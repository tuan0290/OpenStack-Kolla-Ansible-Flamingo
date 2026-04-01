# Cài đặt Telemetry (Ceilometer + Gnocchi + Aodh)

> Thực hiện trên node **bastion**

## Mục lục

1. [Tổng quan kiến trúc Telemetry](#1-tổng-quan-kiến-trúc-telemetry)
2. [Cấu hình globals.yml](#2-cấu-hình-globalsyml)
3. [Deploy Telemetry stack](#3-deploy-telemetry-stack)
4. [Kiểm tra các service](#4-kiểm-tra-các-service)
5. [Xem metrics và tạo alarm](#5-xem-metrics-và-tạo-alarm)

---

## 1. Tổng quan kiến trúc Telemetry

```
Nova/Neutron/Cinder...
        │
        │ gửi event qua RabbitMQ
        ▼
  CEILOMETER (collector)
        │
        │ lưu metrics
        ▼
   GNOCCHI (time-series DB)
        │
        │ AODH đọc metrics
        ▼
    AODH (alarming)
        │
        │ trigger alarm khi vượt ngưỡng
        ▼
  Webhook / Email / Auto-scaling
```

- **Ceilometer**: Thu thập metrics từ các service (CPU, RAM, network, disk I/O...)
- **Gnocchi**: Time-series database lưu trữ metrics hiệu quả
- **Aodh**: Alarm service, trigger action khi metric vượt ngưỡng

---

## 2. Cấu hình globals.yml

Thêm vào `/etc/kolla/globals.yml`:

```yaml
# Telemetry
enable_ceilometer: "yes"
enable_gnocchi: "yes"
enable_aodh: "yes"

# Gnocchi storage backend (file cho lab, ceph cho production)
gnocchi_backend_storage: "file"
```

> Trong production, dùng `gnocchi_backend_storage: "ceph"` để lưu metrics trên Ceph cluster, đảm bảo HA và scale tốt hơn.

---

## 3. Deploy Telemetry stack

```bash
kolla-ansible -i ~/multinode pull --tags "ceilometer,gnocchi,aodh"
kolla-ansible -i ~/multinode deploy --tags "ceilometer,gnocchi,aodh"
```

Kiểm tra container trên controller:

```bash
ssh root@192.168.225.195 \
  "docker ps --format 'table {{.Names}}\t{{.Status}}' | grep -E 'ceilometer|gnocchi|aodh'"
```

```
aodh_api                    Up 2 minutes
aodh_evaluator              Up 2 minutes
aodh_listener               Up 2 minutes
aodh_notifier               Up 2 minutes
ceilometer_central          Up 2 minutes
ceilometer_compute          Up 2 minutes  ← chạy trên compute1
ceilometer_notification     Up 2 minutes
gnocchi_api                 Up 2 minutes
gnocchi_metricd             Up 2 minutes
gnocchi_statsd              Up 2 minutes
```

---

## 4. Kiểm tra các service

```bash
source /etc/kolla/admin-openrc.sh
```

### 4.1 Kiểm tra Gnocchi

```bash
openstack metric status
```

```
+-----------------------------------------------------+-------+
| Field                                               | Value |
+-----------------------------------------------------+-------+
| storage/number of metric having measures to process | 0     |
| storage/total number of measures to process         | 0     |
+-----------------------------------------------------+-------+
```

### 4.2 Kiểm tra Aodh

```bash
openstack alarm list
```

```
(empty - chưa có alarm nào)
```

### 4.3 Kiểm tra Ceilometer đang thu thập metrics

Sau khi có instance đang chạy, đợi ~5 phút rồi kiểm tra:

```bash
openstack metric resource list --type instance
```

```
+--------------------------------------+----------+--------------------------------------+
| id                                   | type     | project_id                           |
+--------------------------------------+----------+--------------------------------------+
| xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx | instance | b54646bf669746db8c62ec0410bd0528     |
+--------------------------------------+----------+--------------------------------------+
```

---

## 5. Xem metrics và tạo alarm

### 5.1 Xem CPU metrics của instance

```bash
# Lấy instance ID
INSTANCE_ID=$(openstack server show test-vm -f value -c id)

# Xem metrics của instance
openstack metric resource show $INSTANCE_ID
```

```bash
# Xem CPU utilization
openstack metric measures show \
  --resource-id $INSTANCE_ID \
  cpu_util
```

```
+---------------------------+-------------+-------+
| Timestamp                 | Granularity | Value |
+---------------------------+-------------+-------+
| 2025-10-01T10:00:00+00:00 |       300.0 |   2.5 |
| 2025-10-01T10:05:00+00:00 |       300.0 |   3.1 |
+---------------------------+-------------+-------+
```

### 5.2 Tạo alarm CPU cao

```bash
openstack alarm create \
  --name cpu-high-alarm \
  --type gnocchi_resources_threshold \
  --metric cpu_util \
  --threshold 80 \
  --comparison-operator gt \
  --aggregation-method mean \
  --granularity 300 \
  --evaluation-periods 3 \
  --resource-type instance \
  --resource-id $INSTANCE_ID \
  --alarm-action "log://" \
  --ok-action "log://"
```

Kiểm tra alarm:

```bash
openstack alarm list
```

```
+--------------------------------------+----------------+-------+----------+
| alarm_id                             | name           | state | severity |
+--------------------------------------+----------------+-------+----------+
| xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx | cpu-high-alarm | ok    | low      |
+--------------------------------------+----------------+-------+----------+
```

---

Trước: [09-octavia.md](09-octavia.md)

---

## Hỏi & Đáp

### Gnocchi khác gì so với lưu metrics trong MariaDB?

Metrics là time-series data - dạng dữ liệu đặc biệt:
- Ghi liên tục (mỗi 5 phút 1 lần cho mỗi instance)
- Ít khi update, chỉ append
- Query theo time range, aggregation (avg, max, min)
- Cần retention policy (xóa data cũ)

MariaDB (relational DB) không tối ưu cho dạng này:
- Mỗi metric point là 1 row → bảng phình to rất nhanh
- Query aggregation chậm khi có hàng triệu rows
- Không có built-in retention/downsampling

Gnocchi dùng storage backend chuyên biệt (file, Ceph, S3) với format nén, tự động downsample data cũ (giữ 1 điểm/giờ thay vì 1 điểm/5 phút sau 1 tháng).

---

### Ceilometer thu thập metrics bằng cách nào?

Ceilometer có 2 cơ chế:

**1. Notification (event-driven):**
```
Nova tạo VM → gửi event "instance.create" vào RabbitMQ
                    │
              Ceilometer notification agent lắng nghe
                    │
              Ghi vào Gnocchi
```

**2. Polling (pull-based):**
```
Ceilometer polling agent
    │ mỗi 5 phút
    ├── gọi Nova API → lấy CPU/RAM usage
    ├── gọi Neutron API → lấy network bytes
    └── gọi Cinder API → lấy disk I/O
    │
    └── ghi vào Gnocchi
```

Notification nhanh hơn (real-time) nhưng chỉ có event data. Polling chậm hơn nhưng có đầy đủ metrics.

---

### Aodh alarm trigger action gì được?

```yaml
# Webhook - gọi HTTP endpoint
--alarm-action "http://my-autoscaler.example.com/scale-up"

# Log - ghi vào log (dùng để test)
--alarm-action "log://"

# Heat autoscaling - trigger Heat stack update
--alarm-action "trust+heat://..."

# Zaqar - gửi message vào queue
--alarm-action "zaqar://?queue=my-queue"
```

Trong production, Aodh thường kết hợp với Heat để làm **auto-scaling**:
- CPU > 80% trong 3 lần đo liên tiếp → Aodh trigger → Heat tạo thêm instance
- CPU < 20% trong 3 lần đo liên tiếp → Aodh trigger → Heat xóa bớt instance
