# OpenStack Flamingo (2025.2) - Kolla-Ansible Deployment Guide

Tài liệu hướng dẫn triển khai OpenStack **Flamingo (2025.2)** bằng **Kolla-Ansible** trên **Ubuntu 24.04 LTS** với mô hình multi-node chạy trên **VMware Workstation**.

---

## Môi trường Lab

**Core nodes:**

| Node | Role | vCPU | RAM | Disk |
|---|---|---|---|---|
| bastion | Deploy node (Kolla-Ansible) | 2 | 2 GB | 20 GB |
| controller | Control Plane (API, DB, MQ, Scheduler...) | 4 | 8 GB | 40 GB + 30 GB |
| compute1 | Nova Compute, OVN agent | 4 | 4 GB | 50 GB |

**Extended nodes (Cinder/Swift):**

| Node | Role | vCPU | RAM | Disk |
|---|---|---|---|---|
| storage1 | Cinder Volume (LVM) | 2 | 2 GB | 20 GB OS + 50 GB data |
| object1 | Swift Account/Container/Object | 2 | 2 GB | 20 GB OS + 20 GB + 20 GB data |
| object2 | Swift Account/Container/Object | 2 | 2 GB | 20 GB OS + 20 GB + 20 GB data |

**Network:**

| VMware | Interface | Dải IP | Vai trò |
|---|---|---|---|
| VMnet8 (NAT) | ens33 | 192.168.182.0/24 | Provider / Internet / Floating IP |
| VMnet1 (Host-only) | ens37 | 192.168.225.0/24 | Management (Kolla API network) |
| VMnet2 (Host-only) | ens38 | 192.168.147.0/24 | Tunnel (Geneve/OVN) |

**IP Summary:**

| Node | ens33 (NAT) | ens37 (Mgmt) | ens38 (Tunnel) |
|---|---|---|---|
| bastion | 192.168.182.128 | 192.168.225.200 | - |
| controller | 192.168.182.195 | 192.168.225.195 | 192.168.147.195 |
| compute1 | 192.168.182.196 | 192.168.225.196 | 192.168.147.196 |
| storage1 | 192.168.182.197 | 192.168.225.197 | - |
| object1 | 192.168.182.198 | 192.168.225.198 | - |
| object2 | 192.168.182.199 | 192.168.225.199 | - |

**Networking backend:** OVN (Open Virtual Network)

---

## Thứ tự cài đặt

```
OpenStack-Kolla-Ansible/
├── README.md
├── 01-environment-prepare.md   → Tất cả nodes + Bastion
├── 02-kolla-ansible-setup.md   → Bastion
├── 03-deploy.md                → Bastion
├── 04-post-deploy.md           → Bastion + Controller
├── 05-cinder.md                → Bastion + Storage1
├── 06-swift.md                 → Bastion + Object1 + Object2
├── 07-heat.md                  → Bastion
├── 08-octavia.md               → Bastion
└── 09-ceilometer.md            → Bastion
```

| File | Nội dung | Node |
|---|---|---|
| [01-environment-prepare.md](01-environment-prepare.md) | Chuẩn bị OS, network, SSH key | Tất cả nodes |
| [02-kolla-ansible-setup.md](02-kolla-ansible-setup.md) | Cài Kolla-Ansible, globals.yml, inventory | Bastion |
| [03-deploy.md](03-deploy.md) | Bootstrap, prechecks, deploy | Bastion |
| [04-post-deploy.md](04-post-deploy.md) | Post-deploy, tạo network, launch instance | Bastion |
| [05-cinder.md](05-cinder.md) | Block Storage (LVM) | Bastion + Storage1 |
| [06-swift.md](06-swift.md) | Object Storage | Bastion + Object1/2 |
| [07-heat.md](07-heat.md) | Orchestration | Bastion |
| [08-octavia.md](08-octavia.md) | Load Balancer | Bastion |
| [09-ceilometer.md](09-ceilometer.md) | Telemetry | Bastion |

---

## Lưu ý quan trọng

**Password thống nhất:** `Welcome123`

**Kolla-Ansible vs Manual:**
- Kolla-Ansible triển khai tất cả service trong **Docker container**
- Không cần cài từng package thủ công, Kolla tự pull image và cấu hình
- Mọi thao tác deploy đều chạy từ **bastion node**
- File cấu hình tập trung tại `/etc/kolla/` trên bastion

**Interface quan trọng trong globals.yml:**
- `network_interface`: ens37 (Management - Kolla dùng để giao tiếp nội bộ)
- `neutron_external_interface`: ens33 (Provider - không có IP, Kolla gán vào br-ex)
- `tunnel_interface`: ens38 (Tunnel - Geneve/OVN overlay)

---

## Truy cập sau khi deploy xong

| Service | URL |
|---|---|
| Horizon Dashboard | `http://192.168.182.195/` |
| Keystone API | `http://192.168.225.195:5000/v3` |
| noVNC Console | `http://192.168.225.195:6080` |
