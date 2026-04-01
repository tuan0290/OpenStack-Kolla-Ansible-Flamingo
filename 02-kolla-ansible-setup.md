# Cấu hình Kolla-Ansible

> Thực hiện **bên trong container** `kolla-ansible` trên bastion
>
> Vào container: `docker exec -it kolla-ansible bash`

## Mục lục

1. [Cấu trúc thư mục](#1-cấu-trúc-thư-mục)
2. [Generate passwords](#2-generate-passwords)
3. [Kiểm tra môi trường](#3-kiểm-tra-môi-trường)

---

## 1. Cấu trúc thư mục

Khi vào container, working directory là `/kolla` - mount từ repo trên bastion host:

```
/kolla/                          ← repo root (mount từ bastion)
├── inventory/
│   ├── multinode                ← inventory cho kolla-ansible deploy
│   └── all-nodes                ← inventory cho prepare-nodes playbook
├── playbooks/
│   └── prepare-nodes.yml        ← playbook chuẩn bị nodes
├── config/
│   └── kolla/                   ← mount vào /etc/kolla bên trong container
│       ├── globals.yml          ← cấu hình deployment
│       └── passwords.yml        ← passwords (auto-generated)
└── docker/
    ├── Dockerfile
    ├── compose.yaml
    └── entrypoint.sh
```

Tạo thư mục config nếu chưa có:

```bash
mkdir -p /kolla/config/kolla
```

Copy file mẫu vào:

```bash
cp /etc/kolla/globals.yml /kolla/config/kolla/globals.yml
cp /etc/kolla/passwords.yml /kolla/config/kolla/passwords.yml
```

---

## 2. Generate passwords

```bash
kolla-genpwd -p /kolla/config/kolla/passwords.yml
```

Đặt lại `keystone_admin_password` thành password dễ nhớ:

```bash
sed -i 's/^keystone_admin_password:.*/keystone_admin_password: Welcome123/' \
  /kolla/config/kolla/passwords.yml
```

Kiểm tra:

```bash
grep keystone_admin_password /kolla/config/kolla/passwords.yml
```

```
keystone_admin_password: Welcome123
```

---

## 3. Kiểm tra môi trường

```bash
kolla-ansible --version
ansible --version
```

```
kolla-ansible 21.0.0
ansible [core 2.17.x]
  python version = 3.12.x
```

Ping tất cả nodes qua inventory multinode:

```bash
ansible -i /kolla/inventory/multinode all -m ping
```

```
controller | SUCCESS => { "ping": "pong" }
compute1   | SUCCESS => { "ping": "pong" }
localhost  | SUCCESS => { "ping": "pong" }
```

---

Tiếp theo: [03-globals-inventory.md](03-globals-inventory.md)

---

## Hỏi & Đáp

### Tại sao dùng Docker container thay vì cài Kolla-Ansible thẳng lên bastion?

Một vài lý do thực tế:

- **Reproducible**: Mọi người trong team dùng cùng 1 image, không có chuyện "máy tôi chạy được mà máy anh không"
- **Isolation**: Kolla-Ansible và dependencies không ảnh hưởng system Python của bastion
- **Version control**: Dockerfile commit vào repo → biết chính xác version nào đang dùng
- **Upgrade dễ**: Đổi version trong Dockerfile, build lại image là xong

### /etc/kolla bên trong container được mount từ đâu?

`compose.yaml` mount `../config/kolla` vào `/etc/kolla` bên trong container:

```yaml
volumes:
  - "../config/kolla:/etc/kolla"
```

Nghĩa là file `globals.yml` và `passwords.yml` thực sự nằm tại `config/kolla/` trong repo trên bastion host. Sửa file ở đây sẽ có hiệu lực ngay bên trong container mà không cần restart.

### SSH key được mount như thế nào?

```yaml
volumes:
  - "~/.ssh:/root/.ssh:ro"
```

SSH key của user root trên bastion được mount vào container ở chế độ read-only. Container dùng key này để SSH đến các nodes - không cần copy key vào image.
