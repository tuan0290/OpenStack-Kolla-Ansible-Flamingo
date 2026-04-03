# Cấu hình Kolla-Ansible

> Thực hiện trên **bastion**. Đảm bảo venv đang active: `source /opt/kolla-venv/bin/activate`

## Mục lục

1. [Kiểm tra version](#1-kiểm-tra-version)
2. [Generate passwords](#2-generate-passwords)
3. [Cấu hình globals.yml](#3-cấu-hình-globalsyml)
4. [Kiểm tra inventory](#4-kiểm-tra-inventory)

---

## 1. Kiểm tra version

Kolla-Ansible 21.0.0 (Flamingo/2025.2) yêu cầu `ansible-core 2.18` hoặc `2.19`. Kiểm tra:

```bash
kolla-ansible --version
ansible --version
```

```
kolla-ansible 21.0.0
ansible [core 2.18.x]
  python version = 3.12.x
```

Nếu ansible-core thấp hơn 2.18, cài lại:

```bash
pip install 'ansible-core>=2.18,<2.20'
kolla-ansible install-deps
```

---

## 2. Generate passwords

`kolla-genpwd` đọc file `/etc/kolla/passwords.yml`, tìm tất cả key có value rỗng và tự động sinh password ngẫu nhiên 32 ký tự cho từng key. File này chứa ~100 password cho tất cả service: MariaDB, RabbitMQ, Keystone, Glance, Nova, Neutron...

```bash
kolla-genpwd
```

Xem một số password vừa được sinh:

```bash
grep -E "^(database_password|rabbitmq_password|keystone_admin_password)" \
  /etc/kolla/passwords.yml
```

```
database_password: xK9mP2qR7nL4vW8j...
rabbitmq_password: hT5yU3oI6pA1sD9f...
keystone_admin_password: bN8cV2xZ4mQ7wE1r...
```

Đặt lại `keystone_admin_password` thành password dễ nhớ để đăng nhập Horizon:

```bash
sed -i 's/^keystone_admin_password:.*/keystone_admin_password: Welcome123/' \
  /etc/kolla/passwords.yml
```

Kiểm tra:

```bash
grep keystone_admin_password /etc/kolla/passwords.yml
```

```
keystone_admin_password: Welcome123
```

> Chỉ cần đổi `keystone_admin_password` - đây là password dùng để đăng nhập Horizon và OpenStack CLI. Các password khác (database, rabbitmq...) để random là tốt nhất vì chúng chỉ dùng nội bộ giữa các service, không cần nhớ.

---

## 3. Cấu hình globals.yml

Ghi đè toàn bộ phần cần thiết vào `/etc/kolla/globals.yml`:

```bash
# Xóa block cũ nếu đã chạy trước đó, rồi append lại
sed -i '/# ── Lab: OpenStack Flamingo/,/^nova_compute_virt_type/d' /etc/kolla/globals.yml
cat >> /etc/kolla/globals.yml << 'EOF'

# ── Lab: OpenStack Flamingo (2025.2) ──────────────────────────────
openstack_release: "2025.2"
kolla_base_distro: "ubuntu"
kolla_install_type: "binary"

# Network interfaces
network_interface: "ens37"
neutron_external_interface: "ens33"
tunnel_interface: "ens38"

# VIP addresses
# Phải là IP chưa dùng trong dải Management - KHÔNG trùng IP của bất kỳ node nào
kolla_internal_vip_address: "192.168.225.100"
kolla_external_vip_address: "192.168.182.100"

# HAProxy
enable_haproxy: "yes"

# Neutron OVN
neutron_plugin_agent: "ovn"
enable_neutron_provider_networks: "yes"
neutron_ovn_distributed_fip: "yes"

# Nova
nova_compute_virt_type: "qemu"
EOF
```

> Dùng `cat >>` để append vào cuối file thay vì ghi đè, giữ nguyên các comment mặc định của Kolla.

### Giải thích từng dòng

| Key | Giá trị | Ý nghĩa |
|---|---|---|
| `openstack_release` | `2025.2` | Version OpenStack để pull Docker image đúng tag |
| `kolla_base_distro` | `ubuntu` | Base OS của container image (ubuntu/debian/rocky/centos) |
| `kolla_install_type` | `binary` | Cài từ apt package bên trong container (thay vì build từ source) |
| `network_interface` | `ens37` | Interface Management - Kolla dùng để giao tiếp nội bộ giữa các service, API endpoints, database, RabbitMQ |
| `neutron_external_interface` | `ens33` | Interface Provider - **không được có IP**, Kolla gán vào OVS bridge `br-ex` để VM ra internet và floating IP |
| `tunnel_interface` | `ens38` | Interface Tunnel - OVN dùng để tạo Geneve overlay giữa controller và compute |
| `kolla_internal_vip_address` | `192.168.225.100` | Virtual IP trên Management network - phải là IP **chưa dùng**, không trùng với IP của bất kỳ node nào. Keepalived sẽ gán IP này lên controller |
| `kolla_external_vip_address` | `192.168.182.100` | Virtual IP trên Provider network - tương tự, phải là IP chưa dùng trong dải `192.168.182.x` |
| `enable_haproxy` | `yes` | Bật HAProxy làm load balancer cho tất cả API endpoint |
| `neutron_plugin_agent` | `ovn` | Dùng OVN làm network backend thay vì OVS truyền thống |
| `enable_neutron_provider_networks` | `yes` | Cho phép VM kết nối thẳng ra physical network (provider network) |
| `neutron_ovn_distributed_fip` | `yes` | Floating IP xử lý trực tiếp trên compute node thay vì phải đi qua controller |
| `nova_compute_virt_type` | `qemu` | Dùng QEMU (software emulation) vì chạy trong VMware - đổi thành `kvm` nếu CPU hỗ trợ nested virt |

Kiểm tra các giá trị đã được ghi:

```bash
grep -E "^(openstack_release|network_interface|neutron_external|tunnel_interface|kolla_internal|kolla_external|neutron_plugin|nova_compute)" \
  /etc/kolla/globals.yml
```

```
openstack_release: "2025.2"
network_interface: "ens37"
neutron_external_interface: "ens33"
tunnel_interface: "ens38"
kolla_internal_vip_address: "192.168.225.100"
kolla_external_vip_address: "192.168.182.100"
neutron_plugin_agent: "ovn"
nova_compute_virt_type: "qemu"
```

### Lưu ý quan trọng về 2025.2

**Horizon port:** Kolla 2025.2 chạy Horizon trên port **8080** khi dùng HAProxy (HAProxy forward từ 80 → 8080). Truy cập Horizon vẫn qua `http://192.168.182.195/` bình thường.

**ProxySQL:** Tự động bật cùng MariaDB, không cần config thêm. Tất cả service kết nối DB qua ProxySQL thay vì trực tiếp vào MariaDB.

**Valkey thay Redis:** Kolla 2025.2 fresh install đã dùng Valkey mặc định - **không cần làm gì thêm**. Chỉ cần xử lý nếu đang upgrade từ phiên bản cũ có `enable_redis: "yes"`:

```bash
# Kiểm tra xem có redis không
grep "enable_redis" /etc/kolla/globals.yml
```

Nếu không có output → bình thường, bỏ qua. Nếu thấy `enable_redis: "yes"` → đang upgrade từ bản cũ, cần đổi:

```bash
sed -i 's/^enable_redis:.*/enable_redis: "no"/' /etc/kolla/globals.yml
echo 'enable_valkey: "yes"' >> /etc/kolla/globals.yml
```

---

## 4. Kiểm tra inventory

Inventory `~/multinode` đã được tạo ở bước trước. Kiểm tra lại:

```bash
ansible -i ~/multinode all -m ping
```

```
controller | SUCCESS => { "ping": "pong" }
compute1   | SUCCESS => { "ping": "pong" }
localhost  | SUCCESS => { "ping": "pong" }
```

Kiểm tra hostname resolvable (bắt buộc cho RabbitMQ):

```bash
ansible -i ~/multinode baremetal -m shell -a "getent hosts controller"
```

```
controller | CHANGED | rc=0 >>
192.168.225.195 controller
```

---

Tiếp theo: [04-deploy.md](04-deploy.md)

---

## Hỏi & Đáp

### Tại sao dùng `cat >>` thay vì `vim` để sửa globals.yml?

File `globals.yml` mặc định của Kolla có ~1000 dòng comment giải thích từng option. Dùng `cat >>` để append các giá trị cần thiết vào cuối file - Ansible đọc file theo thứ tự, giá trị sau sẽ override giá trị trước nếu trùng key. Cách này giữ nguyên toàn bộ comment tham khảo mà không cần xóa.

Nếu muốn xem toàn bộ options có sẵn:

```bash
grep -v "^#" /etc/kolla/globals.yml | grep -v "^$"
```

### ProxySQL là gì và tại sao Kolla 2025.2 dùng mặc định?

ProxySQL là connection pooler và proxy cho MySQL/MariaDB. Kolla 2025.2 bật mặc định vì:

- **Connection pooling**: Hàng chục service OpenStack kết nối DB đồng thời → ProxySQL gom lại, giảm tải MariaDB
- **TLS termination**: TLS giữa service và ProxySQL, ProxySQL → MariaDB cũng TLS
- **HA routing**: Khi MariaDB Galera có node fail, ProxySQL tự route sang node còn sống

Trong lab single-node, ProxySQL vẫn chạy nhưng không có nhiều tác dụng HA - chỉ thêm 1 container `proxysql` trên controller.

### Làm sao thêm service sau khi đã deploy xong?

Kolla-Ansible hỗ trợ thêm service mà không cần deploy lại từ đầu, dùng `globals.d/`:

```bash
mkdir -p /etc/kolla/globals.d

cat > /etc/kolla/globals.d/cinder.yml << 'EOF'
enable_cinder: "yes"
enable_cinder_backend_lvm: "yes"
cinder_volume_group: "cinder-volumes"
EOF
```

Sau đó deploy chỉ service đó, không ảnh hưởng service đang chạy:

```bash
kolla-ansible -i ~/multinode deploy --tags cinder
```

Danh sách tag và key tương ứng:

| Service | Tag deploy | Key globals |
|---|---|---|
| Cinder | `cinder` | `enable_cinder: "yes"` |
| Swift | `swift` | `enable_swift: "yes"` |
| Heat | `heat` | `enable_heat: "yes"` |
| Octavia | `octavia` | `enable_octavia: "yes"` |
| Ceilometer | `ceilometer` | `enable_ceilometer: "yes"` |
| Gnocchi | `gnocchi` | `enable_gnocchi: "yes"` |
| Aodh | `aodh` | `enable_aodh: "yes"` |

Chi tiết từng service xem tại các file `05-cinder.md`, `06-swift.md`...
