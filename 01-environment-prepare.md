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
- Kolla-Ansible chạy trực tiếp trên **bastion** trong Python virtual environment
- Các bước chuẩn bị nodes (Docker, NTP, hostname) được tự động hóa bằng **Ansible playbook**

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

#### Bước 4 - Expand disk OS sau khi boot (chạy trên từng node)

Paste đoạn sau vào terminal của từng node, **thay tên node ở dòng cuối**:

```bash
NODE=controller   # ← đổi thành: compute1 | storage1 | object1 | object2

case $NODE in
  controller) IP_ENS33="192.168.182.195"; IP_ENS37="192.168.225.195"; IP_ENS38="192.168.147.195" ;;
  compute1)   IP_ENS33="192.168.182.196"; IP_ENS37="192.168.225.196"; IP_ENS38="192.168.147.196" ;;
  storage1)   IP_ENS33="192.168.182.197"; IP_ENS37="192.168.225.197"; IP_ENS38="" ;;
  object1)    IP_ENS33="192.168.182.198"; IP_ENS37="192.168.225.198"; IP_ENS38="" ;;
  object2)    IP_ENS33="192.168.182.199"; IP_ENS37="192.168.225.199"; IP_ENS38="" ;;
esac

# 1. Expand disk
apt-get install -y cloud-guest-utils > /dev/null 2>&1
growpart /dev/sda 3 || true
pvresize /dev/sda3
lvextend -l +100%FREE /dev/ubuntu-vg/ubuntu-lv || true
resize2fs /dev/ubuntu-vg/ubuntu-lv

# 2. Hostname
hostnamectl set-hostname "$NODE"

# 3. /etc/hosts
sed -i '/# OpenStack nodes/,/# END OpenStack nodes/d' /etc/hosts
cat >> /etc/hosts << EOF

# OpenStack nodes
192.168.225.195    controller
192.168.225.196    compute1
192.168.225.197    storage1
192.168.225.198    object1
192.168.225.199    object2
# END OpenStack nodes
EOF

# 4. Netplan
cp /etc/netplan/50-cloud-init.yaml /etc/netplan/50-cloud-init.yaml.bak
if [[ -n "$IP_ENS38" ]]; then
cat > /etc/netplan/50-cloud-init.yaml << EOF
network:
  version: 2
  ethernets:
    ens33:
      addresses: [${IP_ENS33}/24]
      routes: [{to: default, via: 192.168.182.2}]
      nameservers: {addresses: [8.8.8.8]}
    ens37:
      addresses: [${IP_ENS37}/24]
    ens38:
      addresses: [${IP_ENS38}/24]
EOF
else
cat > /etc/netplan/50-cloud-init.yaml << EOF
network:
  version: 2
  ethernets:
    ens33:
      addresses: [${IP_ENS33}/24]
      routes: [{to: default, via: 192.168.182.2}]
      nameservers: {addresses: [8.8.8.8]}
    ens37:
      addresses: [${IP_ENS37}/24]
EOF
fi
chmod 600 /etc/netplan/50-cloud-init.yaml
netplan apply

echo "Done: $(hostname) | $(df -h / | awk 'NR==2{print $2}') | $IP_ENS33"
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

## 5. Chuẩn bị tất cả nodes bằng Ansible Playbook

> Thực hiện trên **bastion**, đảm bảo đã `source /opt/kolla-venv/bin/activate`

### 5.1 Tạo inventory all-nodes

```bash
cat > ~/all-nodes << 'EOF'
[all_nodes]
controller  ansible_host=192.168.225.195 ansible_user=root ansible_become=True ansible_private_key_file=~/.ssh/id_ed25519
compute1    ansible_host=192.168.225.196 ansible_user=root ansible_become=True ansible_private_key_file=~/.ssh/id_ed25519
storage1    ansible_host=192.168.225.197 ansible_user=root ansible_become=True ansible_private_key_file=~/.ssh/id_ed25519
object1     ansible_host=192.168.225.198 ansible_user=root ansible_become=True ansible_private_key_file=~/.ssh/id_ed25519
object2     ansible_host=192.168.225.199 ansible_user=root ansible_become=True ansible_private_key_file=~/.ssh/id_ed25519

[core_nodes]
controller  ansible_host=192.168.225.195 ansible_user=root ansible_become=True ansible_private_key_file=~/.ssh/id_ed25519
compute1    ansible_host=192.168.225.196 ansible_user=root ansible_become=True ansible_private_key_file=~/.ssh/id_ed25519

