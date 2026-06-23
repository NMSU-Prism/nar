#!/usr/bin/env bash
set -euo pipefail

NS="kt-local-eth-testnet"
RUNNER="narwhal-runner"
NODE_PREFIX="narwhal-node"
COUNT=10
IMAGE="narwhal-node:local"
TAR="/tmp/narwhal-node-local.tar"

WORKERS=("10.10.0.30" "10.10.0.21")

echo "=== 1. Build custom image locally ==="
mkdir -p /tmp/narwhal-image

cat > /tmp/narwhal-image/Dockerfile <<'DOCKER'
FROM debian:13

RUN apt update && apt install -y \
    openssh-server openssh-client sudo git curl \
    python3 python3-pip python3-venv \
    build-essential clang libclang-dev llvm-dev cmake pkg-config libssl-dev \
 && rm -rf /var/lib/apt/lists/*

RUN useradd -m -s /bin/bash narwhal \
 && echo 'narwhal ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/narwhal \
 && chmod 440 /etc/sudoers.d/narwhal \
 && mkdir -p /var/run/sshd /home/narwhal/.ssh \
 && chown -R narwhal:narwhal /home/narwhal

USER narwhal
WORKDIR /home/narwhal

RUN curl https://sh.rustup.rs -sSf | sh -s -- -y \
 && /home/narwhal/.cargo/bin/rustup default stable \
 && echo 'source $HOME/.cargo/env' >> /home/narwhal/.bashrc

USER root
EXPOSE 22 5000 5001 5002 5003 5004 5005
CMD ["bash", "-lc", "mkdir -p /var/run/sshd && /usr/sbin/sshd && tail -f /dev/null"]
DOCKER

docker build -t "$IMAGE" /tmp/narwhal-image
docker save "$IMAGE" -o "$TAR"

echo "=== 2. Import image into local k3s node ==="
sudo k3s ctr images import "$TAR"

echo "=== 3. Import image into worker nodes ==="
for W in "${WORKERS[@]}"; do
  echo "----- worker $W -----"
  scp "$TAR" "narwhal@$W:/tmp/"
  ssh "narwhal@$W" "sudo /usr/local/bin/k3s ctr images import $TAR"
done

echo "=== 4. Clean old pods/services ==="
kubectl delete pod -n "$NS" "$RUNNER" --ignore-not-found=true

for i in $(seq -w 1 "$COUNT"); do
  kubectl delete pod -n "$NS" "${NODE_PREFIX}-${i}" --ignore-not-found=true
  kubectl delete svc -n "$NS" "${NODE_PREFIX}-${i}" --ignore-not-found=true
done

echo "=== 5. Create runner ==="
cat <<YAML | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${RUNNER}
  namespace: ${NS}
spec:
  nodeSelector:
    eth-node: node-b
  containers:
  - name: ${RUNNER}
    image: ${IMAGE}
    imagePullPolicy: Never
    command: ["sleep","infinity"]
    resources:
      requests:
        cpu: "4"
        memory: "8Gi"
      limits:
        cpu: "8"
        memory: "16Gi"
YAML

kubectl wait --for=condition=Ready pod/"$RUNNER" -n "$NS" --timeout=180s

echo "=== 6. Create 10 dedicated Narwhal pods + DNS services ==="
for i in $(seq -w 1 "$COUNT"); do
  POD="${NODE_PREFIX}-${i}"

cat <<YAML | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${POD}
  namespace: ${NS}
  labels:
    app: narwhal-node
    node-name: ${POD}
spec:
  nodeSelector:
    eth-node: node-b
  containers:
  - name: narwhal
    image: ${IMAGE}
    imagePullPolicy: Never
    resources:
      requests:
        cpu: "500m"
        memory: "2Gi"
      limits:
        cpu: "2"
        memory: "4Gi"
    ports:
    - containerPort: 22
    - containerPort: 5000
    - containerPort: 5001
    - containerPort: 5002
    - containerPort: 5003
    - containerPort: 5004
    - containerPort: 5005
YAML

cat <<YAML | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: ${POD}
  namespace: ${NS}
spec:
  selector:
    node-name: ${POD}
  ports:
  - name: ssh
    port: 22
    targetPort: 22
  - name: p5000
    port: 5000
    targetPort: 5000
  - name: p5001
    port: 5001
    targetPort: 5001
  - name: p5002
    port: 5002
    targetPort: 5002
  - name: p5003
    port: 5003
    targetPort: 5003
  - name: p5004
    port: 5004
    targetPort: 5004
  - name: p5005
    port: 5005
    targetPort: 5005
YAML
done

for i in $(seq -w 1 "$COUNT"); do
  kubectl wait --for=condition=Ready pod/"${NODE_PREFIX}-${i}" -n "$NS" --timeout=180s
done

echo "=== 7. Create SSH key in runner ==="
kubectl exec -n "$NS" "$RUNNER" -- bash -c "
su - narwhal -c 'mkdir -p ~/.ssh && chmod 700 ~/.ssh && ssh-keygen -t rsa -N \"\" -f ~/.ssh/id_rsa'
"

PUBKEY=$(kubectl exec -n "$NS" "$RUNNER" -- cat /home/narwhal/.ssh/id_rsa.pub)

echo "=== 8. Copy runner key to all nodes ==="
for i in $(seq -w 1 "$COUNT"); do
  POD="${NODE_PREFIX}-${i}"
  kubectl exec -n "$NS" "$POD" -- bash -c "
    mkdir -p /home/narwhal/.ssh
    echo '$PUBKEY' > /home/narwhal/.ssh/authorized_keys
    chown -R narwhal:narwhal /home/narwhal/.ssh
    chmod 700 /home/narwhal/.ssh
    chmod 600 /home/narwhal/.ssh/authorized_keys
  "
done

echo "=== 9. Build DNS host list ==="
HOSTS=()
for i in $(seq -w 1 "$COUNT"); do
  HOSTS+=("${NODE_PREFIX}-${i}.${NS}.svc.cluster.local")
done

printf '%s\n' "${HOSTS[@]}"

echo "=== 10. SSH verify by DNS ==="
for HOST in "${HOSTS[@]}"; do
  kubectl exec -n "$NS" "$RUNNER" -- bash -c \
    "su - narwhal -c 'ssh -o StrictHostKeyChecking=no -o BatchMode=yes narwhal@$HOST \"/bin/cat /etc/hostname && whoami && /home/narwhal/.cargo/bin/cargo --version\"'"
done

echo "=== 11. Clone repo and setup venv in runner ==="
kubectl exec -n "$NS" "$RUNNER" -- bash -c "
su - narwhal -c '
cd ~
git clone -b main https://github.com/NMSU-Prism/nar.git narwhal
python3 -m venv ~/virtual_env
. ~/virtual_env/bin/activate
pip install --upgrade pip setuptools wheel
pip install fabric==3.2.2 invoke==2.2.0 paramiko==3.4.0 decorator lexicon six pyyaml matplotlib numpy pandas scipy
'
"

echo "=== 12. Write settings.json with DNS hosts ==="
SETTINGS_JSON="{\"key\":{\"name\":\"local\",\"path\":\"/home/narwhal/.ssh/id_rsa\"},\"ssh_user\":\"narwhal\",\"port\":5000,\"repo\":{\"name\":\"narwhal\",\"url\":\"https://github.com/NMSU-Prism/nar.git\",\"branch\":\"main\"},\"hosts\":["
for idx in "${!HOSTS[@]}"; do
  n=$((idx+1))
  SETTINGS_JSON+="{\"name\":\"n$n\",\"ip\":\"${HOSTS[$idx]}\"}"
  if [ "$idx" -lt 9 ]; then SETTINGS_JSON+=","; fi
done
SETTINGS_JSON+="]}"

kubectl exec -n "$NS" "$RUNNER" -- bash -c "cat > /home/narwhal/narwhal/benchmark/settings.json <<'JSON'
$SETTINGS_JSON
JSON
chown -R narwhal:narwhal /home/narwhal/narwhal
"

echo "=== 13. Patch fabfile.py for 10 nodes ==="
kubectl exec -n "$NS" "$RUNNER" -- bash -c "
su - narwhal -c '
cd ~/narwhal/benchmark
python3 - <<PY
from pathlib import Path
p = Path(\"fabfile.py\")
s = p.read_text()
s = s.replace(\"'nodes': [2],\", \"'nodes': [10],\")
s = s.replace(\"'rate': [10_000, 110_000],\", \"'rate': [10_000],\")
s = s.replace(\"'runs': 2,\", \"'runs': 1,\")
p.write_text(s)
PY
'
"

echo "=== 14. Verify setup ==="
kubectl exec -n "$NS" "$RUNNER" -- bash -c "
su - narwhal -c '
source ~/.cargo/env
source ~/virtual_env/bin/activate
export NARWHAL_SETTINGS=/home/narwhal/narwhal/benchmark/settings.json
cd ~/narwhal/benchmark

echo --- settings ---
cat \$NARWHAL_SETTINGS

python3 - <<PY
import json
cfg=json.load(open(\"/home/narwhal/narwhal/benchmark/settings.json\"))
print(\"hosts =\", len(cfg[\"hosts\"]))
print([h[\"ip\"] for h in cfg[\"hosts\"]])
assert len(cfg[\"hosts\"]) == 10
assert cfg[\"repo\"][\"url\"] == \"https://github.com/NMSU-Prism/nar.git\"
assert cfg[\"repo\"][\"branch\"] == \"main\"
PY

echo --- fab remote patch ---
grep -A18 \"def remote\" fabfile.py

echo --- runner rust ---
cargo --version
rustc --version

echo --- fab ---
fab --version
fab --list
'
"

echo "=== DONE ==="
echo "Run benchmark:"
echo "kubectl exec -it -n $NS $RUNNER -- bash"
echo "su - narwhal"
echo "source ~/virtual_env/bin/activate"
echo "source ~/.cargo/env"
echo "export NARWHAL_SETTINGS=/home/narwhal/narwhal/benchmark/settings.json"
echo "cd ~/narwhal/benchmark"
echo "fab remote"
