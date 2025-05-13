#!/bin/bash

# Hàm hiển thị thông báo
log() {
    echo "[+] $1"
}

error() {
    echo "[x] $1"
    exit 1
}

warning() {
    echo "[!] $1"
}

# Kiểm tra quyền root
if [ "$(id -u)" -ne 0 ]; then
    error "Script này cần được chạy với quyền root."
fi

log "Bắt đầu kiểm tra và mở rộng phân vùng root..."

# Lấy thông tin thiết bị gắn với /
ROOT_DEVICE=$(findmnt -n -o SOURCE /) || error "Không tìm thấy thiết bị root."
# Lấy loại filesystem
FSTYPE=$(findmnt -n -o FSTYPE /) || error "Không xác định được filesystem."

log "Thiết bị root: $ROOT_DEVICE"
log "Filesystem: $FSTYPE"

# Kiểm tra có phải LVM không
if [[ "$ROOT_DEVICE" != /dev/mapper/* ]]; then
    error "Root không nằm trên LVM. Dừng script."
fi

# Lấy tên Volume Group (VG) và Logical Volume (LV)
VG_NAME=$(vgdisplay | awk '/VG Name/{print $3; exit}') || error "Không tìm thấy Volume Group."
LV_PATH=$(lvdisplay "$ROOT_DEVICE" | awk '/LV Path/{print $3; exit}') || error "Không tìm thấy Logical Volume."

log "Volume Group: $VG_NAME"
log "Logical Volume: $LV_PATH"

# Trong trường hợp của bạn, chúng ta biết chắc chắn ổ đĩa chính là /dev/sda
MAIN_DISK="sda"
log "Ổ đĩa chính: /dev/$MAIN_DISK"

# Xử lý không gian chưa phân vùng cuối ổ đĩa
log "Xử lý không gian chưa phân vùng từ 21.5GB đến 42.9GB..."

# Tạo phân vùng mới
log "Tạo phân vùng mới..."
parted /dev/$MAIN_DISK mkpart primary 21.5GB 42.9GB || warning "Lỗi khi tạo phân vùng mới."

# Đánh dấu phân vùng là LVM
log "Đánh dấu phân vùng mới là LVM..."
parted /dev/$MAIN_DISK set 5 lvm on || warning "Lỗi khi đặt cờ LVM."

# Đợi hệ thống cập nhật thông tin phân vùng
log "Đợi hệ thống cập nhật thông tin phân vùng..."
sleep 3
partprobe /dev/$MAIN_DISK

# Khởi tạo physical volume
NEW_PART="/dev/${MAIN_DISK}5"
log "Khởi tạo physical volume $NEW_PART..."
pvcreate $NEW_PART || warning "Lỗi khi khởi tạo physical volume."

# Thêm vào volume group
log "Thêm vào volume group $VG_NAME..."
vgextend $VG_NAME $NEW_PART || warning "Lỗi khi mở rộng volume group."

# Mở rộng logical volume
log "Mở rộng logical volume $LV_PATH..."
lvextend -l +100%FREE $LV_PATH || warning "Lỗi khi mở rộng logical volume."

# Mở rộng filesystem
log "Mở rộng filesystem..."
resize2fs $ROOT_DEVICE || warning "Lỗi khi mở rộng filesystem."

log "Hoàn tất. Thông tin phân vùng hiện tại:"
df -Th /

log "Script hoàn tất!"
