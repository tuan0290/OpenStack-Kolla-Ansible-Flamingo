# Post-Deploy: Cấu hình sau khi deploy

> Thực hiện trên node **bastion**

## Mục lục

1. [Generate admin credentials](#1-generate-admin-credentials)
2. [Kiểm tra các service](#2-kiểm-tra-các-service)
3. [Tạo network và resources ban đầu](#3-tạo-network-và-resources-ban-đầu)
4. [Launch instance đầu tiên](#4-launch-instance-đầu-tiên)
5. [Truy cập Horizon](#5-truy-cập-horizon)

---

## 1. Generate admin credentials

Kolla-Ansible cung cấp lệnh `post-deploy` để tạo file `admin-openrc.sh`:

```bash
kolla-ansible -i ~/multinode post-deploy
```

File được tạo tại `/etc/kolla/admin-openrc.sh`. Load vào shell:

```bash
source /etc/kolla/admin-openrc.sh
```

Kiểm tra nội dung:

```bash
cat /etc/kolla/admin-openrc.sh
```

```bash
export OS_PROJECT_DOMAIN_NAME=Default
export OS_USER_DOMAIN_NAME=Default
export OS_PROJECT_NAME=admin
export OS_TENANT_NAME=admin
export OS_USERNAME=admin
export OS_PASSWORD=Welcome123
export OS_AUTH_URL=http://192.168.225.195:5000/v3
export OS_INTERFACE=internal
export OS_ENDPOINT_TYPE=internalURL
export OS_IDENTITY_API_VERSION=3
export OS_REGION_NAME=RegionOne
export OS_AUTH_PLUGIN=password
```

Cài đặt OpenStack client trên bastion:

```bash
pip install python-openstackclient
```

Kiểm tra kết nối đến Keystone:

```bash
openstack token issue
```

```
+------------+---------------------------------------------------------+
| Field      | Value                                                   |
+------------+---------------------------------------------------------+
| expires    | 2025-10-01T10:00:00+0000                                |
| id         | gAAAAABZ...                                             |
| project_id | b54646bf669746db8c62ec0410bd0528                        |
| user_id    | 102f8ea368cd4451ad6fefeb15801177                        |
+------------+---------------------------------------------------------+
```

---

## 2. Kiểm tra các service

### 2.1 Kiểm tra service catalog

```bash
openstack service list
```

```
+----------------------------------+------------+----------------+
| ID                               | Name       | Type           |
+----------------------------------+------------+----------------+
| ...                              | keystone   | identity       |
| ...                              | glance     | image          |
| ...                              | nova       | compute        |
| ...                              | neutron    | network        |
| ...                              | placement  | placement      |
+----------------------------------+------------+----------------+
```

### 2.2 Kiểm tra Nova compute

```bash
openstack compute service list
```

```
+----+----------------+------------+----------+---------+-------+
| ID | Binary         | Host       | Zone     | Status  | State |
+----+----------------+------------+----------+---------+-------+
|  1 | nova-conductor | controller | internal | enabled | up    |
|  2 | nova-scheduler | controller | internal | enabled | up    |
|  3 | nova-compute   | compute1   | nova     | enabled | up    |
+----+----------------+------------+----------+---------+-------+
```

### 2.3 Kiểm tra Neutron agents

```bash
openstack network agent list
```

```
+------+------------------------------+------------+-------+-------+
| ID   | Agent Type                   | Host       | Alive | State |
+------+------------------------------+------------+-------+-------+
| ...  | OVN Controller Gateway agent | controller | :-)   | UP    |
| ...  | OVN Controller agent         | compute1   | :-)   | UP    |
| ...  | OVN Metadata agent           | controller | :-)   | UP    |
| ...  | OVN Metadata agent           | compute1   | :-)   | UP    |
+------+------------------------------+------------+-------+-------+
```

### 2.4 Kiểm tra Glance

```bash
openstack image list
```

Lúc này chưa có image nào, kết quả trả về rỗng là bình thường.

### 2.5 Kiểm tra Placement

```bash
openstack resource provider list
```

```
+--------------------------------------+----------+------------+
| uuid                                 | name     | generation |
+--------------------------------------+----------+------------+
| xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx | compute1 |          1 |
+--------------------------------------+----------+------------+
```

---

## 3. Tạo network và resources ban đầu

### 3.1 Upload image Cirros

Cirros là image nhỏ (~20MB) dùng để test, boot rất nhanh.

```bash
wget https://download.cirros-cloud.net/0.6.2/cirros-0.6.2-x86_64-disk.img
```

```bash
openstack image create \
  --container-format bare \
  --disk-format qcow2 \
  --file cirros-0.6.2-x86_64-disk.img \
  --public \
  cirros-0.6.2
```

Kiểm tra:

```bash
openstack image list
```

```
+--------------------------------------+-------------+--------+
| ID                                   | Name        | Status |
+--------------------------------------+-------------+--------+
| xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx | cirros-0.6.2| active |
+--------------------------------------+-------------+--------+
```

### 3.2 Tạo flavor

```bash
openstack flavor create --id 1 --vcpus 1 --ram 512 --disk 5 m1.tiny
openstack flavor create --id 2 --vcpus 1 --ram 1024 --disk 10 m1.small
openstack flavor create --id 3 --vcpus 2 --ram 2048 --disk 20 m1.medium
```

### 3.3 Tạo provider network

```bash
openstack network create \
  --share \
  --provider-physical-network physnet1 \
  --provider-network-type flat \
  --external \
  provider
```

```bash
openstack subnet create \
  --network provider \
  --allocation-pool start=192.168.182.210,end=192.168.182.250 \
  --dns-nameserver 8.8.8.8 \
  --gateway 192.168.182.2 \
  --subnet-range 192.168.182.0/24 \
  provider-subnet
```

> Pool `192.168.182.210-250` dùng cho Floating IP. Đảm bảo dải này không bị DHCP của VMware cấp.

### 3.4 Tạo self-service network

```bash
openstack network create selfservice
```

```bash
openstack subnet create \
  --network selfservice \
  --dns-nameserver 8.8.8.8 \
  --gateway 10.0.0.1 \
  --subnet-range 10.0.0.0/24 \
  selfservice-subnet
```

### 3.5 Tạo router

```bash
openstack router create router1
openstack router set router1 --external-gateway provider
openstack router add subnet router1 selfservice-subnet
```

Kiểm tra router:

```bash
openstack router show router1 -c external_gateway_info -c interfaces_info
```

### 3.6 Tạo security group rules

Mặc định security group chặn tất cả inbound. Thêm rule cho SSH và ICMP:

```bash
openstack security group rule create --proto icmp default
openstack security group rule create --proto tcp --dst-port 22 default
```

### 3.7 Tạo SSH keypair

```bash
ssh-keygen -t ed25519 -f ~/.ssh/openstack-key -N ""
openstack keypair create --public-key ~/.ssh/openstack-key.pub mykey
```

---

## 4. Launch instance đầu tiên

### 4.1 Tạo instance trên self-service network

```bash
openstack server create \
  --flavor m1.tiny \
  --image cirros-0.6.2 \
  --network selfservice \
  --security-group default \
  --key-name mykey \
  test-vm
```

Theo dõi trạng thái:

```bash
openstack server list
```

```
+--------------------------------------+---------+--------+---------------------------+
| ID                                   | Name    | Status | Networks                  |
+--------------------------------------+---------+--------+---------------------------+
| xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx | test-vm | ACTIVE | selfservice=10.0.0.x      |
+--------------------------------------+---------+--------+---------------------------+
```

> Trạng thái phải là `ACTIVE`. Nếu `ERROR`, xem log: `openstack server show test-vm`

### 4.2 Gán Floating IP

```bash
openstack floating ip create provider
```

```
+---------------------+--------------------------------------+
| Field               | Value                                |
+---------------------+--------------------------------------+
| floating_ip_address | 192.168.182.210                      |
| ...                 |                                      |
+---------------------+--------------------------------------+
```

```bash
openstack server add floating ip test-vm 192.168.182.210
```

### 4.3 Kiểm tra kết nối

```bash
ping -c 3 192.168.182.210
```

```
PING 192.168.182.210 (192.168.182.210) 56(84) bytes of data.
64 bytes from 192.168.182.210: icmp_seq=1 ttl=63 time=1.2 ms
64 bytes from 192.168.182.210: icmp_seq=2 ttl=63 time=0.9 ms
64 bytes from 192.168.182.210: icmp_seq=3 ttl=63 time=1.1 ms
```

```bash
ssh -i ~/.ssh/openstack-key cirros@192.168.182.210
```

```
$ hostname
test-vm
$ ip a
...
```

---

## 5. Truy cập Horizon

Mở trình duyệt trên máy Windows host:

```
http://192.168.182.195/
```

Đăng nhập:
- Domain: `Default`
- Username: `admin`
- Password: `Welcome123`

---

Tiếp theo: [06-cinder.md](06-cinder.md)

---

## Hỏi & Đáp

### Kolla post-deploy làm gì?

`kolla-ansible post-deploy` thực hiện các bước sau:
1. Tạo file `/etc/kolla/admin-openrc.sh` với credentials của admin user
2. Tạo file `/etc/kolla/clouds.yaml` cho OpenStack SDK
3. Chạy một số task cleanup sau deploy

Đây là bước bắt buộc để có credentials dùng OpenStack CLI.

---

### physnet1 trong provider network là gì?

`physnet1` là tên logical của physical network trong Neutron. Kolla-Ansible tự động map:

```
globals.yml:
  neutron_external_interface: "ens33"
  neutron_bridge_name: "br-ex"          ← default
  neutron_physical_networks: "physnet1"  ← default

→ Kolla tạo mapping: physnet1 → br-ex → ens33
```

Khi tạo provider network với `--provider-physical-network physnet1`, Neutron biết traffic của network này đi qua `br-ex` → `ens33` → physical switch.

---

### Tại sao dùng Cirros để test?

Cirros được thiết kế đặc biệt cho việc test OpenStack:
- Kích thước nhỏ (~20MB) → upload nhanh, boot nhanh (~10 giây)
- Tự động lấy IP qua DHCP
- Có sẵn SSH server
- Username mặc định: `cirros`, password: `gocubsgo`
- Không cần keypair (có thể login bằng password qua console)

Trong production, dùng Ubuntu Cloud Image hoặc CentOS Stream image.
