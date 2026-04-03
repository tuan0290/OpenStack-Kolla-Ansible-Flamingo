# Chuẩn bị môi trường cho Kolla-Ansible

## Mục lục

1. [Mô hình triển khai](#1-mô-hình-triển-khai)
2. [IP Planning](#2-ip-planning)
3. [Cấu hình VMware](#3-cấu-hình-vmware)
4. [Chuẩn bị Bastion (thủ công - 1 lần)](#4-chuẩn-bị-bastion)
5. [Chuẩn bị tất cả nodes bằng script](#5-chuẩn-bị-tất-cả-nodes-bằng-script)
6. [Kiểm tra kết quả](#6-kiểm-tra-kết-quả)

---

## 1. Mô hình triển khai

Kolla-Ansible triển khai OpenStack dưới dạng **Docker container**. Toàn bộ quá trình deploy được điều khiển từ một node trung tâm gọi là **bastion** (deploy node).

```
┌─────────────────────────────────────────────────────────────────┐
│                        BASTION NODE                             │
│   Kolla-Ansible + Ansible + Python venv                         │
│   /etc/kolla/globals.yml  ← cấu hình toàn bộ deployment        │
│   /etc/kolla/passwords.yml ← mật khẩu tất cả service           │
│   multinode inventory     ← danh sách nodes và roles           │
└──────────────────────────────┬──────────────────────────────────┘
                               │ SSH (Management network)
              ┌────────────────┼──────────────────────────────────────────┐
              ▼                ▼                ▼                          ▼
     ┌────────────────┐ ┌────────────┐ ┌────────────────┐ ┌──────────────────────┐
     │  CONTROLLER    │ │  COMPUTE1  │ │  STORAGE1      │ │  OBJECT1 / OBJECT2   │
     │  (containers)  │ │(containers)│ │  (containers)  │ │     (containers)     │
     │  keystone      │ │  nova-     │ │  cinder-volume │ │  swift-account       │
     │  glance        │ │  compute   │ │                │ │  swift-container     │
     │  nova-api      │ │  ovn-      │ │                │ │  swift-object        │
     │  neutron       │ │  controller│ │                │ │                      │
     │  horizon...    │ │            │ │                │ │                      │
     └────────────────┘ └────────────┘ └────────────────┘ └──────────────────────┘
```

**Điểm khác biệt so với cài Manual:**
- Không cài package trực tiếp lên OS, tất cả chạy trong Docker container
- Không cần cấu hình MariaDB, RabbitMQ, Memcached thủ công - Kolla lo hết
- Một lệnh `kolla-ansible deploy` thay thế toàn bộ các bước cài từng service
- Kolla-Ansible chạy trực tiếp trên **bastion** trong Python virtual environment
- Các bước chuẩn bị nodes (Docker, NTP, hostname) được tự động hóa bằng **shell script**

---

## 2. IP Planning

### Phân hoạch địa chỉ IP

**Tất cả nodes:**

| Hostname | Interface | IP Address | Netmask | Gateway | DNS | Vai trò |
|---|---|---|---|---|---|---|
| bastion | ens33 (NAT) | 192.168.182.128 | 255.255.255.0 | 192.168.182.2 | 8.8.8.8 | Internet |
| bastion | ens37 (Mgmt) | 192.168.225.200 | 255.255.255.0 | | | Management |
| controller | ens33 (NAT) | 192.168.182.195 | 255.255.255.0 | 192.168.182.2 | 8.8.8.8 | Provider/Internet (tạm thời) |
| controller | ens37 (Mgmt) | 192.168.225.195 | 255.255.255.0 | | | Management |
| controller | ens38 (Tunnel) | 192.168.147.195 | 255.255.255.0 | | | OVN Tunnel |
| compute1 | ens33 (NAT) | 192.168.182.196 | 255.255.255.0 | 192.168.182.2 | 8.8.8.8 | Provider/Internet (tạm thời) |
| compute1 | ens37 (Mgmt) | 192.168.225.196 | 255.255.255.0 | | | Management |
| compute1 | ens38 (Tunnel) | 192.168.147.196 | 255.255.255.0 | | | OVN Tunnel |
| storage1 | ens33 (NAT) | 192.168.182.197 | 255.255.255.0 | 192.168.182.2 | 8.8.8.8 | Internet |
| storage1 | ens37 (Mgmt) | 192.168.225.197 | 255.255.255.0 | | | Management |
| object1 | ens33 (NAT) | 192.168.182.198 | 255.255.255.0 | 192.168.182.2 | 8.8.8.8 | Internet |
| object1 | ens37 (Mgmt) | 192.168.225.198 | 255.255.255.0 | | | Management |
| object2 | ens33 (NAT) | 192.168.182.199 | 255.255.255.0 | 192.168.182.2 | 8.8.8.8 | Internet |
| object2 | ens37 (Mgmt) | 192.168.225.199 | 255.255.255.0 | | | Management |

> **Lưu ý:** `ens33` trên controller và compute1 có IP tạm thời trong giai đoạn cài đặt ban đầu. Kolla-Ansible sẽ tự động gán interface này vào OVS bridge `br-ex` khi deploy Neutron, lúc đó IP trên `ens33` sẽ mất.

### Yêu cầu phần cứng

| Node | vCPU | RAM | Disk 1 (OS) | Disk 2 | Ghi chú |
|---|---|---|---|---|---|
| bastion | 2 | 2 GB | 20 GB | - | Chỉ chạy Kolla-Ansible |
| controller | 4 | 8 GB | 40 GB | 30 GB | RAM cao hơn Manual vì chạy nhiều container |
| compute1 | 4 | 4 GB | 50 GB | - | |
| storage1 | 2 | 2 GB | 20 GB | 50 GB | Disk 2 cho Cinder LVM |
| object1 | 2 | 2 GB | 20 GB | 20 GB | 20 GB Disk 2+3 cho Swift |
| object2 | 2 | 2 GB | 20 GB | 20 GB | 20 GB Disk 2+3 cho Swift |

---

## 3. Cấu hình VMware

### 3.1 Clone VM từ Bastion

Tất cả các nodes đều clone từ bastion để tiết kiệm thời gian cài OS. Sau khi clone, mỗi node cần được chỉnh lại disk, network adapter, và cấu hình riêng.

**Thứ tự clone và cấu hình disk trong VMware:**

| VM clone | Disk 1 (sda) | Disk 2 (sdb) | Disk 3 (sdc) | Action sau clone |
|---|---|---|---|---|
| controller | Giữ 20GB → expand lên **40GB** | Thêm mới **30GB** | - | Expand sda + growpart |
| compute1 | Giữ 20GB → expand lên **50GB** | - | - | Expand sda + growpart |
| storage1 | Giữ 20GB | Thêm mới **50GB** | - | Chỉ expand sda nếu cần |
| object1 | Giữ 20GB | Thêm mới **20GB** | Thêm mới **20GB** | Chỉ expand sda nếu cần |
| object2 | Giữ 20GB | Thêm mới **20GB** | Thêm mới **20GB** | Chỉ expand sda nếu cần |

---

#### Bước 1 - Clone VM trong VMware

Trong VMware Workstation:
1. Chuột phải vào VM **bastion** → **Manage** → **Clone**
2. Chọn **Create a full clone**
3. Đặt tên theo node (controller, compute1, storage1, object1, object2)
4. Lặp lại cho từng node

---

#### Bước 2 - Chỉnh disk cho từng node sau khi clone

**Controller** - expand sda lên 40GB, thêm sdb 30GB:

Trong VMware VM Settings của controller:
- Hard Disk 1 (sda): **Expand** → nhập `40` GB
- **Add** → Hard Disk → SCSI → **30 GB** → tạo new virtual disk

**Compute1** - expand sda lên 50GB, không cần disk 2:

- Hard Disk 1 (sda): **Expand** → nhập `50` GB

**Storage1** - giữ sda 20GB, thêm sdb 50GB:

- **Add** → Hard Disk → SCSI → **50 GB** → tạo new virtual disk

**Object1 và Object2** - giữ sda 20GB, thêm sdb + sdc mỗi cái 20GB:

- **Add** → Hard Disk → SCSI → **20 GB** (sdb)
- **Add** → Hard Disk → SCSI → **20 GB** (sdc)

---

#### Bước 3 - Chỉnh Network Adapter cho từng node sau khi clone

Bastion chỉ có 1 adapter (VMnet8). Các node cần thêm adapter:

**Controller, Compute1** - thêm 2 adapter nữa:

Trong VM Settings:
- Network Adapter 1: giữ nguyên **VMnet8 (NAT)**
- **Add** → Network Adapter → **VMnet1 (Host-only)** ← Management
- **Add** → Network Adapter → **VMnet2 (Host-only)** ← Tunnel

**Storage1, Object1, Object2** - thêm 1 adapter:

- Network Adapter 1: giữ nguyên **VMnet8 (NAT)**
- **Add** → Network Adapter → **VMnet1 (Host-only)** ← Management

---

#### Bước 4 - Khởi tạo node sau khi boot (chạy trên từng node)

Copy script [`scripts/initVM.sh`](scripts/initVM.sh) vào node rồi chạy với tên node tương ứng:

```bash
bash initVM.sh controller   # đổi thành: compute1 | storage1 | object1 | object2
```

Script tự động thực hiện 4 việc: expand OS disk, set hostname, cập nhật `/etc/hosts`, cấu hình netplan. Sau khi chạy xong, reboot:

```bash
reboot
```

Kết quả mong đợi sau reboot cho từng node:

| Node | / (sda) | sdb | sdc |
|---|---|---|---|
| controller | ~39G | 30G (trống) | - |
| compute1 | ~49G | - | - |
| storage1 | ~19G | 50G (trống) | - |
| object1 | ~19G | 20G (trống) | 20G (trống) |
| object2 | ~19G | 20G (trống) | 20G (trống) |

> `sdb`/`sdc` để trống hoàn toàn - không partition, không format. Kolla-Ansible (Cinder/Swift) sẽ tự xử lý khi deploy.

---

### 3.2 Gán Network Adapter

**Bastion** - 2 adapter:

| Adapter | Kết nối vào | Mục đích |
|---|---|---|
| Network Adapter 1 | VMnet8 (NAT) | Internet / SSH giai đoạn đầu |
| Network Adapter 2 | VMnet1 (Host-only) | Management - SSH sau khi flush ens33 |

**Controller, Compute1** - 3 adapter:

| Adapter | Kết nối vào | Mục đích |
|---|---|---|
| Network Adapter 1 | VMnet8 (NAT) | Provider / Internet |
| Network Adapter 2 | VMnet1 (Host-only) | Management |
| Network Adapter 3 | VMnet2 (Host-only) | Tunnel |

**Storage1, Object1, Object2** - 2 adapter:

| Adapter | Kết nối vào | Mục đích |
|---|---|---|
| Network Adapter 1 | VMnet8 (NAT) | Internet |
| Network Adapter 2 | VMnet1 (Host-only) | Management |

---

## 4. Chuẩn bị Bastion

> Chỉ thực hiện thủ công trên **bastion** - 1 lần duy nhất.

### 4.1 Cấu hình network

```bash
apt update && apt upgrade -y
```

Sửa `/etc/netplan/50-cloud-init.yaml`:

```bash
cat > /etc/netplan/50-cloud-init.yaml << 'EOF'
network:
  version: 2
  ethernets:
    ens33:
      addresses:
        - 192.168.182.128/24
      routes:
        - to: default
          via: 192.168.182.2
      nameservers:
        addresses: [8.8.8.8]
    ens37:
      addresses:
        - 192.168.225.200/24
EOF
chmod 600 /etc/netplan/50-cloud-init.yaml
netplan apply
```

```bash
hostnamectl set-hostname bastion
```

```bash
# Xóa block cũ nếu đã chạy trước đó, rồi append lại
sed -i '/# Provider IP - bastion SSH/,/^$/d' /etc/hosts
cat >> /etc/hosts << 'EOF'

# Provider IP - bastion SSH đến các nodes qua dải này (giai đoạn chuẩn bị)
192.168.182.195    controller-provider
192.168.182.196    compute1-provider
192.168.182.197    storage1-provider
192.168.182.198    object1-provider
192.168.182.199    object2-provider

# Management IP - Kolla-Ansible dùng dải này để deploy
192.168.225.195    controller
192.168.225.196    compute1
192.168.225.197    storage1
192.168.225.198    object1
192.168.225.199    object2
EOF
```

### 4.2 Cài đặt dependencies

```bash
apt install -y git python3-dev libffi-dev gcc libssl-dev python3-venv
```

### 4.3 Tạo ansible.cfg

Cấu hình Ansible để tắt warning Python interpreter và hiển thị VM offline thay vì báo lỗi đỏ:

```bash
cat > ~/ansible.cfg << 'EOF'
[defaults]
host_key_checking = False
interpreter_python = /usr/bin/python3
stdout_callback = yaml

[ssh_connection]
ssh_args = -o ConnectTimeout=5 -o ConnectionAttempts=1
EOF
```

> `ConnectTimeout=5` giới hạn thời gian chờ SSH 5 giây. Node nào không phản hồi sẽ hiện `UNREACHABLE` với thông báo timeout thay vì lỗi đỏ dài dòng. `interpreter_python` tắt warning về Python discovery.

### 4.3 Cài đặt Kolla-Ansible trong Python venv

```bash
python3 -m venv /opt/kolla-venv
source /opt/kolla-venv/bin/activate
pip install -U pip
pip install kolla-ansible==21.0.0
```

```bash
echo "source /opt/kolla-venv/bin/activate" >> ~/.bashrc
```

```bash
kolla-ansible install-deps
```

### 4.4 Khởi tạo cấu hình Kolla

```bash
mkdir -p /etc/kolla
cp -r /opt/kolla-venv/share/kolla-ansible/etc_examples/kolla/* /etc/kolla/
```

Tạo `~/multinode` từ file mẫu của Kolla rồi chỉ sửa phần nodes:

```bash
# Lấy phần header (5 groups đầu + deployment + bifrost)
cat > /tmp/multinode-header << 'EOF'
[control]
controller ansible_host=192.168.225.195 ansible_user=root ansible_become=True ansible_private_key_file=~/.ssh/id_ed25519

[network]
controller ansible_host=192.168.225.195 ansible_user=root ansible_become=True ansible_private_key_file=~/.ssh/id_ed25519

[compute]
compute1 ansible_host=192.168.225.196 ansible_user=root ansible_become=True ansible_private_key_file=~/.ssh/id_ed25519

[monitoring]
controller ansible_host=192.168.225.195 ansible_user=root ansible_become=True ansible_private_key_file=~/.ssh/id_ed25519

[storage]
controller ansible_host=192.168.225.195 ansible_user=root ansible_become=True ansible_private_key_file=~/.ssh/id_ed25519

[deployment]
localhost ansible_connection=local

[bifrost]

EOF

# Ghép với toàn bộ phần [baremetal:children] trở đi từ file mẫu chính thức
BAREMETAL_LINE=$(grep -n "^\[baremetal" \
  /opt/kolla-venv/share/kolla-ansible/ansible/inventory/multinode \
  | cut -d: -f1)
tail -n +${BAREMETAL_LINE} \
  /opt/kolla-venv/share/kolla-ansible/ansible/inventory/multinode \
  >> /tmp/multinode-header

# Thêm all:vars
printf "\n[all:vars]\nansible_python_interpreter=/usr/bin/python3\n" \
  >> /tmp/multinode-header

cp /tmp/multinode-header ~/multinode
```

Kiểm tra nhanh IP trong inventory:

```bash
grep ansible_host ~/multinode
```

```
controller ansible_host=192.168.225.195 ...   ← Management IP
compute1   ansible_host=192.168.225.196 ...   ← Management IP
```

### 4.5 Tạo SSH key và copy đến tất cả nodes

```bash
ssh-keygen -t ed25519 -C "kolla-ansible" -f ~/.ssh/id_ed25519 -N ""
```

```bash
ssh-copy-id -i ~/.ssh/id_ed25519.pub root@192.168.225.195   # controller
ssh-copy-id -i ~/.ssh/id_ed25519.pub root@192.168.225.196   # compute1
ssh-copy-id -i ~/.ssh/id_ed25519.pub root@192.168.225.197   # storage1
ssh-copy-id -i ~/.ssh/id_ed25519.pub root@192.168.225.198   # object1
ssh-copy-id -i ~/.ssh/id_ed25519.pub root@192.168.225.199   # object2
```

---

## 5. Chuẩn bị tất cả nodes bằng script

> Thực hiện trên **bastion**, đảm bảo đã copy SSH key đến tất cả nodes (bước 4.5).

Script [`scripts/prepare-nodes.sh`](scripts/prepare-nodes.sh) tự động hóa 3 việc theo thứ tự:
1. Fix `/etc/resolv.conf` - gỡ symlink `systemd-resolved`, ghi DNS tĩnh để `apt` hoạt động ổn định
2. Cài Docker CE + cấu hình daemon
3. Cài và cấu hình Chrony (controller làm NTP server, các node còn lại là client)

### 5.1 Copy script lên bastion

```bash
# Từ máy local (nếu dùng repo)
scp scripts/prepare-nodes.sh root@192.168.182.128:~/prepare-nodes.sh
chmod +x ~/prepare-nodes.sh
```

### 5.2 Chạy script

Chạy toàn bộ (DNS fix → Docker → NTP):

```bash
bash ~/prepare-nodes.sh
```

Hoặc chạy từng phần nếu cần:

```bash
bash ~/prepare-nodes.sh --dns      # Chỉ fix /etc/resolv.conf
bash ~/prepare-nodes.sh --docker   # DNS fix + Docker
bash ~/prepare-nodes.sh --ntp      # DNS fix + NTP
bash ~/prepare-nodes.sh --verify   # Kiểm tra trạng thái
```

---

## 6. Kiểm tra kết quả

### 6.1 Kiểm tra Docker và Chrony đang chạy

```bash
bash ~/prepare-nodes.sh --verify
```

Kết quả mong đợi:

```
  controller   | Docker: active   | Chrony: active
  compute1     | Docker: active   | Chrony: active
  storage1     | Docker: active   | Chrony: active
  object1      | Docker: active   | Chrony: active
  object2      | Docker: active   | Chrony: active
```

### 6.2 Kiểm tra các node đã sync time từ controller

Chạy trên từng NTP client (compute1, storage1, object1, object2):

```bash
ssh root@192.168.225.196 "chronyc sources"   # compute1
```

Kết quả mong đợi - phải thấy dấu `^*` trước `192.168.225.195` (controller):

```
MS Name/IP address         Stratum Poll Reach LastRx Last sample
===============================================================================
^* 192.168.225.195               3   6   377    42   +123us[ +456us] +/-  10ms
```

> Nếu thấy `^?` thì chrony chưa reach được controller - kiểm tra lại firewall hoặc chrony config trên controller.

### 6.3 Kiểm tra độ lệch thời gian

```bash
ssh root@192.168.225.196 "chronyc tracking"
```

```
Reference ID    : C0A8E1C3 (192.168.225.195)
System time     : 0.000123456 seconds fast of NTP time
```

> `Reference ID` phải là `192.168.225.195`. Nếu thấy `INIT` thì đợi thêm 1-2 phút rồi chạy lại.

---

Tiếp theo: [02-kolla-ansible-setup.md](02-kolla-ansible-setup.md)
