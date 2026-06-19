#!/usr/bin/env bash
set -euo pipefail

NS="kt-local-eth-testnet"
RUNNER="narwhal-runner"
NODE_PREFIX="narwhal-node"
COUNT=10

echo "=== 1. Clean old runner/narwhal nodes ==="
kubectl delete pod -n "$NS" "$RUNNER" --ignore-not-found=true

for i in $(seq -w 1 "$COUNT"); do
  kubectl delete pod -n "$NS" "${NODE_PREFIX}-${i}" --ignore-not-found=true
  kubectl delete svc -n "$NS" "${NODE_PREFIX}-${i}" --ignore-not-found=true
done

echo "=== 2. Create runner pod ==="
kubectl run "$RUNNER" \
  -n "$NS" \
  --image=debian:13 \
  --restart=Never \
  --command -- sleep infinity

kubectl wait --for=condition=Ready pod/"$RUNNER" -n "$NS" --timeout=180s

echo "=== 3. Create 10 dedicated Narwhal pods + services ==="
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
  containers:
  - name: narwhal
    image: debian:13
    command: ["sleep", "infinity"]
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

echo "=== 4. Install runner tools ==="
kubectl exec -n "$NS" "$RUNNER" -- bash -c "
apt update &&
apt install -y git curl openssh-client openssh-server sudo \
python3 python3-pip python3-venv build-essential \
pkg-config libssl-dev clang libclang-dev llvm-dev cmake
"

echo "=== 5. Create runner user/key ==="
kubectl exec -n "$NS" "$RUNNER" -- bash -c "
useradd -m -s /bin/bash narwhal 2>/dev/null || true
echo 'narwhal ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/narwhal
chmod 440 /etc/sudoers.d/narwhal
chown -R narwhal:narwhal /home/narwhal
su - narwhal -c 'mkdir -p ~/.ssh && chmod 700 ~/.ssh && ssh-keygen -t rsa -N \"\" -f ~/.ssh/id_rsa'
"

PUBKEY=$(kubectl exec -n "$NS" "$RUNNER" -- cat /home/narwhal/.ssh/id_rsa.pub)

echo "=== 6. Prepare 10 Narwhal nodes ==="
for i in $(seq -w 1 "$COUNT"); do
  POD="${NODE_PREFIX}-${i}"
  echo "----- $POD -----"

  kubectl exec -n "$NS" "$POD" -- bash -c "
    apt update &&
    apt install -y openssh-server sudo git curl build-essential \
      clang libclang-dev llvm-dev cmake pkg-config libssl-dev &&
    useradd -m -s /bin/bash narwhal 2>/dev/null || true
    mkdir -p /var/run/sshd
    service ssh restart || /usr/sbin/sshd
    echo 'narwhal ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/narwhal
    chmod 440 /etc/sudoers.d/narwhal
    mkdir -p /home/narwhal/.ssh
    grep -qxF '$PUBKEY' /home/narwhal/.ssh/authorized_keys 2>/dev/null || echo '$PUBKEY' >> /home/narwhal/.ssh/authorized_keys
    chown -R narwhal:narwhal /home/narwhal
    chmod 700 /home/narwhal/.ssh
    chmod 600 /home/narwhal/.ssh/authorized_keys
  "
done

echo "=== 7. Build DNS host list ==="
HOSTS=()
for i in $(seq -w 1 "$COUNT"); do
  HOSTS+=("${NODE_PREFIX}-${i}.${NS}.svc.cluster.local")
done

printf '%s\n' "${HOSTS[@]}"

echo "=== 8. SSH verify by DNS ==="
for HOST in "${HOSTS[@]}"; do
  kubectl exec -n "$NS" "$RUNNER" -- bash -c \
    "su - narwhal -c 'ssh -o StrictHostKeyChecking=no -o BatchMode=yes narwhal@$HOST \"hostname && whoami\"'"
done

echo "=== 9. Install/update Rust stable on all 10 Narwhal nodes ==="
for HOST in "${HOSTS[@]}"; do
  echo "----- Rust on $HOST -----"
  kubectl exec -n "$NS" "$RUNNER" -- bash -c \
    "su - narwhal -c 'ssh narwhal@$HOST \"curl https://sh.rustup.rs -sSf | sh -s -- -y && \\\$HOME/.cargo/bin/rustup default stable && rm -rf ~/narwhal && \\\$HOME/.cargo/bin/cargo --version && \\\$HOME/.cargo/bin/rustc --version\"'"
done

echo "=== 10. Setup runner repo, venv, Rust/Cargo ==="
kubectl exec -n "$NS" "$RUNNER" -- bash -c "
su - narwhal -c '
cd ~
git clone -b main https://github.com/NMSU-Prism/nar.git narwhal
python3 -m venv ~/virtual_env
. ~/virtual_env/bin/activate
pip install --upgrade pip setuptools wheel
pip install fabric==3.2.2 invoke==2.2.0 paramiko==3.4.0 decorator lexicon six pyyaml matplotlib numpy pandas scipy

curl https://sh.rustup.rs -sSf | sh -s -- -y
. ~/.cargo/env
rustup default stable
cargo --version
rustc --version
echo \"source \$HOME/.cargo/env\" >> ~/.bashrc
'
"

echo "=== 11. Write settings.json using DNS hostnames ==="
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

echo "=== 12. Patch fabfile.py to use 10 nodes, 1 run, lower rate ==="
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

echo "=== 13. Build runner local Narwhal binaries ==="
kubectl exec -n "$NS" "$RUNNER" -- bash -c "
su - narwhal -c '
. ~/.cargo/env
cd ~/narwhal
cargo build --release --features benchmark
'
"

echo "=== 14. Verify settings, fab, cargo ==="
kubectl exec -n "$NS" "$RUNNER" -- bash -c "
su - narwhal -c '
. ~/virtual_env/bin/activate
. ~/.cargo/env
export NARWHAL_SETTINGS=/home/narwhal/narwhal/benchmark/settings.json
cd ~/narwhal/benchmark

echo \"--- NARWHAL_SETTINGS ---\"
echo \$NARWHAL_SETTINGS
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

echo \"--- fab remote patch ---\"
grep -A18 \"def remote\" fabfile.py

echo \"--- runner cargo ---\"
cargo --version
rustc --version

echo \"--- fab ---\"
fab --version
fab --list
'
"

echo "=== 15. Verify remote Rust/clang by DNS ==="
for HOST in "${HOSTS[@]}"; do
  echo "----- verify $HOST -----"
  kubectl exec -n "$NS" "$RUNNER" -- bash -c \
    "su - narwhal -c 'ssh narwhal@$HOST \"\\\$HOME/.cargo/bin/cargo --version && clang --version | head -1 && ls /usr/lib/*/libclang*.so* /usr/lib/llvm-*/lib/libclang*.so* 2>/dev/null | head -1\"'"
done

echo "=== DONE ==="
echo "Run benchmark:"
echo "kubectl exec -it -n $NS $RUNNER -- bash"
echo "su - narwhal"
echo "source ~/virtual_env/bin/activate"
echo "source ~/.cargo/env"
echo "export NARWHAL_SETTINGS=/home/narwhal/narwhal/benchmark/settings.json"
echo "cd ~/narwhal/benchmark"
echo "fab remote"
