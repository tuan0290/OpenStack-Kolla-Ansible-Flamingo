# Cấu hình globals.yml và Inventory

> Thực hiện **bên trong container** `kolla-ansible` trên bastion

## Mục lục

1. [Cấu hình globals.yml](#1-cấu-hình-globalsyml)
2. [Cấu hình multinode inventory](#2-cấu-hình-multinode-inventory)
3. [Cấu hình Local Docker Registry](#3-cấu-hình-local-docker-registry)
4. [Kiểm tra inventory](#4-kiểm-tra-inventory)

---

## 1. Cấu hình globals.yml

`globals.yml` là file cấu hình trung tâm của Kolla-Ansible. File này nằm tại `/kolla/config/kolla/globals.yml` (mount vào `/etc/kolla/globals.yml` bên trong container).

```bash
vim /etc/kolla/globals.yml
```

### 1.1 Base configuration

```yaml
openstack_release: "2025.2"
kolla_base_distro: "ubuntu"
kolla_install_type: "binary"
```

### 1.2 Network interfaces

```yaml
# Interface Management - Kolla dùng để giao tiếp nội bộ giữa các service
network_interface: "ens37"

# Interface Provider/External - KHÔNG được có IP
# Kolla sẽ gán vào OVS bridge br-ex khi deploy Neutron
neutron_external_interface: "ens33"

# Interface Tunnel - OVN Geneve overlay
tunnel_interface: "ens38"
```

> **Quan trọng:** Docs chính thức yêu cầu `neutron_external_interface` phải không có IP address. Prechecks sẽ fail nếu `ens33` đang có IP. Xem mục [Xử lý ens33 trước khi deploy](#xử-lý-ens33-trước-khi-deploy) bên dưới.

### 1.3 VIP addresses

```yaml
# VIP cho internal API (Management network - ens37)
kolla_internal_vip_address: "192.168.225.195"

# VIP cho external access - Horizon, public API (Provider network)
# Đây là IP trên br-ex sau khi Kolla deploy Neutron
kolla_external_vip_address: "192.168.182.195"
```

> Trong lab single-controller, VIP trùng với IP của controller. Trong production multi-controller, VIP là IP riêng được Keepalived quản lý.
>
> Nếu có nhiều Keepalived cluster trong cùng L2 network, cần set `keepalived_virtual_router_id` thành giá trị unique (0-255) để tránh xung đột:
> ```yaml
> keepalived_virtual_router_id: "51"
> ```

### 1.4 HAProxy và Services

```yaml
enable_haproxy: "yes"
```

### 1.5 Neutron / OVN

```yaml
neutron_plugin_agent: "ovn"
enable_neutron_provider_networks: "yes"
neutron_ovn_distributed_fip: "yes"
```

### 1.6 Nova

```yaml
# QEMU cho VMware lab (nested virt), KVM cho bare metal
nova_compute_virt_type: "qemu"
```

### 1.7 File globals.yml hoàn chỉnh

```yaml
---
# Kolla-Ansible globals.yml - OpenStack Flamingo (2025.2)

openstack_release: "2025.2"
kolla_base_distro: "ubuntu"
kolla_install_type: "binary"

# Network interfaces
network_interface: "ens37"
neutron_external_interface: "ens33"
tunnel_interface: "ens38"

# VIP addresses
kolla_internal_vip_address: "192.168.225.195"
kolla_external_vip_address: "192.168.182.195"

# Local Docker registry (xem mục 3)
docker_registry: "192.168.182.128:4000"
docker_registry_insecure: "yes"

# HAProxy
enable_haproxy: "yes"

# Neutron OVN
neutron_plugin_agent: "ovn"
enable_neutron_provider_networks: "yes"
neutron_ovn_distributed_fip: "yes"

# Nova
nova_compute_virt_type: "qemu"
```

### 1.8 Xử lý ens33 trước khi deploy

Prechecks của Kolla-Ansible sẽ fail nếu `neutron_external_interface` (`ens33`) đang có IP. Cần xóa IP trên `ens33` trước khi chạy deploy.

Thêm task này vào cuối playbook `prepare-nodes.yml`, hoặc chạy thủ công trên controller và compute1:

```bash
# Chạy từ container, trước bước prechecks
ansible -i /kolla/inventory/multinode control,compute \
  -m shell \
  -a "ip addr flush dev ens33"
```

Hoặc thêm vào playbook `prepare-nodes.yml` (xem file playbook):

```bash
ansible-playbook -i /kolla/inventory/all-nodes playbooks/prepare-nodes.yml \
  --tags flush-ens33
```

> Sau khi flush IP, SSH từ bastion đến controller/compute qua `192.168.182.x` sẽ mất. Đây là bình thường - Kolla sẽ SSH qua Management IP (`ens37`) từ đây trở đi vì inventory dùng `ansible_host` trỏ đến `192.168.182.x` chỉ cho giai đoạn chuẩn bị. Cần update inventory trước khi deploy - xem mục 2.

### 1.9 globals.d - Cấu hình modular cho từng service

Thay vì nhét tất cả vào `globals.yml`, có thể tách cấu hình từng service ra file riêng trong `globals.d/`:

```bash
mkdir -p /etc/kolla/globals.d
```

Ví dụ, khi thêm Cinder sau này:

```bash
cat > /etc/kolla/globals.d/cinder.yml << 'EOF'
enable_cinder: "yes"
enable_cinder_backend_lvm: "yes"
cinder_volume_group: "cinder-volumes"
EOF
```

Kolla-Ansible tự động load tất cả `*.yml` trong `globals.d/`. Cách này giúp quản lý cấu hình gọn hơn khi có nhiều service.

---

## 2. Cấu hình multinode inventory

File inventory nằm tại `/kolla/inventory/multinode`.

> **Lưu ý quan trọng từ docs chính thức:** RabbitMQ không hoạt động với IP address thuần - nó cần hostname resolvable. Inventory dùng tên hostname (controller, compute1) kết hợp với `ansible_host` để SSH, đảm bảo RabbitMQ cluster hoạt động đúng.

File `inventory/multinode` đã được cấu hình sẵn với đầy đủ các tham số:

```ini
[control]
controller ansible_host=192.168.182.195 ansible_user=root ansible_become=True ansible_private_key_file=/root/.ssh/id_ed25519

[network]
controller ansible_host=192.168.182.195 ansible_user=root ansible_become=True ansible_private_key_file=/root/.ssh/id_ed25519

[compute]
compute1 ansible_host=192.168.182.196 ansible_user=root ansible_become=True ansible_private_key_file=/root/.ssh/id_ed25519

[monitoring]
controller ansible_host=192.168.182.195 ansible_user=root ansible_become=True ansible_private_key_file=/root/.ssh/id_ed25519

[storage]
controller ansible_host=192.168.182.195 ansible_user=root ansible_become=True ansible_private_key_file=/root/.ssh/id_ed25519
```

Giải thích các tham số:
- `ansible_host` - IP để SSH (Provider IP, vì bastion chỉ có NAT)
- `ansible_user=root` - user SSH
- `ansible_become=True` - cho phép privilege escalation (sudo)
- `ansible_private_key_file` - SSH key path bên trong container (mount từ `~/.ssh` của bastion)

> **Sau khi flush ens33:** Nếu đã xóa IP trên `ens33`, cần đổi `ansible_host` sang Management IP (`192.168.225.x`) để Kolla-Ansible tiếp tục SSH được trong quá trình deploy. Xem bước này trong [04-deploy.md](04-deploy.md).

---

## 3. Cấu hình Local Docker Registry

Docs chính thức khuyến nghị dùng local registry cho multinode deployment để tránh pull image từ internet nhiều lần (mỗi node pull riêng).

### 3.1 Chạy registry trên Bastion

Chạy lệnh này **trên bastion host** (không phải trong container):

```bash
docker run -d \
  --network host \
  --name registry \
  --restart=always \
  -e REGISTRY_HTTP_ADDR=0.0.0.0:4000 \
  -v registry:/var/lib/registry \
  registry:2
```

> Port 4000 để tránh xung đột với Keystone (port 5000).

Kiểm tra registry đang chạy:

```bash
curl http://192.168.182.128:4000/v2/
```

```
{}
```

### 3.2 Pull và push images vào local registry

Từ bên trong container kolla-ansible:

```bash
kolla-ansible -i /kolla/inventory/multinode pull
kolla-ansible -i /kolla/inventory/multinode push
```

Lệnh `push` sẽ tag lại tất cả images và push vào registry `192.168.182.128:4000`.

### 3.3 Cấu hình các nodes dùng insecure registry

Playbook `prepare-nodes.yml` đã có task cấu hình Docker daemon với insecure registry. Kiểm tra:

```bash
ansible -i /kolla/inventory/all-nodes all_nodes \
  -m shell -a "cat /etc/docker/daemon.json"
```

```json
{
  "insecure-registries": ["192.168.182.128:4000"]
}
```

---

## 4. Kiểm tra inventory

### 4.1 Ping tất cả nodes

```bash
ansible -i /kolla/inventory/multinode all -m ping
```

```
controller | SUCCESS => { "ping": "pong" }
compute1   | SUCCESS => { "ping": "pong" }
localhost  | SUCCESS => { "ping": "pong" }
```

### 4.2 Kiểm tra hostname resolvable (RabbitMQ requirement)

```bash
ansible -i /kolla/inventory/multinode baremetal \
  -m shell -a "getent hosts controller"
```

```
controller | CHANGED | rc=0 >>
192.168.225.195 controller
```

Tất cả nodes phải resolve được hostname `controller` và `compute1`.

### 4.3 Kiểm tra ens33 không có IP

```bash
ansible -i /kolla/inventory/multinode control,compute \
  -m shell -a "ip addr show ens33 | grep 'inet '"
```

Kết quả phải trống (không có IP) trước khi chạy prechecks.

### 4.4 Kiểm tra Docker trên tất cả nodes

```bash
ansible -i /kolla/inventory/multinode baremetal \
  -m shell -a "docker --version"
```

---

Tiếp theo: [04-deploy.md](04-deploy.md)

---

## Hỏi & Đáp

### Tại sao RabbitMQ không dùng được IP thuần?

RabbitMQ cluster dùng Erlang distribution protocol để các node giao tiếp với nhau. Erlang node name có format `rabbit@<hostname>` - nó dùng hostname, không phải IP. Khi cluster cần resolve `rabbit@controller`, nó lookup hostname `controller` trong DNS hoặc `/etc/hosts`.

Nếu inventory chỉ có IP (không có hostname), RabbitMQ sẽ tạo node name kiểu `rabbit@192.168.225.195` - Erlang không thể resolve IP dạng này trong cluster mode.

Đó là lý do inventory dùng `controller` làm hostname entry, kết hợp với `ansible_host=192.168.182.195` để SSH. Kolla-Ansible dùng hostname để cấu hình RabbitMQ, dùng `ansible_host` để SSH.

---

### kolla_internal_vip_address và kolla_external_vip_address khác nhau thế nào?

```
kolla_internal_vip_address (192.168.225.195 - Management network)
    │
    │ Giao tiếp nội bộ giữa các service
    │ Nova → Keystone, Glance → Keystone...
    ▼
HAProxy :5000 → Keystone
HAProxy :8774 → Nova API
HAProxy :9292 → Glance
HAProxy :9696 → Neutron

kolla_external_vip_address (192.168.182.195 - Provider network / br-ex)
    │
    │ Truy cập từ bên ngoài
    ▼
HAProxy :80   → Horizon
HAProxy :5000 → Keystone public endpoint
```

---

### globals.d có ưu tiên hơn globals.yml không?

Không - cả hai đều được load với cùng mức ưu tiên (đều là "extra vars" trong Ansible). Nếu cùng key xuất hiện ở cả hai nơi, file nào được load sau sẽ thắng. Kolla load `globals.yml` trước, sau đó load từng file trong `globals.d/` theo thứ tự alphabetical.

Best practice: giữ core config trong `globals.yml`, mỗi service optional thêm vào `globals.d/<service>.yml`.
