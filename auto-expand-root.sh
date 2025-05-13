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
# Kiểm tra OS
OS=$(grep '^ID=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "unknown")

log "Hệ điều hành: $OS"
log "Thiết bị root: $ROOT_DEVICE"
log "Filesystem: $FSTYPE"

# Kiểm tra có phải LVM không
if [[ "$ROOT_DEVICE" != /dev/mapper/* ]]; then
    error "Root không nằm trên LVM. Dừng script."
fi

# Lấy tên Volume Group (VG) và Logical Volume (LV)
VG_NAME=$(vgdisplay | awk '/VG Name/{print $3; exit}') || error "Không tìm thấy Volume Group."
LV_NAME=$(lvdisplay "$ROOT_DEVICE" | awk '/LV Path/{print $3}') || error "Không tìm thấy Logical Volume."

log "Volume Group: $VG_NAME"
log "Logical Volume: $LV_NAME"

# Xác định ổ đĩa vật lý chính
MAIN_DISK=$(lsblk -no pkname $(lvdisplay "$ROOT_DEVICE" | grep -o "/dev/[^ ]*" | head -1)) || MAIN_DISK="sda"
log "Ổ đĩa chính được sử dụng: /dev/$MAIN_DISK"

# Kiểm tra không gian trống chưa phân vùng trên ổ đĩa
log "Kiểm tra không gian chưa phân vùng..."
UNALLOCATED_SPACE=$(parted /dev/$MAIN_DISK print free | grep "Free Space" | awk '{if ($3 > 1000) print $1,$2,$3}')

if [ -z "$UNALLOCATED_SPACE" ]; then
    log "Không tìm thấy không gian chưa phân vùng đáng kể."
else
    log "Tìm thấy không gian chưa phân vùng:"
    echo "$UNALLOCATED_SPACE"
    
    # Xử lý từng khoảng không gian trống
    while read -r START END SIZE UNIT; do
        if [[ "$UNIT" == *"GB"* ]] && (( $(echo "$SIZE > 1" | bc -l) )); then
            log "Xử lý không gian trống từ $START đến $END (khoảng $SIZE $UNIT)"
            
            # Xác định số phân vùng tiếp theo
            NEXT_PART=$(parted /dev/$MAIN_DISK print | tail -n +8 | wc -l)
            NEXT_PART=$((NEXT_PART + 1))
            
            log "Tạo phân vùng mới (số $NEXT_PART)..."
            parted /dev/$MAIN_DISK mkpart primary $START $END || warning "Không thể tạo phân vùng mới, có thể đã tồn tại."
            
            log "Đánh dấu phân vùng mới là LVM..."
            parted /dev/$MAIN_DISK set $NEXT_PART lvm on || warning "Không thể đặt cờ LVM, tiếp tục..."
            
            # Đợi hệ thống cập nhật thông tin phân vùng
            sleep 3
            
            # Xác định tên thiết bị cho phân vùng mới
            NEW_PART="/dev/${MAIN_DISK}${NEXT_PART}"
            # Kiểm tra định dạng phân vùng (GPT vs MBR)
            if ! [ -e "$NEW_PART" ]; then
                NEW_PART="/dev/${MAIN_DISK}p${NEXT_PART}"
            fi
            
            if [ -e "$NEW_PART" ]; then
                log "Khởi tạo phân vùng mới $NEW_PART là physical volume..."
                pvcreate "$NEW_PART" || warning "Không thể khởi tạo physical volume, có thể đã tồn tại."
                
                log "Thêm physical volume mới vào volume group $VG_NAME..."
                vgextend "$VG_NAME" "$NEW_PART" || warning "Không thể thêm vào volume group."
            else
                warning "Không tìm thấy thiết bị phân vùng mới. Đường dẫn thử: $NEW_PART"
            fi
        fi
    done <<< "$UNALLOCATED_SPACE"
fi

# Kiểm tra dung lượng trống trong VG
FREE_PE=$(vgdisplay "$VG_NAME" | awk '/Free  PE/{print $5}') || error "Lỗi khi kiểm tra dung lượng VG."
FREE_SIZE=$(vgdisplay "$VG_NAME" | grep "Free  PE" | awk '{print $5,$6,$7}')

if [ "$FREE_PE" -eq 0 ]; then
    warning "Không còn dung lượng trống trong Volume Group $VG_NAME."
    log "Thông tin phân vùng hiện tại:"
    df -Th /
    exit 0
fi

log "Dung lượng trống khả dụng: $FREE_SIZE"

# Mở rộng Logical Volume
log "Mở rộng Logical Volume thêm 100% dung lượng trống..."
lvextend -l +100%FREE "$LV_NAME" || error "Lỗi khi mở rộng Logical Volume."

# Mở rộng filesystem
case "$FSTYPE" in
    ext4)
        log "Mở rộng EXT4 với resize2fs..."
        resize2fs "$ROOT_DEVICE" || error "Lỗi khi mở rộng EXT4."
        ;;
    xfs)
        log "Mở rộng XFS với xfs_growfs..."
        xfs_growfs / || error "Lỗi khi mở rộng XFS."
        ;;
    *)
        error "Filesystem $FSTYPE chưa được hỗ trợ."
        ;;
esac

log "Đã hoàn tất mở rộng. Thông tin phân vùng hiện tại:"
df -Th /

log "Script hoàn tất thành công!"
