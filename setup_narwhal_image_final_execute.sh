#!/usr/bin/env bash
set -euo pipefail

NS="kt-local-eth-testnet"
RUNNER="narwhal-runner"
NODE_PREFIX="narwhal-node"
COUNT=10
IMAGE="narwhal-node:local"
TAR="/tmp/narwhal-node-local.tar"

WORKERS=("10.10.0.30" "10.10.0.21" "10.10.0.28" "10.10.0.29")

echo "=== 1. Build custom image locally with prebuilt nar.git ==="
# mkdir -p /tmp/narwhal-image

# cat > /tmp/narwhal-image/Dockerfile <<'DOCKER'
# FROM debian:13

# RUN apt update && apt install -y \
#     openssh-server openssh-client sudo git curl tmux \
#     python3 python3-pip python3-venv \
#     build-essential clang libclang-dev llvm-dev cmake pkg-config libssl-dev \
#  && rm -rf /var/lib/apt/lists/*

# RUN useradd -m -s /bin/bash narwhal \
#  && echo 'narwhal ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/narwhal \
#  && chmod 440 /etc/sudoers.d/narwhal \
#  && mkdir -p /var/run/sshd /home/narwhal/.ssh \
#  && chown -R narwhal:narwhal /home/narwhal

# USER narwhal
# WORKDIR /home/narwhal

# RUN curl https://sh.rustup.rs -sSf | sh -s -- -y \
#  && /home/narwhal/.cargo/bin/rustup default stable \
#  && echo 'source $HOME/.cargo/env' >> /home/narwhal/.bashrc

# ENV PATH="/home/narwhal/.cargo/bin:${PATH}"
# ENV CARGO_BUILD_JOBS=1

# RUN git clone -b main https://github.com/NMSU-Prism/nar.git /home/narwhal/narwhal \
#  && cd /home/narwhal/narwhal \
#  && cargo build --release --features benchmark

# USER root
# EXPOSE 22 5000 5001 5002 5003 5004 5005
# CMD ["bash", "-lc", "mkdir -p /var/run/sshd && /usr/sbin/sshd && tail -f /dev/null"]
# DOCKER

# docker build -t "$IMAGE" /tmp/narwhal-image
# docker save "$IMAGE" -o "$TAR"

# echo "=== 2. Import image into local k3s node ==="
# sudo /usr/local/bin/k3s ctr images import "$TAR"

# echo "=== 3. Import image into worker nodes ==="
# for W in "${WORKERS[@]}"; do
#   echo "----- worker $W -----"
#   scp "$TAR" "narwhal@$W:/tmp/"
#   ssh "narwhal@$W" "sudo /usr/local/bin/k3s ctr images import $TAR"
# done

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
        cpu: "1"
        memory: "8Gi"
      limits:
        cpu: "8"
        memory: "16Gi"
YAML

