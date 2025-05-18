#!/bin/bash

# Hàm hiển thị thông báo
log() {
    echo "[+] $1" | tee -a /var/log/auto-expand-root.log
}

error() {
    echo "[!] Lỗi: $1" | tee -a /var/log/auto-expand-root.log
    exit 1
}

warning() {
    echo "[!] Cảnh báo: $1" | tee -a /var/log/auto-expand-root.log
}

# Tạo log file
mkdir -p /var/log
touch /var/log/auto-expand-root.log
LOG_FILE="/var/log/auto-expand-root.log"

# Kiểm tra quyền root
if [ "$(id -u)" -ne 0 ]; then
    error "Script này cần được chạy với quyền root."
fi

log "Bắt đầu kiểm tra và mở rộng phân vùng root..."
log "Log được ghi tại: $LOG_FILE"

# Lấy thông tin thiết bị gắn với /
ROOT_DEVICE=$(findmnt -n -o SOURCE /) || error "Không tìm thấy thiết bị root."
FSTYPE=$(findmnt -n -o FSTYPE /) || error "Không xác định được filesystem."

log "Thiết bị root: $ROOT_DEVICE"
log "Filesystem: $FSTYPE"

# Kiểm tra có phải LVM không
if [[ "$ROOT_DEVICE" != /dev/mapper/* ]]; then
    error "Root không nằm trên LVM. Script chỉ hỗ trợ LVM."
fi

# Lấy tên Volume Group (VG) và Logical Volume (LV)
VG_NAME=$(vgdisplay --noheadings -C -o vg_name 2>/dev/null | head -n 1) || error "Không tìm thấy Volume Group."
LV_PATH=$(lvdisplay "$ROOT_DEVICE" 2>/dev/null | awk '/LV Path/{print $3; exit}') || error "Không tìm thấy Logical Volume."

log "Volume Group: $VG_NAME"
log "Logical Volume: $LV_PATH"

# Tìm ổ đĩa vật lý từ Physical Volume (PV)
PV_LIST=$(pvdisplay 2>/dev/null | awk '/PV Name/{print $3}')
DISK_LIST=""

for PV in $PV_LIST; do
    if [[ $PV == /dev/sd* || $PV == /dev/vd* || $PV == /dev/nvme* ]]; then
        DISK=$(echo "$PV" | sed 's/[0-9]*$//' | sed 's|/dev/||' | sed 's/p[0-9]*$//')
        if [[ ! $DISK_LIST =~ $DISK ]]; then
            DISK_LIST="$DISK_LIST $DISK"
        fi
    fi
done

# Nếu không tìm thấy, thử các ổ đĩa phổ biến
if [ -z "$DISK_LIST" ]; then
    DISK_LIST=$(lsblk -pno name | grep -E '/dev/sd|/dev/vd|/dev/xvd|/dev/nvme' | sed 's|/dev/||' | awk -F'[0-9]' '{print $1}' | sort -u)
fi

if [ -z "$DISK_LIST" ]; then
    error "Không tìm thấy ổ đĩa. Kiểm tra thủ công với 'lsblk'."
fi

log "Danh sách ổ đĩa tìm thấy: $DISK_LIST"

# Biến theo dõi dung lượng và trạng thái
SPACE_ADDED=0
TOTAL_FREE_SPACE=0
TOTAL_UNUSED_PARTITION_SPACE=0
USED_PARTITION_COUNT=0
TOTAL_USED_PARTITION_SPACE=0

# Kiểm tra từng ổ đĩa
for DISK in $DISK_LIST; do
    log "Kiểm tra ổ đĩa /dev/$DISK..."

    # Kiểm tra loại bảng phân vùng
    PART_TABLE=$(parted /dev/$DISK print 2>/dev/null | grep "Partition Table:" | awk '{print $3}')
    log "Loại bảng phân vùng: $PART_TABLE"

    # Kiểm tra số lượng phân vùng
    PART_COUNT=$(parted /dev/$DISK print 2>/dev/null | grep -c "^ [0-9]")
    if [ "$PART_COUNT" -ge 128 ] && [ "$PART_TABLE" = "gpt" ]; then
        warning "Đã đạt giới hạn 128 phân vùng trên /dev/$DISK. Bỏ qua."
        continue
    fi

    # 1. Kiểm tra không gian chưa phân vùng
    log "Kiểm tra không gian chưa phân vùng..."
    UNALLOCATED=$(parted /dev/$DISK unit MB print free 2>/dev/null | grep "Free Space" | awk '{print $1, $2, $3}')

    if [ -n "$UNALLOCATED" ]; then
        log "Tìm thấy không gian chưa phân vùng trên /dev/$DISK:"
        echo "$UNALLOCATED" | tee -a "$LOG_FILE"

        while read -r START END SIZE; do
            if [ -z "$SIZE" ] || [ "${SIZE%.*}" -lt 100 ]; then
                log "Không gian từ ${START}MB đến ${END}MB ($SIZE MB) quá nhỏ, bỏ qua."
                continue
            fi

            TOTAL_FREE_SPACE=$((TOTAL_FREE_SPACE + SIZE))
            log "Xử lý không gian trống từ ${START}MB đến ${END}MB ($SIZE MB)..."

            LAST_PART=$(parted /dev/$DISK print 2>/dev/null | grep -E "^ [0-9]" | tail -n 1 | awk '{print $1}')
            NEXT_PART=$((LAST_PART + 1))

            if lsof /dev/$DISK >/dev/null 2>&1; then
                warning "Ổ đĩa /dev/$DISK đang bị khóa. Thử đồng bộ..."
                sync
                sleep 2
            fi

            log "Tạo phân vùng mới (số $NEXT_PART)..."
            if ! parted /dev/$DISK mkpart primary "${START}MB" "${END}MB" 2>/dev/null; then
                warning "Không thể tạo phân vùng mới từ ${START}MB đến ${END}MB. Bỏ qua."
                continue
            fi

            if [ "$PART_TABLE" = "gpt" ]; then
                log "Đặt cờ LVM cho phân vùng $NEXT_PART..."
                if ! parted /dev/$DISK set $NEXT_PART lvm on 2>/dev/null; then
                    warning "Không thể đặt cờ LVM cho phân vùng $NEXT_PART."
                fi
            fi

            log "Cập nhật bảng phân vùng..."
            sync
            partprobe /dev/$DISK 2>/dev/null
            sleep 2

            if [[ "$DISK" == nvme* ]]; then
                NEW_PART="/dev/${DISK}p${NEXT_PART}"
            else
                NEW_PART="/dev/${DISK}${NEXT_PART}"
            fi

            if [ ! -e "$NEW_PART" ]; then
                warning "Không tìm thấy $NEW_PART. Thử quét lại..."
                for host in /sys/class/scsi_host/host*; do
                    [ -e "$host/scan" ] && echo "- - -" > "$host/scan"
                done
                sleep 2
            fi

            if [ ! -e "$NEW_PART" ]; then
                warning "Vẫn không tìm thấy $NEW_PART. Bỏ qua."
                continue
            fi

            log "Khởi tạo physical volume $NEW_PART..."
            if ! pvcreate "$NEW_PART" 2>/dev/null; then
                warning "Lỗi khi khởi tạo physical volume $NEW_PART."
                continue
            fi

            log "Thêm $NEW_PART vào volume group $VG_NAME..."
            if ! vgextend "$VG_NAME" "$NEW_PART" 2>/dev/null; then
                warning "Lỗi khi mở rộng volume group $VG_NAME."
                continue
            fi

            SPACE_ADDED=1
        done <<< "$UNALLOCATED"
    else
        log "Không tìm thấy không gian chưa phân vùng trên /dev/$DISK."
    fi

    # 2. Kiểm tra phân vùng hiện có chưa sử dụng
    log "Kiểm tra phân vùng hiện có trên /dev/$DISK..."
    PARTITIONS=$(parted /dev/$DISK print 2>/dev/null | grep -E "^ [0-9]" | awk '{print $1}')
    UNUSED_PARTITIONS=""

    for PART_NUM in $PARTITIONS; do
        if [[ "$DISK" == nvme* ]]; then
            PART_DEVICE="/dev/${DISK}p${PART_NUM}"
        else
            PART_DEVICE="/dev/${DISK}${PART_NUM}"
        fi

        if pvdisplay "$PART_DEVICE" >/dev/null 2>&1; then
            PART_SIZE=$(parted /dev/$DISK unit MB print 2>/dev/null | grep "^ $PART_NUM" | awk '{print $4}' | sed 's/MB//')
            USED_PARTITION_COUNT=$((USED_PARTITION_COUNT + 1))
            TOTAL_USED_PARTITION_SPACE=$((TOTAL_USED_PARTITION_SPACE + PART_SIZE))
            log "Phân vùng $PART_DEVICE ($PART_SIZE MB) đang được sử dụng trong LVM."
        else
            PART_SIZE=$(parted /dev/$DISK unit MB print 2>/dev/null | grep "^ $PART_NUM" | awk '{print $4}' | sed 's/MB//')
            if [ -n "$PART_SIZE" ] && [ "${PART_SIZE%.*}" -ge 100 ]; then
                UNUSED_PARTITIONS="$UNUSED_PARTITIONS $PART_DEVICE:$PART_SIZE"
                TOTAL_UNUSED_PARTITION_SPACE=$((TOTAL_UNUSED_PARTITING_SPACE + PART_SIZE))
            else
                log "Phân vùng $PART_DEVICE ($PART_SIZE MB) quá nhỏ, bỏ qua."
            fi
        fi
    done

    if [ -n "$UNUSED_PARTITIONS" ]; then
        log "Các phân vùng chưa được sử dụng trong LVM trên /dev/$DISK:"
        for PART in $UNUSED_PARTITIONS; do
            PART_DEVICE=${PART%%:*}
            PART_SIZE=${PART##*:}
            log "- $PART_DEVICE: $PART_SIZE MB"
        done
    else
        log "Không tìm thấy phân vùng chưa sử dụng đủ lớn trên /dev/$DISK."
    fi

    for PART in $UNUSED_PARTITIONS; do
        PART_DEVICE=${PART%%:*}
        PART_SIZE=${PART##*:}

        log "Xử lý phân vùng chưa sử dụng $PART_DEVICE ($PART_SIZE MB)..."

        if [ "$PART_TABLE" = "gpt" ]; then
            log "Đặt cờ LVM cho phân vùng $PART_DEVICE..."
            PART_NUM=$(echo "$PART_DEVICE" | grep -o '[0-9]\+$')
            if ! parted /dev/$DISK set $PART_NUM lvm on 2>/dev/null; then
                warning "Không thể đặt cờ LVM cho phân vùng $PART_DEVICE."
            fi
        fi

        log "Khởi tạo physical volume $PART_DEVICE..."
        if ! pvcreate "$PART_DEVICE" 2>/dev/null; then
            warning "Lỗi khi khởi tạo physical volume $PART_DEVICE."
            continue
        fi

        log "Thêm $PART_DEVICE vào volume group $VG_NAME..."
        if ! vgextend "$VG_NAME" "$PART_DEVICE" 2>/dev/null; then
            warning "Lỗi khi mở rộng volume group $VG_NAME."
            continue
        fi

        SPACE_ADDED=1
    done
done

# Báo cáo tổng quan dung lượng
log "Tổng quan dung lượng:"
log "- Số phân vùng đang sử dụng trong LVM: $USED_PARTITION_COUNT"
log "- Tổng dung lượng phân vùng đang sử dụng: $TOTAL_USED_PARTITION_SPACE MB"
log "- Tổng dung lượng không gian chưa phân vùng (>=100MB): $TOTAL_FREE_SPACE MB"
log "- Tổng dung lượng phân vùng chưa sử dụng (>=100MB): $TOTAL_UNUSED_PARTITION_SPACE MB"
TOTAL_EXPANDABLE=$((TOTAL_FREE_SPACE + TOTAL_UNUSED_PARTITION_SPACE))
log "- Tổng dung lượng có thể mở rộng: $TOTAL_EXPANDABLE MB ($((TOTAL_EXPANDABLE / 1024)) GB)"

# Kiểm tra dung lượng trống trong VG
FREE_PE=$(vgdisplay "$VG_NAME" 2>/dev/null | grep "Free  PE" | awk '{print $5}' || echo "0")
FREE_SIZE=$(vgdisplay "$VG_NAME" 2>/dev/null | grep "Free  PE" | awk '{print $5,$6,$7}' || echo "0")

if [ -z "$FREE_PE" ] || [ "$FREE_PE" -eq 0 ]; then
    if [ $SPACE_ADDED -eq 1 ]; then
        error "Đã thêm phân vùng nhưng không có dung lượng trống trong VG $VG_NAME. Kiểm tra với 'vgdisplay'."
    else
        log "Không tìm thấy dung lượng trống trong VG $VG_NAME hoặc trên ổ đĩa."
        log "Thông tin phân vùng hiện tại:"
        df -Th / | tee -a "$LOG_FILE"
        log "Kiểm tra log chi tiết tại: $LOG_FILE"
        exit 0
    fi
fi

log "Dung lượng trống trong VG: $FREE_SIZE"

# Mở rộng Logical Volume
log "Mở rộng Logical Volume $LV_PATH..."
if ! lvextend -l +100%FREE "$LV_PATH" 2>/dev/null; then
    error "Lỗi khi mở rộng Logical Volume $LV_PATH."
fi

# Mở rộng filesystem
case "$FSTYPE" in
    ext4)
        log "Mở rộng EXT4 filesystem..."
        if ! resize2fs "$ROOT_DEVICE" 2>/dev/null; then
            error "Lỗi khi mở rộng EXT4 filesystem."
        fi
        ;;
    xfs)
        log "Mở rộng XFS filesystem..."
        if ! xfs_growfs / 2>/dev/null; then
            error "Lỗi khi mở rộng XFS filesystem."
        fi
        ;;
    *)
        error "Filesystem $FSTYPE không được hỗ trợ."
        ;;
esac

log "Hoàn tất mở rộng phân vùng. Thông tin hiện tại:"
df -Th / | tee -a "$LOG_FILE"
log "Kiểm tra log chi tiết tại: $LOG_FILE"

log "Script hoàn tất thành công!"
