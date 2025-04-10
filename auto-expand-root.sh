#!/bin/bash

echo "[+] Bắt đầu kiểm tra và mở rộng phân vùng root..."

# Lấy thông tin thiết bị gắn với /
ROOT_DEVICE=$(findmnt -n -o SOURCE /)

# Lấy loại filesystem
FSTYPE=$(findmnt -n -o FSTYPE /)

# Kiểm tra OS
if [ -f /etc/os-release ]; then
    OS=$(grep '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')
else
    OS="unknown"
fi

echo "[+] Hệ điều hành: $OS"
echo "[+] Thiết bị root: $ROOT_DEVICE"
echo "[+] Filesystem: $FSTYPE"

# Kiểm tra có phải LVM không
if [[ "$ROOT_DEVICE" != /dev/mapper/* ]]; then
    echo "[x] Root không nằm trên LVM. Dừng script."
    exit 1
fi

# Thực thi mở rộng phù hợp với loại FS
case "$FSTYPE" in
    ext4)
        echo "[>] Mở rộng EXT4 với resize2fs..."
        resize2fs "$ROOT_DEVICE"
        ;;
    xfs)
        echo "[>] Mở rộng XFS với xfs_growfs..."
        xfs_growfs /
        ;;
    *)
        echo "[x] Filesystem $FSTYPE chưa được hỗ trợ."
        exit 1
        ;;
esac

echo "[+] Đã hoàn tất mở rộng. Thông tin hiện tại:"
df -Th /
