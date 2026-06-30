# VM Placement Tool

Tool tự động chuẩn hóa VM Placement Policy cho các VM trên VCloud Director (cloud2.viettelidc.com.vn).

## Mục đích

Khi các VM đang chạy trên một ESXi host cụ thể nhưng chưa được gán đúng Placement Policy tương ứng với host đó, tool này sẽ:

1. Đọc danh sách Organization cần xử lý từ file input.
2. Lấy danh sách VDC và VM trong từng Org.
3. Xác định host hiện tại của từng VM, tra cứu Placement Policy ID tương ứng từ file ánh xạ host.
4. Nếu VDC chưa có policy đó, thêm policy vào VDC trước.
5. Cập nhật Placement Policy của VM về đúng policy của host đang chạy.

## Cấu trúc thư mục

```
.
├── placement-tool.sh         # Script chính
├── export-vm.sh              # Export danh sách VM
├── export-vdc-placement.sh   # Export placement policy hiện tại của các VDC
├── default-placement.sh      # Gán placement policy mặc định
├── hosts-vcenter.txt         # File ánh xạ: IP host → Placement Policy ID
├── org-id-input.txt          # File input: danh sách Org ID cần xử lý
└── temp/                     # Thư mục tạm (tự động tạo khi chạy)
```

## Yêu cầu

- `bash` 4+
- `curl`
- `jq`
- `awk`

## Chuẩn bị

### 1. Cấu hình xác thực

Copy file `.env.example` thành `.env` rồi điền thông tin đăng nhập:

```bash
cp .env.example .env
```

Nội dung `.env`:
```
BASE_URL=https://your-vcloud-domain.example.com
VCLOUD_USER=username@system
VCLOUD_PASS=your_password
```

Hoặc export trực tiếp trước khi chạy:
```bash
export VCLOUD_USER=username@system
export VCLOUD_PASS=your_password
```

> `.env` đã được gitignore — không lo bị commit nhầm.

### 2. Chuẩn bị file `org-id-input.txt`

Copy từ file mẫu rồi điền Org ID thực tế:

```bash
cp org-id-input.example.txt org-id-input.txt
```

Mỗi dòng gồm `orgId` và `orgName`, phân cách bởi khoảng trắng:

```
<org-uuid-1>  TenOrg1
<org-uuid-2>  TenOrg2
```

### 3. Chuẩn bị file `hosts-vcenter.txt`

Copy từ file mẫu rồi điền thông tin host thực tế:

```bash
cp hosts-vcenter.example.txt hosts-vcenter.txt
```

File ánh xạ giữa IP host ESXi và Compute Policy ID trên VCloud Director. Mỗi dòng gồm 3 cột:

```
<host-ip>   <hostname>   <placement-policy-uuid>
```

Ví dụ:
```
172.16.102.33   AZA-TIER1-M4E5-V4   eb101fcb-3e00-40b4-94ce-4f94b5f3e69e
```

## Sử dụng

```bash
chmod +x placement-tool.sh

# Chạy thật
./placement-tool.sh

# Xem trước sẽ thay đổi gì mà không thực sự update
./placement-tool.sh --dry-run
```

Script in ra trạng thái từng bước và lưu log vào `temp/run-YYYYMMDD-HHMMSS.log`:

```
[2025-12-10 09:00:01] Authentication successful
[2025-12-10 09:00:01] Processing org: VPC-6600807 (c7c1be98-...)
[2025-12-10 09:00:02]   Fetching VM list for org VPC-6600807...
[2025-12-10 09:00:05]   VDC: VPC-6600807-VDC (2662f45b-...)
[2025-12-10 09:00:06]   Skip: VDC VPC-6600807-VDC already has all required compute policies
[2025-12-10 09:00:06]   Skip: vm-web-01 (policy already matched)
[2025-12-10 09:00:06]   Updated placement policy: vm-db-01 → eb101fcb-...
[2025-12-10 09:00:08]   Done VDC VPC-6600807-VDC, waiting 2s before next VDC
```

## Luồng xử lý

```
org-id-input.txt
      │
      ▼
  Lấy danh sách VDC (getListVdc)
      │
      ▼
  Lấy danh sách VM + host hiện tại (getListVm)
      │
      ▼
  Tra cứu Policy ID theo host IP (hosts-vcenter.txt)
      │
      ▼
  Thêm Policy vào VDC nếu chưa có (updateOrgComputePolicies)
      │
      ▼
  Cập nhật Placement Policy cho từng VM (updateVmPlacementPolicy)
```

## Lưu ý

- Script bỏ qua các VDC tên `Catalogs`, `Catalogs02`, và `VTDC-TKG-CSE`.
- Mỗi lần xử lý xong một Org sẽ chờ 2 giây để tránh quá tải API.
- Thư mục `temp/` được tạo tự động và chứa file trung gian trong quá trình chạy.
- **Không commit credentials** vào Git. Thông tin xác thực nên được quản lý qua biến môi trường hoặc vault riêng.
