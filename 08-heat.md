# Cài đặt Orchestration (Heat)

> Thực hiện trên node **bastion**

## Mục lục

1. [Cấu hình globals.yml](#1-cấu-hình-globalsyml)
2. [Deploy Heat](#2-deploy-heat)
3. [Kiểm tra Heat](#3-kiểm-tra-heat)
4. [Tạo stack đầu tiên](#4-tạo-stack-đầu-tiên)

---

## 1. Cấu hình globals.yml

Thêm vào `/etc/kolla/globals.yml`:

```yaml
enable_heat: "yes"
```

---

## 2. Deploy Heat

```bash
kolla-ansible -i ~/multinode pull --tags heat
kolla-ansible -i ~/multinode deploy --tags heat
```

Kiểm tra container trên controller:

```bash
ssh root@192.168.225.195 \
  "docker ps --format 'table {{.Names}}\t{{.Status}}' | grep heat"
```

```
heat_api              Up 2 minutes
heat_api_cfn          Up 2 minutes
heat_engine           Up 2 minutes
```

---

## 3. Kiểm tra Heat

```bash
source /etc/kolla/admin-openrc.sh
openstack orchestration service list
```

```
+------------+-------------+------+--------+--------+
| Hostname   | Binary      | Zone | Status | State  |
+------------+-------------+------+--------+--------+
| controller | heat-engine | nova | up     | up     |
+------------+-------------+------+--------+--------+
```

---

## 4. Tạo stack đầu tiên

Tạo file template `~/test-stack.yaml`:

```yaml
heat_template_version: 2021-04-16

description: Test Heat stack - tạo 1 instance

parameters:
  image:
    type: string
    default: cirros-0.6.2
  flavor:
    type: string
    default: m1.tiny
  network:
    type: string
    default: selfservice

resources:
  my_instance:
    type: OS::Nova::Server
    properties:
      image: { get_param: image }
      flavor: { get_param: flavor }
      networks:
        - network: { get_param: network }

outputs:
  instance_ip:
    description: IP của instance
    value: { get_attr: [my_instance, first_address] }
```

Deploy stack:

```bash
openstack stack create -t ~/test-stack.yaml test-stack
```

Theo dõi trạng thái:

```bash
openstack stack list
```

```
+--------------------------------------+------------+-----------------+
| ID                                   | Stack Name | Stack Status    |
+--------------------------------------+------------+-----------------+
| xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx | test-stack | CREATE_COMPLETE |
+--------------------------------------+------------+-----------------+
```

Xem output:

```bash
openstack stack output show test-stack instance_ip
```

```
+--------------+----------------------------------+
| Field        | Value                            |
+--------------+----------------------------------+
| description  | IP của instance                  |
| output_key   | instance_ip                      |
| output_value | 10.0.0.x                         |
+--------------+----------------------------------+
```

Xóa stack test:

```bash
openstack stack delete test-stack --yes
```

---

Trước: [07-swift.md](07-swift.md) | Tiếp theo: [09-octavia.md](09-octavia.md)
