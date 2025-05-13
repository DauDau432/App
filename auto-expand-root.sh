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

# Xác định ổ đĩa vật lý chính
# Lấy disk từ physical volume trong VG
PV_LIST=$(pvdisplay | grep "PV Name" | awk '{print $3}')
DISK_LIST=""

for PV in $PV_LIST; do
    if [[ $PV == /dev/sd* ]]; then
        # Lấy tên ổ đĩa (sda, sdb,...) từ đường dẫn như /dev/sda1
        DISK=$(echo $PV | sed 's/[0-9]*$//' | sed 's|/dev/||')
        if [[ ! $DISK_LIST =~ $DISK ]]; then
            DISK_LIST="$DISK_LIST $DISK"
        fi
    elif [[ $PV == /dev/vd* ]]; then
        # Cho VPS dùng ổ đĩa ảo (vda, vdb,...)
        DISK=$(echo $PV | sed 's/[0-9]*$//' | sed 's|/dev/||')
        if [[ ! $DISK_LIST =~ $DISK ]]; then
            DISK_LIST="$DISK_LIST $DISK"
        fi
    fi
done

# Nếu không tìm thấy ổ đĩa từ PV, thử phương pháp thứ 2
if [ -z "$DISK_LIST" ]; then
    # Kiểm tra các ổ đĩa phổ biến
    for DISK in sda vda xvda nvme0n1; do
        if [ -e "/dev/$DISK" ]; then
            DISK_LIST="$DISK_LIST $DISK"
        fi
    done
fi

# Vẫn không tìm thấy, thử liệt kê tất cả ổ đĩa
if [ -z "$DISK_LIST" ]; then
    DISK_LIST=$(lsblk -pno name | grep -E '/dev/sd|/dev/vd|/dev/xvd|/dev/nvme' | sed 's|/dev/||' | awk -F'[0-9]' '{print $1}' | sort -u)
fi

if [ -z "$DISK_LIST" ]; then
    error "Không thể xác định ổ đĩa chính. Vui lòng kiểm tra thủ công với lệnh 'lsblk'."
fi

log "Danh sách ổ đĩa tìm thấy: $DISK_LIST"

UNALLOCATED_SPACE_FOUND=0

