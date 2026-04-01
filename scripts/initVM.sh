#!/bin/bash
# initVM.sh - Khởi tạo VM sau khi clone từ bastion
#
# Usage:
#   bash initVM.sh controller
#   bash initVM.sh compute1
#   bash initVM.sh storage1
#   bash initVM.sh object1
#   bash initVM.sh object2

set -e

# ─── Validate input ───────────────────────────────────────────────────────────
NODE=$1

if [[ -z "$NODE" ]]; then
  echo "Usage: bash initVM.sh <node>"
  echo "  node: controller | compute1 | storage1 | object1 | object2"
  exit 1
fi

VALID_NODES=("controller" "compute1" "storage1" "object1" "object2")
if [[ ! " ${VALID_NODES[*]} " =~ " ${NODE} " ]]; then
  echo "Error: unknown node '$NODE'"
  echo "Valid nodes: controller | compute1 | storage1 | object1 | object2"
  exit 1
fi

echo "======================================================"
echo " initVM.sh - Initializing node: $NODE"
echo "======================================================"

# ─── Network config per node ──────────────────────────────────────────────────
case $NODE in
  controller)
    IP_ENS33="192.168.182.195"
    IP_ENS37="192.168.225.195"
    IP_ENS38="192.168.147.195"
    ;;
  compute1)
    IP_ENS33="192.168.182.196"
    IP_ENS37="192.168.225.196"
    IP_ENS38="192.168.147.196"
    ;;
  storage1)
    IP_ENS33="192.168.182.197"
    IP_ENS37="192.168.225.197"
    IP_ENS38=""
    ;;
  object1)
    IP_ENS33="192.168.182.198"
    IP_ENS37="192.168.225.198"
    IP_ENS38=""
    ;;
  object2)
    IP_ENS33="192.168.182.199"
    IP_ENS37="192.168.225.199"
    IP_ENS38=""
    ;;
esac

GATEWAY="192.168.182.2"
DNS="8.8.8.8"

# ─── Step 1: Expand OS disk ───────────────────────────────────────────────────
echo ""
echo "[1/4] Expanding OS disk (sda)..."

if ! command -v growpart &>/dev/null; then
  apt-get install -y cloud-guest-utils > /dev/null 2>&1
fi

# Fix GPT mismatch nếu có, expand partition 3
growpart /dev/sda 3 || true

# Resize LVM
pvresize /dev/sda3
lvextend -l +100%FREE /dev/ubuntu-vg/ubuntu-lv || true
resize2fs /dev/ubuntu-vg/ubuntu-lv

echo "    Done. Disk size: $(df -h / | awk 'NR==2{print $2}')"

# ─── Step 2: Set hostname ─────────────────────────────────────────────────────
echo ""
echo "[2/4] Setting hostname to '$NODE'..."

hostnamectl set-hostname "$NODE"

echo "    Done."

# ─── Step 3: Update /etc/hosts ────────────────────────────────────────────────
echo ""
echo "[3/4] Updating /etc/hosts..."

# Xóa entry cũ của bastion nếu còn
sed -i '/192\.168\.182\.128.*bastion/d' /etc/hosts
sed -i '/192\.168\.225\.200.*bastion/d' /etc/hosts

# Xóa block cũ nếu đã chạy script trước đó
sed -i '/# OpenStack nodes - managed by initVM/,/# END OpenStack nodes/d' /etc/hosts

cat >> /etc/hosts << EOF

# OpenStack nodes - managed by initVM
192.168.225.195    controller
192.168.225.196    compute1
192.168.225.197    storage1
192.168.225.198    object1
192.168.225.199    object2
# END OpenStack nodes
EOF

echo "    Done."

# ─── Step 4: Configure network (netplan) ──────────────────────────────────────
echo ""
echo "[4/4] Configuring network..."

NETPLAN_FILE="/etc/netplan/50-cloud-init.yaml"

# Backup file cũ
cp "$NETPLAN_FILE" "${NETPLAN_FILE}.bak.$(date +%s)"

if [[ -n "$IP_ENS38" ]]; then
  # controller và compute1: 3 interfaces
  cat > "$NETPLAN_FILE" << EOF
network:
  version: 2
  ethernets:
    ens33:
      addresses:
        - ${IP_ENS33}/24
      routes:
        - to: default
          via: ${GATEWAY}
      nameservers:
        addresses: [${DNS}]
    ens37:
      addresses:
        - ${IP_ENS37}/24
    ens38:
      addresses:
        - ${IP_ENS38}/24
EOF
else
  # storage1, object1, object2: 2 interfaces
  cat > "$NETPLAN_FILE" << EOF
network:
  version: 2
  ethernets:
    ens33:
      addresses:
        - ${IP_ENS33}/24
      routes:
        - to: default
          via: ${GATEWAY}
      nameservers:
        addresses: [${DNS}]
    ens37:
      addresses:
        - ${IP_ENS37}/24
EOF
fi

chmod 600 "$NETPLAN_FILE"
netplan apply

echo "    Done."

# ─── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "======================================================"
echo " Summary for node: $NODE"
echo "======================================================"
echo " Hostname : $(hostname)"
echo " Disk /   : $(df -h / | awk 'NR==2{print $2}')"
echo " ens33    : $IP_ENS33"
echo " ens37    : $IP_ENS37"
[[ -n "$IP_ENS38" ]] && echo " ens38    : $IP_ENS38"
echo ""
echo " Reboot recommended to apply all changes."
echo "======================================================"
