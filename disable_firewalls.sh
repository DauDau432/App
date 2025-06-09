#!/bin/bash
clear
echo ""
echo "[+] Xác định hệ điều hành..."

if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    echo "[-] Không xác định được hệ điều hành!"
    exit 1
fi

echo "[+] Hệ điều hành: $PRETTY_NAME"
SCRIPT_VERSION="1.2"
echo "[+] Phiên bản script: $SCRIPT_VERSION"

check_package() {
    local pkg=$1
    case $OS in
        centos|almalinux|rhel)
            rpm -q "$pkg" >/dev/null 2>&1 && return 0 || return 1
            ;;
        ubuntu|debian)
            # Kiểm tra xem gói có tồn tại và ở trạng thái 'ii' (đã cài đặt)
            dpkg -l "$pkg" 2>/dev/null | grep -q "^ii  $pkg " && return 0 || return 1
            ;;
        *)
            return 1
            ;;
    esac
}

remove_package() {
    local pkg=$1
    local service_name=$2

    if check_package "$pkg"; then
        echo "[+] Gói $pkg được cài đặt, tiến hành gỡ cài đặt..."
        # Dừng dịch vụ trước khi gỡ nếu nó đang chạy
        if systemctl is-active --quiet "$service_name"; then
            systemctl stop "$service_name"
            echo "[+] Đã dừng $service_name"
        fi
        # Gỡ cài đặt gói và xóa file cấu hình
        case $OS in
            centos|almalinux|rhel)
                yum remove -y "$pkg" >/dev/null 2>&1 || dnf remove -y "$pkg" >/dev/null 2>&1
                echo "[+] Đã gỡ $pkg"
                ;;
            ubuntu|debian)
                apt-get remove --purge -y "$pkg" >/dev/null 2>&1
                dpkg --purge "$pkg" >/dev/null 2>&1
                apt-get autoremove -y >/dev/null 2>&1
                echo "[+] Đã gỡ $pkg"
                ;;
        esac
    else
        echo "[-] Gói $pkg không được cài đặt."
    fi
}

echo "[+] Bắt đầu gỡ cài đặt các firewall..."

# Gỡ cài đặt các firewall phổ biến
remove_package firewalld firewalld.service
remove_package ufw ufw.service
remove_package iptables iptables.service
remove_package netfilter-persistent netfilter-persistent.service
remove_package nftables nftables.service
remove_package csf csf.service
remove_package fail2ban fail2ban.service

# Xóa rule iptables và ip6tables nếu công cụ tồn tại
if command -v iptables >/dev/null 2>&1; then
    echo "[+] Xóa toàn bộ rule iptables và ip6tables..."
    iptables -P INPUT ACCEPT
    iptables -P FORWARD ACCEPT
    iptables -P OUTPUT ACCEPT
    iptables -F
    iptables -X
    ip6tables -P INPUT ACCEPT
    ip6tables -P FORWARD ACCEPT
    ip6tables -P OUTPUT ACCEPT
    ip6tables -F
    ip6tables -X
    iptables-save > /etc/iptables/rules.v4 2>/dev/null
    ip6tables-save > /etc/iptables/rules.v6 2>/dev/null
    echo "[+] Đã xóa sạch rule iptables và ip6tables"
else
    echo "[-] iptables không được cài đặt."
fi

# Xóa ruleset nftables nếu công cụ tồn tại
if command -v nft >/dev/null 2>&1; then
    echo "[+] Xóa toàn bộ ruleset nftables..."
    nft flush ruleset
    nft list ruleset > /etc/nftables.conf 2>/dev/null
    echo "[+] Đã xóa sạch ruleset nftables"
else
    echo "[-] nftables không được cài đặt."
fi

echo "[+] Kiểm tra các script khởi động thủ công..."
if [ -f /etc/rc.local ] && grep -q -E "iptables|nft|ufw|firewalld|csf|fail2ban" /etc/rc.local; then
    echo "[!] Cảnh báo: Tìm thấy script khởi động firewall trong /etc/rc.local. Vui lòng kiểm tra thủ công."
fi

echo "[+] Hoàn tất gỡ cài đặt và vô hiệu hóa firewall!"