# Kiểm tra từng ổ đĩa
for DISK in $DISK_LIST; do
    log "Kiểm tra ổ đĩa /dev/$DISK..."
    
    # Xác định loại bảng phân vùng (GPT hoặc MBR)
    PART_TABLE=$(parted /dev/$DISK print 2>/dev/null | grep "Partition Table:" | awk '{print $3}')
    log "Loại bảng phân vùng: $PART_TABLE"
    
    # Kiểm tra không gian chưa phân vùng
    UNALLOCATED=$(parted /dev/$DISK print free 2>/dev/null | grep "Free Space" | sort -k1,1n)
    
    if [ -z "$UNALLOCATED" ]; then
        log "Không tìm thấy không gian chưa phân vùng trên /dev/$DISK."
        continue
    fi
    
    log "Tìm thấy không gian chưa phân vùng trên /dev/$DISK:"
    echo "$UNALLOCATED"
    
    # Xử lý từng khoảng trống lớn hơn 100MB
    while read -r START END SIZE UNIT REST; do
        # Bỏ qua nếu kích thước quá nhỏ hoặc không phải GB/MB
        if [[ "$UNIT" == "B" ]] || [[ "$SIZE" == "0.00GB" ]] || [[ "$SIZE" == "0.00MB" ]]; then
            continue
        fi
        
        # Chuyển đổi MB sang GB nếu cần
        if [[ "$UNIT" == "MB" ]] && (( $(echo "$SIZE < 100" | bc -l) )); then
            continue
        fi
        
        log "Xử lý không gian trống từ $START đến $END (khoảng $SIZE $UNIT)..."
        
        # Xác định số phân vùng tiếp theo
        LAST_PART=$(parted /dev/$DISK print 2>/dev/null | tail -n +8 | grep -v Free | wc -l)
        NEXT_PART=$((LAST_PART + 1))
        
        log "Tạo phân vùng mới (số $NEXT_PART)..."
        parted /dev/$DISK mkpart primary $START $END 2>/dev/null || {
            warning "Không thể tạo phân vùng mới. Thử phương pháp khác..."
            # Thử cách khác nếu parted không hoạt động
            parted /dev/$DISK mkpart primary $START 100% 2>/dev/null || {
                warning "Không thể tạo phân vùng mới. Bỏ qua..."
                continue
            }
        }
        
        log "Đánh dấu phân vùng mới là LVM..."
        if [[ "$PART_TABLE" == "gpt" ]]; then
            # Đối với GPT, đặt cờ lvm
            parted /dev/$DISK set $NEXT_PART lvm on 2>/dev/null || warning "Không thể đặt cờ LVM."
        fi
        
        # Đợi hệ thống cập nhật thông tin phân vùng
        log "Cập nhật thông tin phân vùng..."
        sleep 2
        partprobe /dev/$DISK 2>/dev/null
        sleep 1
        
        # Xác định tên thiết bị mới
        if [[ "$DISK" == nvme* ]]; then
            NEW_PART="/dev/${DISK}p${NEXT_PART}"
        elif [[ "$PART_TABLE" == "gpt" && "$DISK" =~ ^vd ]]; then
            # Một số VPS với GPT và vdisk có thể sử dụng pX
            if [ -e "/dev/${DISK}p${NEXT_PART}" ]; then
                NEW_PART="/dev/${DISK}p${NEXT_PART}"
            else
                NEW_PART="/dev/${DISK}${NEXT_PART}"
            fi
        else
            NEW_PART="/dev/${DISK}${NEXT_PART}"
        fi
        
        # Kiểm tra xem thiết bị mới có tồn tại không
        if [ ! -e "$NEW_PART" ]; then
            warning "Không tìm thấy thiết bị $NEW_PART. Thử các tên thiết bị khả năng khác..."
            for POSSIBLE_PART in "/dev/${DISK}${NEXT_PART}" "/dev/${DISK}p${NEXT_PART}"; do
                if [ -e "$POSSIBLE_PART" ]; then
                    NEW_PART="$POSSIBLE_PART"
                    log "Tìm thấy thiết bị: $NEW_PART"
                    break
                fi
            done
        fi
        
        if [ ! -e "$NEW_PART" ]; then
            warning "Không tìm thấy thiết bị phân vùng mới sau khi tạo. Bỏ qua..."
            continue
        fi
        
        log "Khởi tạo physical volume $NEW_PART..."
        pvcreate $NEW_PART 2>/dev/null || warning "Lỗi khi khởi tạo physical volume."
        
        log "Thêm vào volume group $VG_NAME..."
        vgextend $VG_NAME $NEW_PART 2>/dev/null || warning "Lỗi khi mở rộng volume group."
        
        UNALLOCATED_SPACE_FOUND=1
    done <<< "$UNALLOCATED"
done

# Kiểm tra dung lượng trống trong VG
FREE_PE=$(vgdisplay $VG_NAME | awk '/Free  PE/{print $5}')
FREE_SIZE=$(vgdisplay $VG_NAME | grep "Free  PE" | awk '{print $5,$6,$7}')

if [ "$FREE_PE" -eq 0 ]; then
    if [ $UNALLOCATED_SPACE_FOUND -eq 1 ]; then
        error "Đã thêm phân vùng mới nhưng không có không gian trống trong Volume Group. Kiểm tra lại với 'vgdisplay'."
    else
        log "Không còn dung lượng trống trong Volume Group $VG_NAME và không tìm thấy không gian chưa phân vùng."
        log "Thông tin phân vùng hiện tại:"
        df -Th /
        exit 0
    fi
fi

log "Dung lượng trống khả dụng trong VG: $FREE_SIZE"

# Mở rộng Logical Volume
log "Mở rộng Logical Volume $LV_PATH..."
lvextend -l +100%FREE $LV_PATH || error "Lỗi khi mở rộng Logical Volume."

# Mở rộng filesystem
case "$FSTYPE" in
    ext4)
        log "Mở rộng EXT4 với resize2fs..."
        resize2fs $ROOT_DEVICE || error "Lỗi khi mở rộng EXT4."
        ;;
    xfs)
        log "Mở rộng XFS với xfs_growfs..."
        xfs_growfs / || error "Lỗi khi mở rộng XFS."
        ;;
    *)
        error "Filesystem $FSTYPE chưa được hỗ trợ."
        ;;
esac

log "Đã hoàn tất mở rộng phân vùng. Thông tin phân vùng hiện tại:"
df -Th /

log "Script hoàn tất thành công!"
