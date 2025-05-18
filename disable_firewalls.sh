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

check_package() {
    local pkg=$1
    case $OS in
        centos|almalinux|rhel)
            rpm -q "$pkg" >/dev/null 2>&1 && return 0 || return 1
            ;;
        ubuntu|debian)
            dpkg -l "$pkg" >/dev/null 2>&1 && return 0 || return 1
            ;;
        *)
            return 1
            ;;
    esac
}

disable_firewall() {
    local service_name=$1
    local pkg_name=$2

    if check_package "$pkg_name"; then
        echo "[+] Gói $pkg_name được cài đặt."
        if systemctl is-active --quiet "$service_name"; then
            echo "[+] $service_name đang chạy, tiến hành tắt..."
            systemctl stop "$service_name"
            systemctl disable "$service_name"
            systemctl mask "$service_name"
            echo "[+] Đã tắt và chặn $service_name"
        else
            echo "[-] $service_name không chạy nhưng gói được cài đặt."
        fi
    else
        echo "[-] Gói $pkg_name không được cài đặt."
    fi
}

echo "[+] Bắt đầu kiểm tra và vô hiệu hóa các firewall..."

# Kiểm tra các firewall phổ biến
disable_firewall firewalld.service firewalld
disable_firewall ufw.service ufw
disable_firewall iptables.service iptables
disable_firewall netfilter-persistent.service netfilter-persistent
disable_firewall nftables.service nftables
disable_firewall csf.service csf
disable_firewall fail2ban.service fail2ban

echo "[+] Xóa toàn bộ rule iptables và ip6tables..."

if command -v iptables >/dev/null 2>&1; then
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

if command -v nft >/dev/null 2>&1; then
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

echo "[+] Hoàn tất vô hiệu hóa firewall!"
