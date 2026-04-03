#!/bin/bash
# prepare-nodes.sh - Cài Docker và NTP cho tất cả OpenStack nodes
#
# Chạy trên BASTION sau khi đã setup SSH key đến các nodes
#
# Usage:
#   bash prepare-nodes.sh              # Tất cả: DNS fix + Docker + NTP
#   bash prepare-nodes.sh --dns        # Chỉ fix /etc/resolv.conf
#   bash prepare-nodes.sh --docker     # DNS fix + Docker
#   bash prepare-nodes.sh --ntp        # DNS fix + NTP
#   bash prepare-nodes.sh --verify     # Kiểm tra trạng thái

set -e

# ─── Config ───────────────────────────────────────────────────────────────────
MGMT_NET="192.168.225"
CONTROLLER_IP="${MGMT_NET}.195"
SSH_KEY="~/.ssh/id_ed25519"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=5"

declare -A NODES=(
  [controller]="${MGMT_NET}.195"
  [compute1]="${MGMT_NET}.196"
  [storage1]="${MGMT_NET}.197"
  [object1]="${MGMT_NET}.198"
  [object2]="${MGMT_NET}.199"
)

NTP_CLIENTS=(compute1 storage1 object1 object2)

# ─── Helpers ──────────────────────────────────────────────────────────────────
run_on() {
  local node=$1
  local ip=${NODES[$node]}
  shift
  ssh $SSH_OPTS -i $SSH_KEY root@"$ip" "$@"
}

print_step() {
  echo ""
  echo "──────────────────────────────────────────"
  echo " $1"
  echo "──────────────────────────────────────────"
}

# ─── Fix DNS (resolv.conf) ────────────────────────────────────────────────────
fix_dns() {
  local node=$1
  echo "  [$node] Fixing /etc/resolv.conf..."
  run_on "$node" bash << 'REMOTE'
set -e
# Gỡ symlink của systemd-resolved (nếu có), thay bằng file tĩnh
rm -f /etc/resolv.conf
cat > /etc/resolv.conf << 'EOF'
nameserver 8.8.8.8
nameserver 8.8.4.4
EOF
# Ngăn systemd-resolved ghi đè lại
chattr +i /etc/resolv.conf 2>/dev/null || true
echo "    DNS fixed"
REMOTE
}

# ─── Install Docker ───────────────────────────────────────────────────────────
install_docker() {
  local node=$1
  echo "  [$node] Installing Docker..."
  run_on "$node" bash << 'REMOTE'
set -e
# GPG key
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

# Repo
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list

# Install
apt-get update -qq
apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin

# Daemon config
cat > /etc/docker/daemon.json << 'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "50m", "max-file": "5" }
}
EOF

systemctl restart docker
systemctl enable docker
echo "    Docker $(docker --version | awk '{print $3}' | tr -d ',')"
REMOTE
}

# ─── Configure NTP ────────────────────────────────────────────────────────────
configure_ntp_server() {
  echo "  [controller] Configuring chrony as NTP server..."
  run_on controller bash << REMOTE
set -e
apt-get install -y -qq chrony
cat > /etc/chrony/chrony.conf << 'EOF'
server 1.vn.pool.ntp.org iburst
server 0.asia.pool.ntp.org iburst
allow 192.168.225.0/24
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
EOF
systemctl restart chrony
systemctl enable chrony
chronyc makestep || true
echo "    Chrony server ready"
REMOTE
}

configure_ntp_client() {
  local node=$1
  echo "  [$node] Configuring chrony as NTP client → controller (${CONTROLLER_IP})..."
  run_on "$node" bash << REMOTE
set -e
apt-get install -y -qq chrony
cat > /etc/chrony/chrony.conf << 'EOF'
server ${CONTROLLER_IP} iburst
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
EOF
systemctl restart chrony
systemctl enable chrony
echo "    Chrony client ready"
REMOTE
}

# ─── Verify ───────────────────────────────────────────────────────────────────
verify_node() {
  local node=$1
  local ip=${NODES[$node]}
  local docker_status chrony_status
  docker_status=$(ssh $SSH_OPTS -i $SSH_KEY root@"$ip" \
    "systemctl is-active docker 2>/dev/null || echo inactive")
  chrony_status=$(ssh $SSH_OPTS -i $SSH_KEY root@"$ip" \
    "systemctl is-active chrony 2>/dev/null || echo inactive")
  printf "  %-12s | Docker: %-8s | Chrony: %s\n" \
    "$node" "$docker_status" "$chrony_status"
}

# ─── Main ─────────────────────────────────────────────────────────────────────
MODE=${1:-"--all"}

case $MODE in
  --dns)
    print_step "Fixing DNS on all nodes"
    for node in "${!NODES[@]}"; do fix_dns "$node"; done
    ;;

  --docker)
    print_step "Fixing DNS on all nodes"
    for node in "${!NODES[@]}"; do fix_dns "$node"; done
    print_step "Installing Docker on all nodes"
    for node in "${!NODES[@]}"; do install_docker "$node"; done
    ;;

  --ntp)
    print_step "Fixing DNS on all nodes"
    for node in "${!NODES[@]}"; do fix_dns "$node"; done
    print_step "Configuring NTP"
    configure_ntp_server
    for node in "${NTP_CLIENTS[@]}"; do configure_ntp_client "$node"; done
    ;;

  --verify)
    print_step "Verifying node status"
    for node in "${!NODES[@]}"; do verify_node "$node"; done
    ;;

  --all|*)
    print_step "Fixing DNS on all nodes"
    for node in "${!NODES[@]}"; do fix_dns "$node"; done

    print_step "Installing Docker on all nodes"
    for node in "${!NODES[@]}"; do install_docker "$node"; done

    print_step "Configuring NTP"
    configure_ntp_server
    for node in "${NTP_CLIENTS[@]}"; do configure_ntp_client "$node"; done

    print_step "Verification"
    for node in "${!NODES[@]}"; do verify_node "$node"; done
    ;;
esac

echo ""
echo "Done."
