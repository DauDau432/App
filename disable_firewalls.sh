#!/bin/bash

echo "[+] Phát hiện hệ điều hành..."

if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    echo "[-] Không xác định được hệ điều hành!"
    exit 1
fi

echo "[+] Hệ điều hành phát hiện: $PRETTY_NAME"

disable_firewall() {
    local service_name=$1

    if systemctl list-units --type=service | grep -q "$service_name"; then
        echo "[+] Tìm thấy $service_name, tiến hành tắt..."
        systemctl stop "$service_name"
        systemctl disable "$service_name"
        systemctl mask "$service_name"
        echo "[+] Đã tắt và chặn $service_name"
    else
        echo "[-] $service_name không hoạt động hoặc không tồn tại."
    fi
}

echo "[+] Bắt đầu kiểm tra và vô hiệu hóa các firewall..."

disable_firewall firewalld.service
disable_firewall ufw.service
disable_firewall iptables.service
disable_firewall iptables-persistent.service
disable_firewall nftables.service

echo "[+] Xóa toàn bộ rule iptables..."

if command -v iptables >/dev/null 2>&1; then
    iptables -P INPUT ACCEPT
    iptables -P FORWARD ACCEPT
    iptables -P OUTPUT ACCEPT
    iptables -F
    iptables -X
    echo "[+] Đã xóa sạch rule iptables"
fi

if command -v nft >/dev/null 2>&1; then
    nft flush ruleset
    echo "[+] Đã xóa sạch ruleset nftables"
fi

echo "[+] Hoàn tất vô hiệu hóa firewall!"