[storage_nodes]
storage1    ansible_host=192.168.225.197 ansible_user=root ansible_become=True ansible_private_key_file=~/.ssh/id_ed25519

[object_nodes]
object1     ansible_host=192.168.225.198 ansible_user=root ansible_become=True ansible_private_key_file=~/.ssh/id_ed25519
object2     ansible_host=192.168.225.199 ansible_user=root ansible_become=True ansible_private_key_file=~/.ssh/id_ed25519

[ntp_server]
controller  ansible_host=192.168.225.195 ansible_user=root ansible_become=True ansible_private_key_file=~/.ssh/id_ed25519

[ntp_clients]
compute1    ansible_host=192.168.225.196 ansible_user=root ansible_become=True ansible_private_key_file=~/.ssh/id_ed25519
storage1    ansible_host=192.168.225.197 ansible_user=root ansible_become=True ansible_private_key_file=~/.ssh/id_ed25519
object1     ansible_host=192.168.225.198 ansible_user=root ansible_become=True ansible_private_key_file=~/.ssh/id_ed25519
object2     ansible_host=192.168.225.199 ansible_user=root ansible_become=True ansible_private_key_file=~/.ssh/id_ed25519

[all:vars]
ansible_python_interpreter=/usr/bin/python3
EOF
```

### 5.2 Tạo prepare-nodes.yml

```bash
cat > ~/prepare-nodes.yml << 'EOF'
---
# ─────────────────────────────────────────────────────────────────
# PLAY 0: Fix system time trước khi làm bất cứ thứ gì
# VM mới clone thường bị lệch giờ → apt update fail
# ─────────────────────────────────────────────────────────────────
- name: Fix system time on all nodes
  hosts: all_nodes
  become: true
  ignore_unreachable: true
  gather_facts: false
  tasks:
    - name: Install chrony if not present
      apt:
        name: chrony
        state: present
        update_cache: false
      ignore_errors: true

    - name: Force immediate time sync
      shell: chronyc makestep
      ignore_errors: true

    - name: Show current time
      shell: date
      register: current_time
      changed_when: false

    - name: Print time
      debug:
        msg: "{{ inventory_hostname }}: {{ current_time.stdout }}"

# ─────────────────────────────────────────────────────────────────
# PLAY 1: Common setup
# ─────────────────────────────────────────────────────────────────
- name: Common setup for all nodes
  hosts: all_nodes
  become: true
  gather_facts: true
  ignore_unreachable: true
  tasks:
    - name: Update apt cache
      apt:
        update_cache: yes
        cache_valid_time: 3600
      tags: [common, packages]

    - name: Install common packages
      apt:
        name: [python3-pip, git, curl, vim, net-tools, ca-certificates, gnupg]
        state: present
      tags: [common, packages]

- name: Install Docker on all nodes
  hosts: all_nodes
  become: true
  ignore_unreachable: true
  tasks:
    - name: Create /etc/apt/keyrings directory
      file:
        path: /etc/apt/keyrings
        state: directory
        mode: '0755'
      tags: docker

    - name: Download Docker GPG key
      get_url:
        url: https://download.docker.com/linux/ubuntu/gpg
        dest: /etc/apt/keyrings/docker.asc
        mode: '0644'
      tags: docker

    - name: Add Docker apt repository
      apt_repository:
        repo: >-
          deb [arch={{ ansible_architecture | replace('x86_64', 'amd64') }}
          signed-by=/etc/apt/keyrings/docker.asc]
          https://download.docker.com/linux/ubuntu
          {{ ansible_distribution_release }} stable
        state: present
        filename: docker
      tags: docker

    - name: Install Docker packages
      apt:
        name: [docker-ce, docker-ce-cli, containerd.io, docker-buildx-plugin]
        state: present
        update_cache: yes
      tags: docker

    - name: Configure Docker daemon
      copy:
        dest: /etc/docker/daemon.json
        content: |
          {
            "log-driver": "json-file",
            "log-opts": { "max-size": "50m", "max-file": "5" }
          }
      tags: docker

    - name: Start and enable Docker
      systemd:
        name: docker
        state: restarted
        enabled: yes
      tags: docker

- name: Configure NTP server on controller
  hosts: ntp_server
  become: true
  ignore_unreachable: true
  tasks:
    - name: Install and configure chrony as server
      apt:
        name: chrony
        state: present
      tags: ntp

    - name: Configure chrony server
      copy:
        dest: /etc/chrony/chrony.conf
        content: |
          server 1.vn.pool.ntp.org iburst
          server 0.asia.pool.ntp.org iburst
          allow 192.168.225.0/24
          driftfile /var/lib/chrony/drift
          makestep 1.0 3
          rtcsync
      tags: ntp

    - name: Restart chrony
      systemd:
        name: chrony
        state: restarted
        enabled: yes
      tags: ntp