kubectl wait --for=condition=Ready pod/"$RUNNER" -n "$NS" --timeout=300s

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
        cpu: "1"
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
  - name: p5006
    port: 5006
    targetPort: 5006
  - name: p5007
    port: 5007
    targetPort: 5007
  - name: p5008
    port: 5008
    targetPort: 5008
  - name: p5009
    port: 5009
    targetPort: 5009
  - name: p5010
    port: 5010
    targetPort: 5010
  - name: p5011
    port: 5011
    targetPort: 5011
  - name: p5012
    port: 5012
    targetPort: 5012
  - name: p5013
    port: 5013
    targetPort: 5013
  - name: p5014
    port: 5014
    targetPort: 5014
  - name: p5015
    port: 5015
    targetPort: 5015
  - name: p5016
    port: 5016
    targetPort: 5016
  - name: p5017
    port: 5017
    targetPort: 5017
  - name: p5018
    port: 5018
    targetPort: 5018
  - name: p5019
    port: 5019
    targetPort: 5019
  - name: p5020
    port: 5020
    targetPort: 5020
  - name: p5021
    port: 5021
    targetPort: 5021
  - name: p5022
    port: 5022
    targetPort: 5022
  - name: p5023
    port: 5023
    targetPort: 5023
  - name: p5024
    port: 5024
    targetPort: 5024
  - name: p5025
    port: 5025
    targetPort: 5025
  - name: p5026
    port: 5026
    targetPort: 5026
  - name: p5027
    port: 5027
    targetPort: 5027
  - name: p5028
    port: 5028
    targetPort: 5028
  - name: p5029
    port: 5029
    targetPort: 5029
  - name: p5030
    port: 5030
    targetPort: 5030
  - name: p5031
    port: 5031
    targetPort: 5031
  - name: p5032
    port: 5032
    targetPort: 5032
  - name: p5033
    port: 5033
    targetPort: 5033
  - name: p5034
    port: 5034
    targetPort: 5034
  - name: p5035
    port: 5035
    targetPort: 5035
  - name: p5036
    port: 5036
    targetPort: 5036
  - name: p5037
    port: 5037
    targetPort: 5037
  - name: p5038
    port: 5038
    targetPort: 5038
  - name: p5039
    port: 5039
    targetPort: 5039
  - name: p5040
    port: 5040
    targetPort: 5040
  - name: p5041
    port: 5041
    targetPort: 5041
  - name: p5042
    port: 5042
    targetPort: 5042
  - name: p5043
    port: 5043
    targetPort: 5043
  - name: p5044
    port: 5044
    targetPort: 5044
  - name: p5045
    port: 5045
    targetPort: 5045
  - name: p5046
    port: 5046
    targetPort: 5046
  - name: p5047
    port: 5047
    targetPort: 5047
  - name: p5048
    port: 5048
    targetPort: 5048
  - name: p5049
    port: 5049
    targetPort: 5049
  - name: p5050
    port: 5050
    targetPort: 5050
YAML
done

for i in $(seq -w 1 "$COUNT"); do
  kubectl wait --for=condition=Ready pod/"${NODE_PREFIX}-${i}" -n "$NS" --timeout=300s
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

echo "=== 9. Build service ClusterIP host list ==="
HOSTS=()
for i in $(seq -w 1 "$COUNT"); do
  SVC="${NODE_PREFIX}-${i}"
  IP=$(kubectl get svc -n "$NS" "$SVC" -o jsonpath='{.spec.clusterIP}')
  HOSTS+=("$IP")
done

printf '%s\n' "${HOSTS[@]}"

echo "=== 10. SSH verify by DNS ==="
for HOST in "${HOSTS[@]}"; do
  kubectl exec -n "$NS" "$RUNNER" -- bash -c \
    "su - narwhal -c 'ssh -o StrictHostKeyChecking=no -o BatchMode=yes narwhal@$HOST \"/bin/cat /etc/hostname && whoami && /home/narwhal/.cargo/bin/cargo --version && test -x /home/narwhal/narwhal/target/release/node && echo PREBUILT_OK\"'"
done

echo "=== 11. Setup venv in runner; repo already exists in image ==="
kubectl exec -n "$NS" "$RUNNER" -- bash -c "
su - narwhal -c '
cd ~
test -d ~/narwhal || git clone -b main https://github.com/NMSU-Prism/nar.git narwhal
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

echo "=== 13.5 Patch remote.py to skip build if binary exists ==="
kubectl exec -n "$NS" "$RUNNER" -- bash -c "
su - narwhal -c '
cd ~/narwhal/benchmark
python3 - <<PY
from pathlib import Path
p = Path(\"benchmark/remote.py\")
s = p.read_text()
s = s.replace(
    \"cargo build --release --features benchmark\",
    \"test -x target/release/node || CARGO_BUILD_JOBS=1 cargo build --release --features benchmark\"
)
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

echo --- remote build command ---
grep -n \"target/release/node\\|cargo build\" benchmark/remote.py

echo --- fab remote patch ---
grep -A18 \"def remote\" fabfile.py

echo --- runner prebuilt binary ---
test -x ~/narwhal/target/release/node && echo PREBUILT_OK

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
