# Bootstrap, Prechecks và Deploy

> Thực hiện **bên trong container** `kolla-ansible` trên bastion

## Mục lục

1. [Flush IP trên ens33](#1-flush-ip-trên-ens33)
2. [Bootstrap servers](#2-bootstrap-servers)
3. [Pull và Push Docker images](#3-pull-và-push-docker-images)
4. [Prechecks](#4-prechecks)
5. [Deploy](#5-deploy)
6. [Validate config](#6-validate-config)
7. [Theo dõi quá trình deploy](#7-theo-dõi-quá-trình-deploy)
8. [Xử lý lỗi thường gặp](#8-xử-lý-lỗi-thường-gặp)

---

## 1. Flush IP trên ens33

Kolla-Ansible prechecks yêu cầu `neutron_external_interface` (`ens33`) **không được có IP**. Cần xóa IP trước khi chạy prechecks.

```bash
ansible -i /kolla/inventory/multinode control,compute \
  -m shell \
  -a "ip addr flush dev ens33 && ip link set ens33 up"
```

Kiểm tra:

```bash
ansible -i /kolla/inventory/multinode control,compute \
  -m shell -a "ip addr show ens33"
```

```
controller | CHANGED | rc=0 >>
2: ens33: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 ...
    link/ether ...
    ← không có dòng inet → đúng rồi
```

> Sau bước này SSH từ bastion đến controller/compute qua `192.168.182.x` sẽ mất. Kolla-Ansible sẽ tiếp tục SSH qua Management IP. Cần update `ansible_host` trong inventory sang Management IP:

```bash
sed -i 's/ansible_host=192.168.182.195/ansible_host=192.168.225.195/' /kolla/inventory/multinode
sed -i 's/ansible_host=192.168.182.196/ansible_host=192.168.225.196/' /kolla/inventory/multinode
```

Kiểm tra inventory sau khi sửa:

```bash
ansible -i /kolla/inventory/multinode all -m ping
```

---

## 2. Bootstrap servers

Bootstrap cài đặt các dependency cần thiết trên tất cả nodes (Python packages, cấu hình Docker daemon...).

```bash
kolla-ansible -i /kolla/inventory/multinode bootstrap-servers
```

Kết quả mong đợi:

```
PLAY RECAP *********************************************************************
controller                 : ok=32  changed=8   unreachable=0  failed=0
compute1                   : ok=28  changed=6   unreachable=0  failed=0
localhost                  : ok=5   changed=0   unreachable=0  failed=0
```

Bootstrap thực hiện trên mỗi node:
- Cài `python3-docker`, `python3-mysqldb` và các Python packages
- Cấu hình Docker daemon (log driver, storage driver...)
- Cấu hình insecure registry nếu dùng local registry

---

## 3. Pull và Push Docker images

Pull tất cả images về local registry trên bastion (~30-60 phút):

```bash
kolla-ansible -i /kolla/inventory/multinode pull
```

Push vào local registry để các nodes pull nội bộ (nhanh hơn nhiều):

```bash
kolla-ansible -i /kolla/inventory/multinode push
```

> Nếu không dùng local registry, bỏ qua bước `push`. Mỗi node sẽ tự pull từ internet.

---

## 4. Prechecks

Prechecks kiểm tra tất cả điều kiện tiên quyết. Phải pass 100% mới deploy.

```bash
kolla-ansible -i /kolla/inventory/multinode prechecks
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
| `Interface ens33 has IP address` | `neutron_external_interface` còn IP | Chạy lại bước 1 flush ens33 |
| `Interface ens33 not found` | Tên interface sai | Kiểm tra `ip a` trên node, sửa globals.yml |
| `Docker is not running` | Docker chưa start | `systemctl start docker` trên node đó |
| `Hostname mismatch` | Hostname không khớp inventory | Sửa `/etc/hostname` hoặc inventory |
| `NTP not synchronized` | Đồng hồ lệch | Kiểm tra chrony: `chronyc tracking` |
| `Hostname not resolvable` | `/etc/hosts` thiếu entry | Kiểm tra `/etc/hosts` trên tất cả nodes |

---

## 5. Deploy

```bash
kolla-ansible -i /kolla/inventory/multinode deploy
```

> Mất khoảng **20-40 phút**. Kolla-Ansible deploy theo thứ tự: MariaDB → RabbitMQ → Memcached → HAProxy → Keystone → Glance → Placement → Nova → Neutron/OVN → Horizon.

---

## 6. Validate config

Sau khi deploy xong, chạy validate để kiểm tra cấu hình các service:

```bash
kolla-ansible -i /kolla/inventory/multinode validate-config
```

> Lưu ý từ docs chính thức: validate chỉ có thể chạy sau lần deploy đầu tiên vì cần access vào running containers.

---

## 7. Theo dõi quá trình deploy

Mở terminal khác, SSH vào controller để theo dõi:

```bash
ssh root@192.168.225.195
watch -n 3 "docker ps --format 'table {{.Names}}\t{{.Status}}' | sort"
```

Khi deploy xong trên controller:

```
NAMES                          STATUS
fluentd                        Up 5 minutes
glance_api                     Up 3 minutes
haproxy                        Up 8 minutes
horizon                        Up 2 minutes
keystone                       Up 4 minutes
mariadb                        Up 9 minutes
memcached                      Up 8 minutes
neutron_ovn_metadata_agent     Up 2 minutes
neutron_server                 Up 2 minutes
nova_api                       Up 3 minutes
nova_conductor                 Up 3 minutes
nova_novncproxy                Up 3 minutes
nova_scheduler                 Up 3 minutes
ovn_controller                 Up 2 minutes
ovn_nb_db                      Up 2 minutes
ovn_northd                     Up 2 minutes
ovn_sb_db                      Up 2 minutes
placement_api                  Up 3 minutes
rabbitmq                       Up 9 minutes
```

Trên compute1:

```bash
ssh root@192.168.225.196
docker ps --format 'table {{.Names}}\t{{.Status}}'
```

```
NAMES                          STATUS
nova_compute                   Up 3 minutes
nova_libvirt                   Up 3 minutes
nova_ssh                       Up 3 minutes
ovn_controller                 Up 2 minutes
neutron_ovn_metadata_agent     Up 2 minutes
```

---

## 8. Xử lý lỗi thường gặp

### Deploy bị lỗi giữa chừng

Kolla-Ansible deploy là idempotent - chạy lại nhiều lần không gây hại:

```bash
kolla-ansible -i /kolla/inventory/multinode deploy -vvv 2>&1 | tee /tmp/deploy.log
```

### Container không start

```bash
# Trên node có container lỗi
docker logs keystone
docker logs neutron_server
```

### MariaDB không start

```bash
docker logs mariadb

# Nếu cần cleanup hoàn toàn
kolla-ansible -i /kolla/inventory/multinode destroy --yes-i-really-really-mean-it
kolla-ansible -i /kolla/inventory/multinode deploy
```

### Reconfigure sau khi sửa globals.yml

```bash
kolla-ansible -i /kolla/inventory/multinode reconfigure
```

### Upgrade lên version mới

```bash
# Sửa openstack_release trong globals.yml
kolla-ansible -i /kolla/inventory/multinode pull
kolla-ansible -i /kolla/inventory/multinode upgrade
```

---

Tiếp theo: [05-post-deploy.md](05-post-deploy.md)

---

## Hỏi & Đáp

### Tại sao phải flush ens33 trước prechecks?

Kolla-Ansible kiểm tra `neutron_external_interface` không có IP vì:

```
ens33 có IP → Kolla gán ens33 vào br-ex → IP mất → mất kết nối
```

Nếu interface đã có IP khi deploy, Kolla vẫn gán vào bridge nhưng sẽ cảnh báo và có thể gây lỗi routing. Prechecks fail sớm để tránh tình huống này.

Sau khi Kolla deploy xong, traffic ra internet đi qua `br-ex` (OVS bridge chứa `ens33`), không phải qua `ens33` trực tiếp nữa.

---

### validate-config kiểm tra gì?

`validate-config` chạy các task kiểm tra trong `kolla-ansible/ansible/roles/$role/tasks/config_validate.yml` của từng service. Nó kiểm tra:

- File config được generate đúng format
- Các giá trị bắt buộc có mặt
- Kết nối đến database, RabbitMQ hoạt động
- Endpoint URL đúng

Khác với `prechecks` (chạy trước deploy, kiểm tra OS/network), `validate-config` chạy sau deploy và kiểm tra application-level config.

---

### Kolla-Ansible lưu cấu hình container ở đâu?

```
/etc/kolla/
├── globals.yml          ← input của bạn
├── globals.d/           ← config modular cho từng service
│   ├── cinder.yml
│   └── swift.yml
├── passwords.yml        ← passwords auto-generated
└── config/              ← override config tùy chọn
    ├── nova/nova.conf
    └── neutron/ml2_conf.ini

/etc/kolla/<service>/    ← generated tự động khi deploy
├── keystone.conf
├── nova.conf
└── ...
```


---

## 1. Bootstrap servers

Bootstrap cài đặt các dependency cần thiết trên tất cả nodes (Python packages, cấu hình Docker daemon...).

```bash
kolla-ansible -i ~/multinode bootstrap-servers
```

Kết quả mong đợi (rút gọn):

```
PLAY [Gather facts for all hosts] **********************************************

TASK [Gathering Facts] *********************************************************
ok: [controller]
ok: [compute1]

...

PLAY RECAP *********************************************************************
controller                 : ok=32  changed=8   unreachable=0  failed=0
compute1                   : ok=28  changed=6   unreachable=0  failed=0
localhost                  : ok=5   changed=0   unreachable=0  failed=0
```

> Nếu có `failed=1` hoặc `unreachable=1`, xem phần [Xử lý lỗi](#6-xử-lý-lỗi-thường-gặp).

Bootstrap thực hiện các việc sau trên mỗi node:
- Cài `python3-docker`, `python3-mysqldb` và các Python packages cần thiết
- Cấu hình Docker daemon (log driver, storage driver...)
- Tạo user `kolla` và cấu hình sudo
- Cấu hình `/etc/kolla` directory

---

## 2. Pull Docker images

Pull tất cả Docker images cần thiết về trước khi deploy. Bước này tốn thời gian nhất (~30-60 phút tùy tốc độ mạng).

```bash
kolla-ansible -i ~/multinode pull
```

Kolla sẽ pull images cho tất cả service đã enable trong `globals.yml`. Mỗi image khoảng 500MB-1GB.

Theo dõi tiến trình trên controller:

```bash
# Mở terminal khác, SSH vào controller
ssh root@192.168.225.195
watch -n 2 "docker images | grep kolla"
```

Kết quả sau khi pull xong:

```
REPOSITORY                              TAG       IMAGE ID       SIZE
quay.io/openstack.kolla/ubuntu-binary-keystone    2025.2    abc123...   800MB
quay.io/openstack.kolla/ubuntu-binary-nova-api    2025.2    def456...   1.2GB
quay.io/openstack.kolla/ubuntu-binary-neutron-server  2025.2  ...      950MB
...
```

---

## 3. Prechecks

Prechecks kiểm tra tất cả điều kiện tiên quyết trước khi deploy. Phải pass 100% mới deploy.

```bash
kolla-ansible -i ~/multinode prechecks
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
| `Interface ens33 not found` | Interface không tồn tại | Kiểm tra tên interface thực tế bằng `ip a` |
| `Interface ens33 has IP address` | `neutron_external_interface` có IP | Xóa IP khỏi `ens33` trong netplan |
| `Docker is not running` | Docker chưa start | `systemctl start docker` trên node đó |
| `Hostname mismatch` | Hostname không khớp inventory | Sửa hostname hoặc inventory |
| `NTP not synchronized` | Đồng hồ lệch | Kiểm tra chrony trên tất cả nodes |

---

## 4. Deploy

Sau khi prechecks pass, bắt đầu deploy:

```bash
kolla-ansible -i ~/multinode deploy
```

> Quá trình deploy mất khoảng **20-40 phút** tùy phần cứng. Đây là lúc Kolla-Ansible tạo và start tất cả container.

Kolla-Ansible deploy theo thứ tự:
1. MariaDB + Galera cluster
2. RabbitMQ cluster
3. Memcached
4. HAProxy + Keepalived
5. Keystone
6. Glance
7. Placement
8. Nova (controller + compute)
9. Neutron + OVN
10. Horizon

---

## 5. Theo dõi quá trình deploy

Mở terminal thứ 2, SSH vào controller để theo dõi container được tạo:

```bash
ssh root@192.168.225.195
watch -n 3 "docker ps --format 'table {{.Names}}\t{{.Status}}' | sort"
```

Khi deploy xong, sẽ thấy các container đang chạy:

```
NAMES                          STATUS
fluentd                        Up 5 minutes
glance_api                     Up 3 minutes
haproxy                        Up 8 minutes
horizon                        Up 2 minutes
keystone                       Up 4 minutes
keystone_fernet                Up 4 minutes
keystone_ssh                   Up 4 minutes
mariadb                        Up 9 minutes
memcached                      Up 8 minutes
neutron_ovn_metadata_agent     Up 2 minutes
neutron_server                 Up 2 minutes
nova_api                       Up 3 minutes
nova_conductor                 Up 3 minutes
nova_novncproxy                Up 3 minutes
nova_scheduler                 Up 3 minutes
ovn_controller                 Up 2 minutes
ovn_nb_db                      Up 2 minutes
ovn_northd                     Up 2 minutes
ovn_sb_db                      Up 2 minutes
placement_api                  Up 3 minutes
rabbitmq                       Up 9 minutes
```

Trên compute1:

```bash
ssh root@192.168.225.196
docker ps --format 'table {{.Names}}\t{{.Status}}'
```

```
NAMES                          STATUS
nova_compute                   Up 3 minutes
nova_libvirt                   Up 3 minutes
nova_ssh                       Up 3 minutes
ovn_controller                 Up 2 minutes
neutron_ovn_metadata_agent     Up 2 minutes
```

---

## 6. Xử lý lỗi thường gặp

### 6.1 Deploy bị lỗi giữa chừng

Kolla-Ansible deploy là idempotent - có thể chạy lại nhiều lần mà không gây hại. Khi gặp lỗi, xem log chi tiết:

```bash
kolla-ansible -i ~/multinode deploy -vvv 2>&1 | tee /tmp/deploy.log
```

Sau khi sửa lỗi, chạy lại:

```bash
kolla-ansible -i ~/multinode deploy
```

### 6.2 Container không start

Kiểm tra log của container bị lỗi:

```bash
# Trên node có container lỗi
docker logs <container_name>

# Ví dụ
docker logs keystone
docker logs neutron_server
```

### 6.3 MariaDB không start

```bash
# Trên controller
docker logs mariadb

# Nếu lỗi "InnoDB: Unable to lock ./ibdata1"
# → Có thể do deploy trước bị dở, cần cleanup
kolla-ansible -i ~/multinode destroy --yes-i-really-really-mean-it
kolla-ansible -i ~/multinode deploy
```

### 6.4 Reconfigure sau khi sửa globals.yml

Nếu cần thay đổi cấu hình sau khi đã deploy:

```bash
# Sửa /etc/kolla/globals.yml
# Sau đó chạy reconfigure (không cần deploy lại từ đầu)
kolla-ansible -i ~/multinode reconfigure
```

### 6.5 Upgrade lên version mới

```bash
pip install -U kolla-ansible
kolla-ansible -i ~/multinode pull
kolla-ansible -i ~/multinode upgrade
```

---

Tiếp theo: [05-post-deploy.md](05-post-deploy.md)

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

Thứ tự này đảm bảo khi service A start, tất cả dependency của A đã sẵn sàng.

---

### Kolla-Ansible lưu cấu hình container ở đâu?

```
/etc/kolla/
├── globals.yml          ← input của bạn
├── passwords.yml        ← passwords được generate
└── config/              ← override config cho từng service (tùy chọn)
    ├── nova/
    │   └── nova.conf
    ├── neutron/
    │   └── ml2_conf.ini
    └── ...

/etc/kolla/<service>/    ← được tạo tự động khi deploy
├── keystone.conf
├── nova.conf
├── neutron.conf
└── ...
```

Kolla-Ansible generate file config từ template + globals.yml + passwords.yml, sau đó mount vào container. Không cần sửa file config thủ công như cài Manual.

---

### Tại sao cần bước `pull` riêng trước `deploy`?

Về mặt kỹ thuật, `deploy` cũng tự pull image nếu chưa có. Nhưng tách `pull` ra có lợi:

1. **Kiểm soát thời gian**: Pull image tốn nhiều thời gian và bandwidth. Làm riêng để biết chính xác bao lâu.
2. **Tránh timeout**: Nếu pull và deploy cùng lúc, task deploy có thể timeout trong khi đang chờ pull.
3. **Retry dễ hơn**: Nếu pull bị lỗi mạng, chỉ cần chạy lại `pull` mà không ảnh hưởng deploy.
4. **Offline deploy**: Sau khi pull xong, có thể deploy trong môi trường không có internet.
