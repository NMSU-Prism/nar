#!/usr/bin/env bash
set -euo pipefail

NS="kt-local-eth-testnet"
RUNNER="narwhal-runner"

echo "=== 0. Detect running EL pods ==="
PODS=($(kubectl get pods -n "$NS" --field-selector=status.phase=Running -o name \
  | sed 's#pod/##' \
  | grep '^el-.*geth-lighthouse$' \
  | sort \
  | head -10))

if [ "${#PODS[@]}" -lt 10 ]; then
  echo "ERROR: Need 10 running EL pods, found ${#PODS[@]}"
  printf '%s\n' "${PODS[@]}"
  exit 1
fi

IPS=()
for POD in "${PODS[@]}"; do
  IP=$(kubectl get pod -n "$NS" "$POD" -o jsonpath='{.status.podIP}')
  IPS+=("$IP")
done

echo "Using pods:"
printf '%s\n' "${PODS[@]}"
echo "Using IPs:"
printf '%s\n' "${IPS[@]}"

echo "=== 1. Reset runner ==="
kubectl delete pod -n "$NS" "$RUNNER" --ignore-not-found=true
kubectl run "$RUNNER" -n "$NS" --image=debian:13 --restart=Never --command -- sleep infinity
kubectl wait --for=condition=Ready pod/"$RUNNER" -n "$NS" --timeout=180s

echo "=== 2. Install runner tools ==="
kubectl exec -n "$NS" "$RUNNER" -- bash -c "
apt update &&
apt install -y git curl openssh-client sudo python3 python3-pip python3-venv build-essential pkg-config libssl-dev
"

echo "=== 3. Create runner user/key ==="
kubectl exec -n "$NS" "$RUNNER" -- bash -c "
useradd -m -s /bin/bash narwhal 2>/dev/null || true
echo 'narwhal ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/narwhal
chmod 440 /etc/sudoers.d/narwhal
chown -R narwhal:narwhal /home/narwhal
su - narwhal -c 'mkdir -p ~/.ssh && chmod 700 ~/.ssh && ssh-keygen -t rsa -N \"\" -f ~/.ssh/id_rsa'
"

PUBKEY=$(kubectl exec -n "$NS" "$RUNNER" -- cat /home/narwhal/.ssh/id_rsa.pub)

echo "=== 4. Prepare selected EL pods ==="
for POD in "${PODS[@]}"; do
  echo "----- $POD -----"
  kubectl exec -n "$NS" "$POD" -- bash -c "
    apt update &&
    apt install -y openssh-server sudo git curl build-essential pkg-config libssl-dev &&
    useradd -m -s /bin/bash narwhal 2>/dev/null || true
    mkdir -p /var/run/sshd
    service ssh restart || /usr/sbin/sshd
    echo 'narwhal ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/narwhal
    chmod 440 /etc/sudoers.d/narwhal
    mkdir -p /home/narwhal/.ssh
    echo '$PUBKEY' >> /home/narwhal/.ssh/authorized_keys
    chown -R narwhal:narwhal /home/narwhal
    chmod 700 /home/narwhal/.ssh
    chmod 600 /home/narwhal/.ssh/authorized_keys
  "
done

echo "=== 5. SSH verify ==="
for IP in "${IPS[@]}"; do
  kubectl exec -n "$NS" "$RUNNER" -- bash -c \
    "su - narwhal -c 'ssh -o StrictHostKeyChecking=no -o BatchMode=yes narwhal@$IP \"hostname && whoami\"'"
done

echo "=== 6. Install Rust on EL pods ==="
for IP in "${IPS[@]}"; do
  echo "----- $IP -----"
  kubectl exec -n "$NS" "$RUNNER" -- bash -c \
    "su - narwhal -c 'ssh narwhal@$IP \"curl https://sh.rustup.rs -sSf | sh -s -- -y && . \\\$HOME/.cargo/env && cargo --version\"'"
done

echo "=== 7. Setup Narwhal runner ==="
kubectl exec -n "$NS" "$RUNNER" -- bash -c "
su - narwhal -c '
cd ~
git clone -b main https://github.com/NMSU-Prism/nar.git
python3 -m venv ~/virtual_env
. ~/virtual_env/bin/activate
pip install --upgrade pip setuptools wheel
pip install fabric==3.2.2 invoke==2.2.0 paramiko==3.4.0 decorator lexicon six pyyaml matplotlib numpy pandas scipy
'
"

echo "=== 8. Write settings.json ==="
SETTINGS_JSON="{\"key\":{\"name\":\"local\",\"path\":\"/home/narwhal/.ssh/id_rsa\"},\"ssh_user\":\"narwhal\",\"port\":5000,\"repo\":{\"name\":\"narwhal\",\"url\":\"https://github.com/NMSU-Prism/narwhal.git\",\"branch\":\"master\"},\"hosts\":["
for idx in "${!IPS[@]}"; do
  n=$((idx+1))
  SETTINGS_JSON+="{\"name\":\"n$n\",\"ip\":\"${IPS[$idx]}\"}"
  if [ "$idx" -lt 9 ]; then SETTINGS_JSON+=","; fi
done
SETTINGS_JSON+="]}"

kubectl exec -n "$NS" "$RUNNER" -- bash -c "cat > /home/narwhal/narwhal/benchmark/settings.json <<'JSON'
$SETTINGS_JSON
JSON
chown -R narwhal:narwhal /home/narwhal/narwhal
"

echo "=== 9. Verify fab sees 10 hosts ==="
kubectl exec -n "$NS" "$RUNNER" -- bash -c "
su - narwhal -c '
. ~/virtual_env/bin/activate
export NARWHAL_SETTINGS=/home/narwhal/narwhal/benchmark/settings.json
cd ~/narwhal/benchmark
python3 - <<PY
import json
cfg=json.load(open(\"/home/narwhal/narwhal/benchmark/settings.json\"))
print(\"hosts =\", len(cfg[\"hosts\"]))
print([h[\"ip\"] for h in cfg[\"hosts\"]])
assert len(cfg[\"hosts\"]) == 10
PY
fab --version
fab --list
'
"

echo "=== DONE ==="
echo "Run benchmark:"
echo "kubectl exec -it -n $NS $RUNNER -- bash"
echo "su - narwhal"
echo "source ~/virtual_env/bin/activate"
echo "export NARWHAL_SETTINGS=/home/narwhal/narwhal/benchmark/settings.json"
echo "cd ~/narwhal/benchmark"
echo "fab remote"
