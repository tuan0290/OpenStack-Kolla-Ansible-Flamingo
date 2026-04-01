# Cài đặt Load Balancer (Octavia)

> Thực hiện trên node **bastion**

## Mục lục

1. [Chuẩn bị Octavia Amphora image](#1-chuẩn-bị-octavia-amphora-image)
2. [Cấu hình globals.yml](#2-cấu-hình-globalsyml)
3. [Deploy Octavia](#3-deploy-octavia)
4. [Kiểm tra Octavia](#4-kiểm-tra-octavia)
5. [Tạo Load Balancer đầu tiên](#5-tạo-load-balancer-đầu-tiên)

---

## 1. Chuẩn bị Octavia Amphora image

Octavia dùng một VM đặc biệt gọi là **Amphora** để làm load balancer. Cần build hoặc download image này trước.

### 1.1 Download Amphora image có sẵn

Kolla-Ansible cung cấp script build Amphora image, nhưng trong lab có thể dùng image pre-built:

```bash
# Cài diskimage-builder
pip install diskimage-builder

# Clone octavia repo để lấy script build
git clone https://opendev.org/openstack/octavia -b stable/2025.2 /tmp/octavia
cd /tmp/octavia

# Build amphora image (mất ~15-20 phút)
./diskimage-create/diskimage-create.sh \
  -i ubuntu-minimal \
  -o /tmp/amphora-x64-haproxy.qcow2
```

> Nếu không muốn build, có thể download image pre-built từ community. Tuy nhiên build từ source đảm bảo version khớp với Octavia đang deploy.

### 1.2 Upload Amphora image lên Glance

```bash
source /etc/kolla/admin-openrc.sh

openstack image create \
  --container-format bare \
  --disk-format qcow2 \
  --private \
  --tag amphora \
  --file /tmp/amphora-x64-haproxy.qcow2 \
  amphora-x64-haproxy
```

---

## 2. Cấu hình globals.yml

Thêm vào `/etc/kolla/globals.yml`:

```yaml
# Octavia
enable_octavia: "yes"

# Network cho Amphora management (Octavia tự tạo network này)
octavia_network_interface: "ens37"
```

Kolla-Ansible sẽ tự động:
- Tạo Octavia management network (`lb-mgmt-net`)
- Tạo security group cho Amphora
- Tạo keypair cho SSH vào Amphora
- Tạo flavor cho Amphora VM

---

## 3. Deploy Octavia

```bash
kolla-ansible -i ~/multinode pull --tags octavia
kolla-ansible -i ~/multinode deploy --tags octavia
```

Kiểm tra container trên controller:

```bash
ssh root@192.168.225.195 \
  "docker ps --format 'table {{.Names}}\t{{.Status}}' | grep octavia"
```

```
octavia_api               Up 2 minutes
octavia_driver_agent      Up 2 minutes
octavia_health_manager    Up 2 minutes
octavia_housekeeping      Up 2 minutes
octavia_worker            Up 2 minutes
```

---

## 4. Kiểm tra Octavia

```bash
source /etc/kolla/admin-openrc.sh
openstack loadbalancer list
```

```
(empty - chưa có LB nào)
```

Kiểm tra Octavia service:

```bash
openstack loadbalancer flavor list
openstack loadbalancer flavorprofile list
```

---

## 5. Tạo Load Balancer đầu tiên

### 5.1 Chuẩn bị: tạo 2 instance backend

```bash
# Tạo 2 instance làm backend
openstack server create \
  --flavor m1.tiny --image cirros-0.6.2 \
  --network selfservice --security-group default \
  backend-1

openstack server create \
  --flavor m1.tiny --image cirros-0.6.2 \
  --network selfservice --security-group default \
  backend-2
```

Lấy IP của 2 backend:

```bash
openstack server list --name backend
```

```
+------+----------+--------+------------------------+
| ID   | Name     | Status | Networks               |
+------+----------+--------+------------------------+
| ...  | backend-1| ACTIVE | selfservice=10.0.0.10  |
| ...  | backend-2| ACTIVE | selfservice=10.0.0.11  |
+------+----------+--------+------------------------+
```

### 5.2 Tạo Load Balancer

```bash
# Tạo LB trên selfservice network
openstack loadbalancer create \
  --name test-lb \
  --vip-subnet-id selfservice-subnet

# Chờ LB active (mất ~2-3 phút để Amphora VM boot)
watch openstack loadbalancer show test-lb -c provisioning_status
```

```
+---------------------+--------+
| Field               | Value  |
+---------------------+--------+
| provisioning_status | ACTIVE |
+---------------------+--------+
```

### 5.3 Tạo Listener, Pool và Members

```bash
# Tạo listener HTTP port 80
openstack loadbalancer listener create \
  --name test-listener \
  --protocol HTTP \
  --protocol-port 80 \
  test-lb

# Tạo pool với thuật toán ROUND_ROBIN
openstack loadbalancer pool create \
  --name test-pool \
  --lb-algorithm ROUND_ROBIN \
  --listener test-listener \
  --protocol HTTP

# Thêm backend members vào pool
openstack loadbalancer member create \
  --subnet-id selfservice-subnet \
  --address 10.0.0.10 \
  --protocol-port 80 \
  test-pool

openstack loadbalancer member create \
  --subnet-id selfservice-subnet \
  --address 10.0.0.11 \
  --protocol-port 80 \
  test-pool
```

### 5.4 Gán Floating IP cho LB

```bash
# Lấy VIP port của LB
LB_VIP_PORT=$(openstack loadbalancer show test-lb -f value -c vip_port_id)

# Tạo và gán floating IP
openstack floating ip create \
  --port $LB_VIP_PORT \
  provider
```

---

Trước: [08-heat.md](08-heat.md) | Tiếp theo: [10-ceilometer.md](10-ceilometer.md)

---

## Hỏi & Đáp

### Amphora là gì và tại sao Octavia cần VM riêng?

Octavia dùng mô hình **Amphora** - mỗi load balancer là một VM nhỏ chạy HAProxy bên trong:

```
Client → Floating IP → Amphora VM (HAProxy) → Backend VMs
```

Lý do dùng VM thay vì namespace như Neutron LBaaS cũ:
- **Isolation**: Mỗi LB là VM riêng, lỗi 1 LB không ảnh hưởng LB khác
- **Scale**: Có thể tạo hàng nghìn LB độc lập
- **HA**: Octavia hỗ trợ Active-Standby Amphora pair tự động failover
- **Flexibility**: Có thể SSH vào Amphora để debug

Nhược điểm: Tốn tài nguyên hơn (mỗi LB cần 1 VM), boot chậm hơn (~2-3 phút).

---

### Octavia Active-Standby hoạt động như thế nào?

```
Client
  │
  ▼
Floating IP (VIP)
  │
  ├── Amphora-Active (HAProxy đang xử lý traffic)
  │       │ heartbeat mỗi 1 giây
  └── Amphora-Standby (sẵn sàng takeover)
              │
              │ Nếu Active không heartbeat trong 10 giây
              ▼
         Standby → Active (takeover VIP)
         Octavia tạo Amphora mới → Standby
```

Enable Active-Standby khi tạo LB:

```bash
openstack loadbalancer create \
  --name ha-lb \
  --vip-subnet-id selfservice-subnet \
  --flavor amphora-ha    # flavor có topology ACTIVE_STANDBY
```
