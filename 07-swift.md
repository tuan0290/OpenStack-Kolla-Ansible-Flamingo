# Cài đặt Object Storage (Swift)

> Thực hiện trên **bastion** (cấu hình) và **object1, object2** (chuẩn bị disk)

## Mục lục

1. [Chuẩn bị disk trên object1 và object2](#1-chuẩn-bị-disk-trên-object1-và-object2)
2. [Cấu hình Kolla-Ansible cho Swift](#2-cấu-hình-kolla-ansible-cho-swift)
3. [Deploy Swift](#3-deploy-swift)
4. [Kiểm tra Swift](#4-kiểm-tra-swift)

---

## 1. Chuẩn bị disk trên object1 và object2

> Thực hiện trên **object1** và **object2**

Swift yêu cầu disk được format với XFS và có label cụ thể.

### 1.1 Kiểm tra disk

```bash
lsblk
```

```
NAME   MAJ:MIN RM  SIZE RO TYPE MOUNTPOINTS
sda      8:0    0   20G  0 disk
└─sda1   8:1    0   20G  0 part /
sdb      8:16   0   20G  0 disk    ← Swift data disk 1
sdc      8:32   0   20G  0 disk    ← Swift data disk 2
```

### 1.2 Format và label disk

```bash
# Trên object1 và object2 - làm tương tự cho cả sdb và sdc
mkfs.xfs -L d1 /dev/sdb
mkfs.xfs -L d2 /dev/sdc
```

### 1.3 Mount disk

```bash
mkdir -p /srv/node/d1 /srv/node/d2

# Thêm vào /etc/fstab để mount tự động
echo "LABEL=d1 /srv/node/d1 xfs noatime,nodiratime,nobarrier,logbufs=8 0 2" >> /etc/fstab
echo "LABEL=d2 /srv/node/d2 xfs noatime,nodiratime,nobarrier,logbufs=8 0 2" >> /etc/fstab

mount -a
```

Kiểm tra:

```bash
df -h | grep srv
```

```
/dev/sdb        20G   45M   20G   1% /srv/node/d1
/dev/sdc        20G   45M   20G   1% /srv/node/d2
```

---

## 2. Cấu hình Kolla-Ansible cho Swift

> Thực hiện trên node **bastion**

### 2.1 Cập nhật inventory

Sửa `~/multinode`, thêm object nodes:

```ini
[swift-account-server]
object1 ansible_host=192.168.225.198 ansible_user=root
object2 ansible_host=192.168.225.199 ansible_user=root

[swift-container-server]
object1 ansible_host=192.168.225.198 ansible_user=root
object2 ansible_host=192.168.225.199 ansible_user=root

[swift-object-server]
object1 ansible_host=192.168.225.198 ansible_user=root
object2 ansible_host=192.168.225.199 ansible_user=root
```

### 2.2 Cập nhật globals.yml

Thêm vào `/etc/kolla/globals.yml`:

```yaml
# Swift
enable_swift: "yes"
swift_devices_name: "KOLLA_SWIFT_DATA"
swift_devices_match_mode: "prefix"
```

### 2.3 Tạo Swift rings

Swift dùng ring để xác định object được lưu trên node nào. Kolla-Ansible cung cấp script tạo ring tự động:

```bash
kolla-ansible -i ~/multinode genconfig --tags swift
```

Hoặc tạo thủ công:

```bash
# Tạo thư mục chứa ring files
mkdir -p /etc/kolla/config/swift

# Tạo account ring
docker run --rm \
  -v /etc/kolla/config/swift:/etc/swift \
  quay.io/openstack.kolla/ubuntu-binary-swift-base:2025.2 \
  swift-ring-builder /etc/swift/account.builder create 10 3 1

# Tạo container ring
docker run --rm \
  -v /etc/kolla/config/swift:/etc/swift \
  quay.io/openstack.kolla/ubuntu-binary-swift-base:2025.2 \
  swift-ring-builder /etc/swift/container.builder create 10 3 1

# Tạo object ring
docker run --rm \
  -v /etc/kolla/config/swift:/etc/swift \
  quay.io/openstack.kolla/ubuntu-binary-swift-base:2025.2 \
  swift-ring-builder /etc/swift/object.builder create 10 3 1
```

Thêm devices vào ring (object1 và object2, mỗi node 2 disk):

```bash
# object1 - d1
docker run --rm -v /etc/kolla/config/swift:/etc/swift \
  quay.io/openstack.kolla/ubuntu-binary-swift-base:2025.2 \
  swift-ring-builder /etc/swift/account.builder add \
  r1z1-192.168.225.198:6202/d1 100

# object1 - d2
docker run --rm -v /etc/kolla/config/swift:/etc/swift \
  quay.io/openstack.kolla/ubuntu-binary-swift-base:2025.2 \
  swift-ring-builder /etc/swift/account.builder add \
  r1z1-192.168.225.198:6202/d2 100

# object2 - d1
docker run --rm -v /etc/kolla/config/swift:/etc/swift \
  quay.io/openstack.kolla/ubuntu-binary-swift-base:2025.2 \
  swift-ring-builder /etc/swift/account.builder add \
  r1z2-192.168.225.199:6202/d1 100

# object2 - d2
docker run --rm -v /etc/kolla/config/swift:/etc/swift \
  quay.io/openstack.kolla/ubuntu-binary-swift-base:2025.2 \
  swift-ring-builder /etc/swift/account.builder add \
  r1z2-192.168.225.199:6202/d2 100
```

Làm tương tự cho `container.builder` (port 6201) và `object.builder` (port 6200).

Rebalance rings:

```bash
for ring in account container object; do
  docker run --rm -v /etc/kolla/config/swift:/etc/swift \
    quay.io/openstack.kolla/ubuntu-binary-swift-base:2025.2 \
    swift-ring-builder /etc/swift/${ring}.builder rebalance
done
```

### 2.4 Bootstrap object nodes

```bash
kolla-ansible -i ~/multinode bootstrap-servers \
  --limit "object1,object2"
```

---

## 3. Deploy Swift

```bash
kolla-ansible -i ~/multinode deploy --tags swift
```

Kiểm tra container trên object1:

```bash
ssh root@192.168.225.198 "docker ps --format 'table {{.Names}}\t{{.Status}}'"
```

```
NAMES                      STATUS
swift_account_auditor      Up 2 minutes
swift_account_reaper       Up 2 minutes
swift_account_replicator   Up 2 minutes
swift_account_server       Up 2 minutes
swift_container_auditor    Up 2 minutes
swift_container_replicator Up 2 minutes
swift_container_server     Up 2 minutes
swift_container_updater    Up 2 minutes
swift_object_auditor       Up 2 minutes
swift_object_expirer       Up 2 minutes
swift_object_replicator    Up 2 minutes
swift_object_server        Up 2 minutes
swift_object_updater       Up 2 minutes
swift_rsyncd               Up 2 minutes
```

---

## 4. Kiểm tra Swift

```bash
source /etc/kolla/admin-openrc.sh
```

```bash
openstack object store account show
```

```
+------------+---------------------------------------+
| Field      | Value                                 |
+------------+---------------------------------------+
| Account    | AUTH_b54646bf669746db8c62ec0410bd0528 |
| Bytes      | 0                                     |
| Containers | 0                                     |
| Objects    | 0                                     |
+------------+---------------------------------------+
```

Tạo container và upload file:

```bash
openstack container create test-container
echo "Hello Swift" > /tmp/test.txt
openstack object create test-container /tmp/test.txt
openstack object list test-container
```

```
+-----------+
| Name      |
+-----------+
| test.txt  |
+-----------+
```

Download và kiểm tra:

```bash
openstack object save test-container test.txt --file /tmp/downloaded.txt
cat /tmp/downloaded.txt
```

```
Hello Swift
```

---

Trước: [06-cinder.md](06-cinder.md) | Tiếp theo: [08-heat.md](08-heat.md)
