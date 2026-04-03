# Bootstrap, Prechecks và Deploy

> Thực hiện trên **bastion**. Đảm bảo venv đang active: `source /opt/kolla-venv/bin/activate`

## Mục lục

1. [Bootstrap servers](#1-bootstrap-servers)
2. [Pull Docker images](#2-pull-docker-images)
3. [Flush IP trên ens33](#3-flush-ip-trên-ens33)
4. [Prechecks](#4-prechecks)
5. [Deploy](#5-deploy)
6. [Validate config](#6-validate-config)
7. [Theo dõi quá trình deploy](#7-theo-dõi-quá-trình-deploy)
8. [Xử lý lỗi thường gặp](#8-xử-lý-lỗi-thường-gặp)

---

## 1. Bootstrap servers

Bootstrap cài đặt các dependency cần thiết trên tất cả nodes. **Cần internet** - thực hiện trước khi flush ens33.

```bash
kolla-ansible bootstrap-servers -i ~/multinode
```

Kết quả mong đợi:

```
PLAY RECAP *********************************************************************
controller                 : ok=32  changed=8   unreachable=0  failed=0
compute1                   : ok=28  changed=6   unreachable=0  failed=0
localhost                  : ok=5   changed=0   unreachable=0  failed=0
```

Bootstrap thực hiện trên **controller và compute1** (các node trong `~/multinode`):
- Cài `python3-docker`, `python3-mysqldb` và các Python packages cần thiết
- Cấu hình Docker daemon (log driver, storage driver...)
- Tạo user `kolla` và cấu hình sudo

---

## 2. Pull Docker images

Pull tất cả images cần thiết (~30-60 phút tùy tốc độ mạng). **Cần internet** - thực hiện trước khi flush ens33.

```bash
kolla-ansible pull -i ~/multinode
```

Theo dõi tiến trình trên controller (mở terminal khác):

```bash
ssh root@192.168.225.195
watch -n 2 "docker images | grep kolla | wc -l"
```

---

## 3. Flush IP trên ens33

Sau khi bootstrap và pull xong, mới flush ens33. Kolla-Ansible prechecks yêu cầu `neutron_external_interface` không được có IP.

```bash
ansible -i ~/multinode control,compute -m shell -a "
  ip addr flush dev ens33
  ip link set ens33 up
  ip addr add 192.168.182.1/24 dev ens33
  ip route replace default via 192.168.182.2 dev ens33
  echo 'nameserver 8.8.8.8' > /etc/resolv.conf
"
```

> Giữ lại default route và DNS để Kolla-Ansible vẫn có thể pull image bổ sung nếu cần trong quá trình deploy.

---

## 4. Prechecks

Prechecks kiểm tra tất cả điều kiện tiên quyết. Phải pass 100% mới deploy.

```bash
kolla-ansible prechecks -i ~/multinode
```

Kết quả mong đợi:

```
PLAY RECAP *********************************************************************
controller                 : ok=85  changed=0   unreachable=0  failed=0
compute1                   : ok=42  changed=0   unreachable=0  failed=0
localhost                  : ok=12  changed=0   unreachable=0  failed=0
```

**Các lỗi prechecks thường gặp:**

| Lỗi | Nguyên nhân | Cách sửa |
|---|---|---|
| `Interface ens33 has IP address` | `neutron_external_interface` còn IP | Chạy lại bước 1 |
| `Interface ens33 not found` | Tên interface sai | Kiểm tra `ip a` trên node, sửa globals.yml |
| `Docker is not running` | Docker chưa start | `systemctl start docker` trên node đó |
| `Hostname mismatch` | Hostname không khớp inventory | Sửa `/etc/hostname` hoặc inventory |
| `NTP not synchronized` | Đồng hồ lệch | Kiểm tra chrony: `chronyc tracking` |
| `Hostname not resolvable` | `/etc/hosts` thiếu entry | Kiểm tra `/etc/hosts` trên tất cả nodes |

---

## 5. Deploy

```bash
kolla-ansible deploy -i ~/multinode
```

> Mất khoảng **20-40 phút**. Kolla-Ansible deploy theo thứ tự: MariaDB → RabbitMQ → Memcached → HAProxy → Keystone → Glance → Placement → Nova → Neutron/OVN → Horizon.

---

## 6. Validate config

Sau khi deploy xong, chạy validate để kiểm tra cấu hình các service:

```bash
kolla-ansible validate-config -i ~/multinode
```

> Docs chính thức: validate chỉ chạy được sau lần deploy đầu tiên vì cần access vào running containers.

---

## 7. Theo dõi quá trình deploy

Mở terminal khác, SSH vào controller để theo dõi:

```bash
ssh root@192.168.225.195
watch -n 3 "docker ps --format 'table {{.Names}}\t{{.Status}}' | sort"
```

Khi deploy xong trên controller, các container chính phải đang chạy:

```
NAMES                          STATUS
fluentd                        Up x minutes
glance_api                     Up x minutes
haproxy                        Up x minutes
horizon                        Up x minutes
keystone                       Up x minutes
mariadb                        Up x minutes
memcached                      Up x minutes
neutron_ovn_metadata_agent     Up x minutes
neutron_server                 Up x minutes
nova_api                       Up x minutes
nova_conductor                 Up x minutes
nova_novncproxy                Up x minutes
nova_scheduler                 Up x minutes
ovn_controller                 Up x minutes
ovn_nb_db                      Up x minutes
ovn_northd                     Up x minutes
ovn_sb_db                      Up x minutes
placement_api                  Up x minutes
proxysql                       Up x minutes
rabbitmq                       Up x minutes
```

> Kolla 2025.2 có thêm container `proxysql` so với các bản trước.

Trên compute1:

```bash
ssh root@192.168.225.196
docker ps --format 'table {{.Names}}\t{{.Status}}'
```

```
NAMES                          STATUS
nova_compute                   Up x minutes
nova_libvirt                   Up x minutes
nova_ssh                       Up x minutes
ovn_controller                 Up x minutes
neutron_ovn_metadata_agent     Up x minutes
```

---

## 8. Xử lý lỗi thường gặp

### Deploy bị lỗi giữa chừng

Kolla-Ansible deploy là idempotent - chạy lại nhiều lần không gây hại:

```bash
kolla-ansible deploy -i ~/multinode -vvv 2>&1 | tee /tmp/deploy.log
```

### Container không start

```bash
# SSH vào node có container lỗi
docker logs keystone
docker logs neutron_server
docker logs mariadb
```

### Cleanup và deploy lại từ đầu

```bash
kolla-ansible destroy -i ~/multinode --yes-i-really-really-mean-it
kolla-ansible deploy -i ~/multinode
```

### Reconfigure sau khi sửa globals.yml

```bash
kolla-ansible reconfigure -i ~/multinode
```

### Upgrade lên version mới

```bash
kolla-ansible pull -i ~/multinode
kolla-ansible upgrade -i ~/multinode
```

---

Tiếp theo: [04-post-deploy.md](04-post-deploy.md)

---

## Hỏi & Đáp

### Kolla-Ansible deploy theo thứ tự nào và tại sao?

```
MariaDB → RabbitMQ → Memcached
    │           │          │
    │           │          └── Keystone cần Memcached để cache token
    │           └──────────── Tất cả service cần RabbitMQ để gửi event
    └──────────────────────── Tất cả service cần DB để lưu state

Keystone → Glance → Placement → Nova → Neutron → Horizon
    │           │          │       │        │
    │           │          │       │        └── Neutron cần Nova để notify port changes
    │           │          │       └──────────── Nova cần Placement để track resource
    │           │          └──────────────────── Placement cần Keystone để auth
    │           └─────────────────────────────── Glance cần Keystone để auth
    └─────────────────────────────────────────── Keystone là identity provider cho tất cả
```

### Tại sao cần bước `pull` riêng trước `deploy`?

`deploy` cũng tự pull image nếu chưa có, nhưng tách ra có lợi:

- Pull tốn nhiều thời gian và bandwidth - làm riêng để biết chính xác bao lâu
- Nếu pull lỗi mạng, chỉ cần chạy lại `pull` mà không ảnh hưởng deploy
- Sau khi pull xong có thể deploy offline

### validate-config kiểm tra gì?

Khác với `prechecks` (kiểm tra OS/network trước deploy), `validate-config` chạy sau deploy và kiểm tra application-level:
- File config được generate đúng format
- Kết nối đến database, RabbitMQ hoạt động
- Endpoint URL đúng

Chỉ chạy được sau lần deploy đầu tiên vì cần access vào running containers.
