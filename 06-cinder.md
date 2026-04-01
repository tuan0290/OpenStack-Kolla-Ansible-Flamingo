# Cài đặt Block Storage (Cinder) với LVM

> Thực hiện trên **bastion** (cấu hình) và **storage1** (chuẩn bị LVM)

## Mục lục

1. [Chuẩn bị LVM trên storage1](#1-chuẩn-bị-lvm-trên-storage1)
2. [Cấu hình Kolla-Ansible cho Cinder](#2-cấu-hình-kolla-ansible-cho-cinder)
3. [Deploy Cinder](#3-deploy-cinder)
4. [Kiểm tra Cinder](#4-kiểm-tra-cinder)

---

## 1. Chuẩn bị LVM trên storage1

> Thực hiện trên node **storage1**

### 1.1 Kiểm tra disk thứ 2

```bash
lsblk
```

```
NAME   MAJ:MIN RM  SIZE RO TYPE MOUNTPOINTS
sda      8:0    0   20G  0 disk
└─sda1   8:1    0   20G  0 part /
sdb      8:16   0   50G  0 disk    ← disk này dùng cho Cinder LVM
```

### 1.2 Tạo LVM Physical Volume và Volume Group

```bash
pvcreate /dev/sdb
vgcreate cinder-volumes /dev/sdb
```

Kiểm tra:

```bash
pvs
vgs
```

```
  PV         VG             Fmt  Attr PSize   PFree
  /dev/sdb   cinder-volumes lvm2 a--  <50.00g <50.00g

  VG             #PV #LV #SN Attr   VSize   VFree
  cinder-volumes   1   0   0 wz--n- <50.00g <50.00g
```

### 1.3 Cấu hình LVM filter (quan trọng)

Mặc định LVM scan tất cả block device, có thể gây xung đột với Cinder. Cần filter chỉ scan `/dev/sdb`:

Sửa `/etc/lvm/lvm.conf`, tìm section `devices` và thêm:

```
devices {
    filter = [ "a/sdb/", "r/.*/"]
}
```

```bash
systemctl restart lvm2-lvmetad 2>/dev/null || true
```

---

## 2. Cấu hình Kolla-Ansible cho Cinder

> Thực hiện trên node **bastion**

### 2.1 Cập nhật inventory

Sửa `~/multinode`, thêm storage1 vào group `[storage]`:

```ini
[storage]
storage1 ansible_host=192.168.225.197 ansible_user=root
```

### 2.2 Cập nhật globals.yml

Thêm vào `/etc/kolla/globals.yml`:

```yaml
# Cinder
enable_cinder: "yes"
enable_cinder_backend_lvm: "yes"
cinder_volume_group: "cinder-volumes"
```

### 2.3 Bootstrap storage1

```bash
kolla-ansible -i ~/multinode bootstrap-servers --limit storage1
```

### 2.4 Pull images cho Cinder

```bash
kolla-ansible -i ~/multinode pull --tags cinder
```

### 2.5 Prechecks

```bash
kolla-ansible -i ~/multinode prechecks --tags cinder
```

---

## 3. Deploy Cinder

```bash
kolla-ansible -i ~/multinode deploy --tags cinder
```

Kiểm tra container trên storage1:

```bash
ssh root@192.168.225.197 "docker ps --format 'table {{.Names}}\t{{.Status}}'"
```

```
NAMES                  STATUS
cinder_volume          Up 2 minutes
cinder_backup          Up 2 minutes
tgtd                   Up 2 minutes
```

---

## 4. Kiểm tra Cinder

```bash
source /etc/kolla/admin-openrc.sh
```

```bash
openstack volume service list
```

```
+------------------+-------------------+------+---------+-------+
| Binary           | Host              | Zone | Status  | State |
+------------------+-------------------+------+---------+-------+
| cinder-scheduler | controller        | nova | enabled | up    |
| cinder-volume    | storage1@lvm      | nova | enabled | up    |
+------------------+-------------------+------+---------+-------+
```

Tạo volume test:

```bash
openstack volume create --size 5 test-vol
openstack volume list
```

```
+--------------------------------------+----------+-----------+------+
| ID                                   | Name     | Status    | Size |
+--------------------------------------+----------+-----------+------+
| xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx | test-vol | available |    5 |
+--------------------------------------+----------+-----------+------+
```

Attach vào instance:

```bash
openstack server add volume test-vm test-vol
openstack volume list
```

```
+--------------------------------------+----------+--------+------+--------------------------------------+
| ID                                   | Name     | Status | Size | Attached to                          |
+--------------------------------------+----------+--------+------+--------------------------------------+
| xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx | test-vol | in-use |    5 | Attached to test-vm on /dev/vdb      |
+--------------------------------------+----------+--------+------+--------------------------------------+
```

---

Trước: [05-post-deploy.md](05-post-deploy.md) | Tiếp theo: [07-swift.md](07-swift.md)
