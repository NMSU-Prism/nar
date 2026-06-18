#!/usr/bin/env bash
set -euo pipefail

NS="kt-local-eth-testnet"
RUNNER="narwhal-runner"

PODS=(
el-01-geth-lighthouse
el-02-geth-lighthouse
el-03-geth-lighthouse
el-04-geth-lighthouse
el-05-geth-lighthouse
el-06-geth-lighthouse
el-07-geth-lighthouse
el-08-geth-lighthouse
el-09-geth-lighthouse
el-10-geth-lighthouse
)

IPS=(
10.42.3.64
10.42.3.68
10.42.1.45
10.42.1.44
10.42.3.65
10.42.3.67
10.42.1.41
10.42.1.43
10.42.1.42
10.42.3.66
)

echo "=== 1. Delete old runner if exists ==="
kubectl delete pod -n "$NS" "$RUNNER" --ignore-not-found=true

echo "=== 2. Create runner pod ==="
kubectl run "$RUNNER" -n "$NS" --image=debian:13 --restart=Never --command -- sleep infinity
kubectl wait --for=condition=Ready pod/"$RUNNER" -n "$NS" --timeout=180s

echo "=== 3. Install tools in runner ==="
kubectl exec -n "$NS" "$RUNNER" -- bash -c "
apt update &&
apt install -y git curl openssh-client openssh-server sudo \
python3 python3-pip python3-venv build-essential pkg-config libssl-dev
"

echo "=== 4. Create narwhal user in runner ==="
kubectl exec -n "$NS" "$RUNNER" -- bash -c "
useradd -m -s /bin/bash narwhal 2>/dev/null || true
echo 'narwhal ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/narwhal
chmod 440 /etc/sudoers.d/narwhal
chown -R narwhal:narwhal /home/narwhal
"

echo "=== 5. Generate SSH key in runner ==="
kubectl exec -n "$NS" "$RUNNER" -- bash -c "
su - narwhal -c 'mkdir -p ~/.ssh && chmod 700 ~/.ssh && test -f ~/.ssh/id_rsa || ssh-keygen -t rsa -N \"\" -f ~/.ssh/id_rsa'
"

PUBKEY=$(kubectl exec -n "$NS" "$RUNNER" -- bash -c "cat /home/narwhal/.ssh/id_rsa.pub")

echo "=== 6. Prepare all geth pods ==="
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
    grep -qxF '$PUBKEY' /home/narwhal/.ssh/authorized_keys 2>/dev/null || echo '$PUBKEY' >> /home/narwhal/.ssh/authorized_keys
    chown -R narwhal:narwhal /home/narwhal
    chmod 700 /home/narwhal/.ssh
    chmod 600 /home/narwhal/.ssh/authorized_keys
  "
done

echo "=== 7. Test SSH from runner to all geth pods ==="
for IP in "${IPS[@]}"; do
  kubectl exec -n "$NS" "$RUNNER" -- bash -c "
    su - narwhal -c 'ssh -o StrictHostKeyChecking=no -o BatchMode=yes narwhal@$IP \"hostname && whoami\"'
  "
done

echo "=== 8. Install Rust on all geth pods ==="
for IP in "${IPS[@]}"; do
  echo "----- Rust $IP -----"
  kubectl exec -n "$NS" "$RUNNER" -- bash -c "
    su - narwhal -c 'ssh narwhal@$IP \"curl https://sh.rustup.rs -sSf | sh -s -- -y && . \\\$HOME/.cargo/env && cargo --version\"'
  "
done

echo "=== 9. Clone Narwhal and create venv in runner ==="
kubectl exec -n "$NS" "$RUNNER" -- bash -c "
su - narwhal -c '
cd ~
test -d narwhal || git clone -b master https://github.com/NMSU-Prism/narwhal.git
python3 -m venv ~/virtual_env
. ~/virtual_env/bin/activate
pip install --upgrade pip setuptools wheel
pip install fabric==3.2.2 invoke==2.2.0 paramiko==3.4.0 decorator lexicon six pyyaml matplotlib numpy pandas scipy
'
"

echo "=== 10. Write 10-node settings.json ==="
kubectl exec -n "$NS" "$RUNNER" -- bash -c "cat > /home/narwhal/narwhal/benchmark/settings.json <<'JSON'
{
  \"key\": {
    \"name\": \"local\",
    \"path\": \"/home/narwhal/.ssh/id_rsa\"
  },
  \"ssh_user\": \"narwhal\",
  \"port\": 5000,
  \"repo\": {
    \"name\": \"narwhal\",
    \"url\": \"https://github.com/NMSU-Prism/narwhal.git\",
    \"branch\": \"master\"
  },
  \"hosts\": [
    { \"name\": \"n1\", \"ip\": \"10.42.3.64\" },
    { \"name\": \"n2\", \"ip\": \"10.42.3.68\" },
    { \"name\": \"n3\", \"ip\": \"10.42.1.45\" },
    { \"name\": \"n4\", \"ip\": \"10.42.1.44\" },
    { \"name\": \"n5\", \"ip\": \"10.42.3.65\" },
    { \"name\": \"n6\", \"ip\": \"10.42.3.67\" },
    { \"name\": \"n7\", \"ip\": \"10.42.1.41\" },
    { \"name\": \"n8\", \"ip\": \"10.42.1.43\" },
    { \"name\": \"n9\", \"ip\": \"10.42.1.42\" },
    { \"name\": \"n10\", \"ip\": \"10.42.3.66\" }
  ]
}
JSON
chown -R narwhal:narwhal /home/narwhal/narwhal
"

echo "=== 11. Verify settings and fab ==="
kubectl exec -n "$NS" "$RUNNER" -- bash -c "
su - narwhal -c '
. ~/virtual_env/bin/activate
export NARWHAL_SETTINGS=/home/narwhal/narwhal/benchmark/settings.json
cd ~/narwhal/benchmark
python3 - <<PY
import json
cfg=json.load(open(\"/home/narwhal/narwhal/benchmark/settings.json\"))
print(\"hosts =\", len(cfg[\"hosts\"]))
assert len(cfg[\"hosts\"]) == 10
PY
fab --version
fab --list
'
"

echo "=== DONE ==="
echo "Enter runner with:"
echo "kubectl exec -it -n $NS $RUNNER -- bash"
echo ""
echo "Then run:"
echo "su - narwhal"
echo "source ~/virtual_env/bin/activate"
echo "export NARWHAL_SETTINGS=/home/narwhal/narwhal/benchmark/settings.json"
echo "cd ~/narwhal/benchmark"
echo "fab remote"
