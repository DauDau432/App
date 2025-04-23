#!/bin/bash
echo "[+] Bắt đầu kiểm tra và mở rộng phân vùng root..."

# Lấy thông tin thiết bị gắn với /
ROOT_DEVICE=$(findmnt -n -o SOURCE /) || { echo "[x] Không tìm thấy thiết bị root."; exit 1; }

# Lấy loại filesystem
FSTYPE=$(findmnt -n -o FSTYPE /) || { echo "[x] Không xác định được filesystem."; exit 1; }

# Kiểm tra OS
OS=$(grep '^ID=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "unknown")

echo "[+] Hệ điều hành: $OS"
echo "[+] Thiết bị root: $ROOT_DEVICE"
echo "[+] Filesystem: $FSTYPE"

# Kiểm tra có phải LVM không
if [[ "$ROOT_DEVICE" != /dev/mapper/* ]]; then
    echo "[x] Root không nằm trên LVM. Dừng script."
    exit 1
fi

# Lấy tên Volume Group (VG) và Logical Volume (LV)
VG_NAME=$(vgdisplay | awk '/VG Name/{print $3; exit}') || { echo "[x] Không tìm thấy Volume Group."; exit 1; }
LV_NAME=$(lvdisplay "$ROOT_DEVICE" | awk '/LV Path/{print $3}') || { echo "[x] Không tìm thấy Logical Volume."; exit 1; }

echo "[+] Volume Group: $VG_NAME"
echo "[+] Logical Volume: $LV_NAME"

# Kiểm tra dung lượng trống trong VG
FREE_PE=$(vgdisplay "$VG_NAME" | awk '/Free  PE/{print $5}') || { echo "[x] Lỗi khi kiểm tra dung lượng VG."; exit 1; }
if [ "$FREE_PE" -eq 0 ]; then
    echo "[x] Không còn dung lượng trống trong Volume Group $VG_NAME."
    echo "[+] Thông tin phân vùng hiện tại:"
    df -Th /
    exit 0
fi
echo "[+] Dung lượng trống khả dụng: $FREE_PE PE"

# Mở rộng Logical Volume
echo "[>] Mở rộng Logical Volume thêm 100% dung lượng trống..."
lvextend -l +100%FREE "$LV_NAME" || { echo "[x] Lỗi khi mở rộng Logical Volume."; exit 1; }

# Mở rộng filesystem
case "$FSTYPE" in
    ext4)
        echo "[>] Mở rộng EXT4 với resize2fs..."
        resize2fs "$ROOT_DEVICE" || { echo "[x] Lỗi khi mở rộng EXT4."; exit 1; }
        ;;
    xfs)
        echo "[>] Mở rộng XFS với xfs_growfs..."
        xfs_growfs / || { echo "[x] Lỗi khi mở rộng XFS."; exit 1; }
        ;;
    *)
        echo "[x] Filesystem $FSTYPE chưa được hỗ trợ."
        exit 1
        ;;
esac

echo "[+] Đã hoàn tất mở rộng. Thông tin phân vùng hiện tại:"
df -Th /