- name: Configure NTP clients
  hosts: ntp_clients
  become: true
  ignore_unreachable: true
  tasks:
    - name: Install chrony
      apt:
        name: chrony
        state: present
      tags: ntp

    - name: Configure chrony client
      copy:
        dest: /etc/chrony/chrony.conf
        content: |
          server 192.168.225.195 iburst
          driftfile /var/lib/chrony/drift
          makestep 1.0 3
          rtcsync
      tags: ntp

    - name: Restart chrony
      systemd:
        name: chrony
        state: restarted
        enabled: yes
      tags: ntp

- name: Verify all nodes are ready
  hosts: all_nodes
  become: true
  ignore_unreachable: true
  tasks:
    - name: Check Docker is running
      systemd:
        name: docker
      register: docker_status
      tags: verify

    - name: Check chrony is running
      systemd:
        name: chrony
      register: chrony_status
      tags: verify

    - name: Print node status
      debug:
        msg: "{{ inventory_hostname }} | Docker: {{ docker_status.status.ActiveState }} | Chrony: {{ chrony_status.status.ActiveState }}"
      tags: verify
EOF
```

### 5.3 Kiểm tra kết nối

```bash
ansible -i ~/all-nodes all -m ping
```

```
controller | SUCCESS => { "ping": "pong" }
compute1   | SUCCESS => { "ping": "pong" }
...
```

### 5.4 Chạy playbook

```bash
ansible-playbook -i ~/all-nodes ~/prepare-nodes.yml
```

Chạy từng phần:

```bash
ansible-playbook -i ~/all-nodes ~/prepare-nodes.yml --tags docker
ansible-playbook -i ~/all-nodes ~/prepare-nodes.yml --tags ntp
```

---

## 6. Kiểm tra kết quả

### 6.1 Kiểm tra Docker và Chrony đang chạy

```bash
ansible-playbook -i ~/all-nodes ~/prepare-nodes.yml --tags verify
```

```
ok: [controller] => { "msg": "controller | Docker: active | Chrony: active" }
ok: [compute1]   => { "msg": "compute1 | Docker: active | Chrony: active" }
...
```

### 6.2 Kiểm tra các node đã sync time từ controller

```bash
ansible -i ~/all-nodes ntp_clients -m command -a "chronyc sources -v"
```

Kết quả mong đợi - mỗi node phải thấy `controller` là source và có dấu `*` (đang sync):

```
compute1 | CHANGED | rc=0 >>
  .-- Source mode  '^' = server, '=' = peer, '#' = local clock.
 / .- Source state '*' = current best, '+' = combined, '-' = not combined,
| / '?' = unreachable, 'x' = time may be in error, '~' = time too variable.
||                                                 .- xxxx [ yyyy ] +/- zzzz
||      Reachable?  .                             /   xxxx = adjusted offset,
||      |           |                            |    yyyy = measured offset,
||      |           |                            |    zzzz = estimated error.
||      |           |                            |
MS Name/IP address         Stratum Poll Reach LastRx Last sample
===============================================================================
^* 192.168.225.195               3   6   377    42   +123us[ +456us] +/-  10ms
```

> Dấu `^*` trước `192.168.225.195` (controller) là quan trọng nhất - nghĩa là node đang sync từ controller. Nếu thấy `^?` thì chrony chưa reach được controller, kiểm tra lại firewall hoặc chrony config trên controller.

### 6.3 Kiểm tra độ lệch thời gian

```bash
ansible -i ~/all-nodes all_nodes -m command -a "chronyc tracking"
```

Chú ý dòng `System time` - lệch không quá 1 giây là ổn:

```
compute1 | CHANGED | rc=0 >>
Reference ID    : C0A8E1C3 (192.168.225.195)
Stratum         : 4
System time     : 0.000123456 seconds fast of NTP time
Last offset     : +0.000123456 seconds
RMS offset      : 0.000234567 seconds
Frequency       : 12.345 ppm fast
...
```

> `Reference ID` phải là `192.168.225.195` (controller). Nếu thấy IP khác hoặc `INIT` thì chrony chưa sync xong, đợi thêm 1-2 phút rồi chạy lại.

---

Tiếp theo: [02-kolla-ansible-setup.md](02-kolla-ansible-setup.md)
