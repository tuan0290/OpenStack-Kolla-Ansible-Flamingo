# Chuẩn bị môi trường cho Kolla-Ansible

## Mục lục

1. [Mô hình triển khai](#1-mô-hình-triển-khai)
2. [IP Planning](#2-ip-planning)
3. [Cấu hình VMware](#3-cấu-hình-vmware)
4. [Chuẩn bị Bastion (thủ công - 1 lần)](#4-chuẩn-bị-bastion)
5. [Chuẩn bị tất cả nodes bằng Ansible Playbook](#5-chuẩn-bị-tất-cả-nodes-bằng-ansible-playbook)
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
- Kolla-Ansible chạy trong **Docker container trên bastion** - không cần cài Python venv thủ công
- Các bước chuẩn bị nodes (Docker, NTP, network, hostname) được tự động hóa bằng **Ansible playbook**

---

## 2. IP Planning

### Phân hoạch địa chỉ IP

**Tất cả nodes:**

| Hostname | Interface | IP Address | Netmask | Gateway | DNS | Vai trò |
|---|---|---|---|---|---|---|
| bastion | ens33 (NAT) | 192.168.182.128 | 255.255.255.0 | 192.168.182.2 | 8.8.8.8 | Internet |
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

#### Bước 4 - Expand disk OS sau khi boot (chạy trên từng node)

Sau khi boot node lên, chạy script `initVM.sh` - script tự động xử lý expand disk, set hostname, cấu hình network và `/etc/hosts` trong 1 lệnh:

```bash
# Copy script từ bastion sang node cần init
scp root@192.168.182.128:/opt/kolla/OpenStack-Kolla-Ansible/scripts/initVM.sh .

chmod +x initVM.sh
bash initVM.sh <tên-node>
```

Chạy đúng tên node cho từng VM:

```bash
# Trên controller
bash initVM.sh controller

# Trên compute1
bash initVM.sh compute1

# Trên storage1
bash initVM.sh storage1

# Trên object1
bash initVM.sh object1

# Trên object2
bash initVM.sh object2
```

Output mong đợi (ví dụ controller):

```
======================================================
 initVM.sh - Initializing node: controller
======================================================

[1/4] Expanding OS disk (sda)...
    Done. Disk size: 39G

[2/4] Setting hostname to 'controller'...
    Done.

[3/4] Updating /etc/hosts...
    Done.

[4/4] Configuring network...
    Done.

======================================================
 Summary for node: controller
======================================================
 Hostname : controller
 Disk /   : 39G
 ens33    : 192.168.182.195
 ens37    : 192.168.225.195
 ens38    : 192.168.147.195

 Reboot recommended to apply all changes.
======================================================
```

Sau khi chạy xong, reboot:

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

**Bastion** - 1 adapter:

| Adapter | Kết nối vào | Mục đích |
|---|---|---|
| Network Adapter 1 | VMnet8 (NAT) | Internet / SSH đến các nodes |

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

> Chỉ thực hiện thủ công trên **bastion** - 1 lần duy nhất. Mọi thứ còn lại sẽ do Ansible lo.

### 4.1 Cấu hình network

```bash
apt update && apt upgrade -y
```

Sửa `/etc/netplan/50-cloud-init.yaml`:

```yaml
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
```

```bash
netplan apply
hostnamectl set-hostname bastion
```

Sửa `/etc/hosts`:

```
127.0.0.1          localhost
192.168.182.128    bastion

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
```

> Bastion cần resolve cả 2 dải: `192.168.182.x` để SSH trong giai đoạn chuẩn bị, `192.168.225.x` để Kolla-Ansible SSH sau khi flush `ens33`.

```bash
apt install -y ca-certificates curl gnupg

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

echo "deb [arch=$(dpkg --print-architecture) \
  signed-by=/etc/apt/keyrings/docker.asc] \
  https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  | tee /etc/apt/sources.list.d/docker.list > /dev/null

apt update
apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

### 4.3 Tạo SSH key và copy đến tất cả nodes

```bash
ssh-keygen -t ed25519 -C "kolla-ansible" -f ~/.ssh/id_ed25519 -N ""
```

Copy key đến tất cả nodes (nhập password root từng node):

```bash
ssh-copy-id -i ~/.ssh/id_ed25519.pub root@192.168.182.195   # controller
ssh-copy-id -i ~/.ssh/id_ed25519.pub root@192.168.182.196   # compute1
ssh-copy-id -i ~/.ssh/id_ed25519.pub root@192.168.182.197   # storage1
ssh-copy-id -i ~/.ssh/id_ed25519.pub root@192.168.182.198   # object1
ssh-copy-id -i ~/.ssh/id_ed25519.pub root@192.168.182.199   # object2
```

### 4.4 Clone repo và build Kolla-Ansible container

Copy thư mục project từ máy host hoặc dùng git nếu đã push lên remote:

```bash
# Nếu dùng git
git clone <repo-url> /opt/kolla

# Nếu chưa có remote repo, tạo thư mục thủ công
mkdir -p /opt/kolla
# Sau đó copy file lên bastion qua scp từ máy dev:
# scp -r ./OpenStack-Kolla-Ansible root@192.168.182.128:/opt/kolla/
```

Build và start container:

```bash
cd /opt/kolla/OpenStack-Kolla-Ansible/docker
docker compose up -d --build
```

Kiểm tra container đang chạy:

```bash
docker compose ps
```

```
NAME            IMAGE           COMMAND         STATUS
kolla-ansible   kolla-ansible   "/entrypoint…"  Up
```

Vào trong container để thực hiện tất cả các bước tiếp theo:

```bash
docker exec -it kolla-ansible bash
```

---

## 5. Chuẩn bị tất cả nodes bằng Ansible Playbook

> Thực hiện **bên trong container** `kolla-ansible`

Playbook `playbooks/prepare-nodes.yml` tự động hóa toàn bộ các bước:
- Cài Docker trên tất cả nodes
- Cấu hình NTP (controller làm server, các node còn lại làm client)
- Cấu hình network/netplan cho từng node
- Set hostname và `/etc/hosts`

### 5.1 Kiểm tra kết nối đến tất cả nodes

```bash
ansible -i inventory/all-nodes all -m ping
```

```
controller | SUCCESS => { "ping": "pong" }
compute1   | SUCCESS => { "ping": "pong" }
storage1   | SUCCESS => { "ping": "pong" }
object1    | SUCCESS => { "ping": "pong" }
object2    | SUCCESS => { "ping": "pong" }
```

### 5.2 Chạy playbook chuẩn bị

Chạy toàn bộ:

```bash
ansible-playbook -i inventory/all-nodes playbooks/prepare-nodes.yml
```

Hoặc chạy từng phần bằng tag:

```bash
# Chỉ cài Docker
ansible-playbook -i inventory/all-nodes playbooks/prepare-nodes.yml --tags docker

# Chỉ cấu hình NTP
ansible-playbook -i inventory/all-nodes playbooks/prepare-nodes.yml --tags ntp

# Chỉ cấu hình network
ansible-playbook -i inventory/all-nodes playbooks/prepare-nodes.yml --tags network

# Chỉ set hostname
ansible-playbook -i inventory/all-nodes playbooks/prepare-nodes.yml --tags hostname
```

Kết quả mong đợi khi chạy xong:

```
PLAY RECAP *********************************************************************
controller : ok=18  changed=12  unreachable=0  failed=0
compute1   : ok=16  changed=10  unreachable=0  failed=0
storage1   : ok=14  changed=9   unreachable=0  failed=0
object1    : ok=14  changed=9   unreachable=0  failed=0
object2    : ok=14  changed=9   unreachable=0  failed=0
```

---

## 6. Kiểm tra kết quả

> Thực hiện **bên trong container** `kolla-ansible`

```bash
ansible-playbook -i inventory/all-nodes playbooks/prepare-nodes.yml --tags verify
```

```
TASK [Print node status] *******************************************************
ok: [controller] => {
    "msg": "Node: controller\nDocker: active\nChrony: active\n"
}
ok: [compute1] => {
    "msg": "Node: compute1\nDocker: active\nChrony: active\n"
}
...
```

Kiểm tra NTP đồng bộ từ controller:

```bash
ansible -i inventory/all-nodes ntp_clients -m command -a "chronyc sources"
```

---

Tiếp theo: [02-kolla-ansible-setup.md](02-kolla-ansible-setup.md)
