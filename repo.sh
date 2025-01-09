#!/bin/bash

# Kiểm tra hệ điều hành và package manager
if command -v apt >/dev/null 2>&1; then
    echo "Hệ điều hành sử dụng APT (Debian/Ubuntu). Đang đổi repo..."
    sudo sed -i.bak 's|http://[^ ]*|http://sg.archive.ubuntu.com|g' /etc/apt/sources.list
    sudo apt update
elif command -v yum >/dev/null 2>&1; then
    echo "Hệ điều hành sử dụng YUM (CentOS/RHEL). Đang đổi repo..."
    sudo sed -i.bak 's|mirrorlist=.*|baseurl=http://mirror.sg.leaseweb.net/centos/|g' /etc/yum.repos.d/CentOS-Base.repo
    sudo yum clean all && sudo yum makecache
elif command -v dnf >/dev/null 2>&1; then
    echo "Hệ điều hành sử dụng DNF (Fedora). Đang đổi repo..."
    sudo sed -i.bak 's|metalink=.*|baseurl=http://mirror.sg.leaseweb.net/fedora/linux/releases/$releasever/Everything/$basearch/os/|g' /etc/yum.repos.d/fedora.repo
    sudo dnf clean all && sudo dnf makecache
elif command -v pacman >/dev/null 2>&1; then
    echo "Hệ điều hành sử dụng Pacman (Arch Linux). Đang đổi repo..."
    sudo sed -i.bak 's|^Server =.*|Server = http://mirror.sg.leaseweb.net/archlinux/$repo/os/$arch|g' /etc/pacman.d/mirrorlist
    sudo pacman -Syy
else
    echo "Không nhận diện được package manager. Vui lòng kiểm tra thủ công."
    exit 1
fi

echo "Đổi repo thành công!"
