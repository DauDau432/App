#!/bin/bash
# Kiểm tra quyền root
if [ "$(id -u)" -ne 0 ]; then
    echo "[-] Lỗi: Script này cần được chạy với quyền root (sudo)."
    exit 1
fi
clear
echo ""
echo "[+] Công cụ quản lý firewall"
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    echo "[-] Không xác định được hệ điều hành!"
    exit 1
fi
echo "[+] Hệ điều hành: $PRETTY_NAME"
SCRIPT_VERSION="1.6.3"
echo "[+] Phiên bản script: $SCRIPT_VERSION"
# Danh sách Cloudflare IP tĩnh
CLOUDFLARE_IPS_V4="173.245.48.0/20
185.122.0.0/22
92.8.0.0/15
103.21.244.0/22
103.22.200.0/22
103.31.4.0/22
104.16.0.0/13
104.24.0.0/14
108.162.192.0/18
131.0.72.0/22
141.101.64.0/18
162.158.0.0/15
172.64.0.0/13
188.114.96.0/20
190.93.240.0/20
197.234.240.0/22
198.41.128.0/17
199.27.128.0/21
45.32.0.0/19"
CLOUDFLARE_IPS_V6="2400:cb00::/32
2a06:98c1::/32
2a06:98c2::/32
2a06:98c3::/32
2606:4700::/32
2803:f800::/32
2405:b500::/32
2405:8100::/32
2a06:98c0::/29
2c0f:f248::/32"
# Định nghĩa các hàm
check_package() {
    local pkg=$1
    case $OS in
        centos|almalinux|rhel|cloudlinux)
            rpm -q "$pkg" >/dev/null 2>&1 && return 0 || return 1
            ;;
        ubuntu|debian)
            dpkg -l "$pkg" 2>/dev/null | grep -q "^ii $pkg " && return 0 || return 1
            ;;
        *)
            return 1
            ;;
    esac
}
check_iptables() {
    if command -v iptables >/dev/null 2>&1; then
        IPTABLES_VERSION=$(iptables --version | head -n1)
        return 0
    else
        echo "[-] iptables chưa được cài đặt. Vui lòng cài đặt iptables trước khi sử dụng chức năng này."
        return 1
    fi
}
install_package() {
    local pkg=$1
    echo "[+] Cài đặt $pkg..."
    case $OS in
        centos|almalinux|rhel|cloudlinux)
            yum install -y "$pkg" >/dev/null 2>&1 || dnf install -y "$pkg" >/dev/null 2>&1
            ;;
        ubuntu|debian)
            apt-get update >/dev/null 2>&1
            apt-get install -y "$pkg" >/dev/null 2>&1
            ;;
    esac
    if check_package "$pkg"; then
        echo "[+] $pkg đã được cài đặt."
    else
        echo "[-] Không thể cài đặt $pkg."
        return 1
    fi
}
remove_package() {
    local pkg=$1
    local service_name=$2
    if check_package "$pkg"; then
        echo "[+] Gói $pkg được cài đặt, tiến hành gỡ cài đặt..."
        if systemctl is-active --quiet "$service_name"; then
            systemctl stop "$service_name"
            echo "[+] Đã dừng $service_name"
        fi
        case $OS in
            centos|almalinux|rhel|cloudlinux)
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
configure_cloudflare_rules() {
    if ! check_iptables; then
        return 1
    fi
    echo "[+] Sử dụng danh sách IP Cloudflare tĩnh (IPv4 và IPv6)..."
    echo "[+] Cấu hình rule iptables cho Cloudflare (IPv4)..."
    iptables -F
    for ip in $CLOUDFLARE_IPS_V4; do
        iptables -A INPUT -p tcp -s "$ip" --dport 80 -j ACCEPT
        iptables -A INPUT -p tcp -s "$ip" --dport 443 -j ACCEPT
    done
    iptables -A INPUT -p tcp --dport 80 -j DROP
    iptables -A INPUT -p tcp --dport 443 -j DROP
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4
    echo "[+] Cấu hình rule ip6tables cho Cloudflare (IPv6)..."
    ip6tables -F
    for ip in $CLOUDFLARE_IPS_V6; do
        ip6tables -A INPUT -p tcp -s "$ip" --dport 80 -j ACCEPT
        ip6tables -A INPUT -p tcp -s "$ip" --dport 443 -j ACCEPT
    done
    ip6tables -A INPUT -p tcp --dport 80 -j DROP
    ip6tables -A INPUT -p tcp --dport 443 -j DROP
    ip6tables-save > /etc/iptables/rules.v6
    echo "[+] Đã cấu hình rule cho Cloudflare (IPv4 và IPv6)."
}
block_cloudflare_ips() {
    if ! check_iptables; then
        return 1
    fi
    echo "[+] Chặn IP Cloudflare bằng iptables (IPv4)..."
    iptables -F
    for ip in $CLOUDFLARE_IPS_V4; do
        iptables -A INPUT -s "$ip" -j DROP
    done
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4
    echo "[+] Chặn IP Cloudflare bằng ip6tables (IPv6)..."
    ip6tables -F
    for ip in $CLOUDFLARE_IPS_V6; do
        ip6tables -A INPUT -s "$ip" -j DROP
    done
    ip6tables-save > /etc/iptables/rules.v6
    echo "[+] Đã chặn toàn bộ IP Cloudflare (IPv4 & IPv6)."
}
add_custom_ip_subnet() {
    if ! check_iptables; then
        return 1
    fi
    while true; do
        echo "[+] Nhập địa chỉ IP hoặc subnet (ví dụ: 192.168.1.1 hoặc 192.168.1.0/24):"
        read -r CUSTOM_IP
        if [[ ! "$CUSTOM_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]] && [[ ! "$CUSTOM_IP" =~ ^([0-9a-fA-F:]+(/[0-9]{1,3})?)$ ]]; then
            echo "[-] Địa chỉ IP hoặc subnet không hợp lệ!"
            continue
        fi
        echo "[+] Chọn kiểu rule:"
        echo "  0. Quay lại"
        echo "  1. Thêm rule INPUT/OUTPUT cho IP/subnet"
        echo "  2. Thêm rule cho cổng 80/443 (như cũ)"
        read -r rule_choice
        case $rule_choice in
            0)
                echo "[+] Quay lại menu chính."
                return 0
                ;;
            1)
                echo "[+] Thêm rule INPUT/OUTPUT cho $CUSTOM_IP..."
                if [[ "$CUSTOM_IP" =~ : ]]; then
                    ip6tables -I INPUT -s "$CUSTOM_IP" -j ACCEPT
                    ip6tables -I OUTPUT -d "$CUSTOM_IP" -j ACCEPT
                else
                    iptables -I INPUT -s "$CUSTOM_IP" -j ACCEPT
                    iptables -I OUTPUT -d "$CUSTOM_IP" -j ACCEPT
                fi
                echo "[+] Đã thêm rule INPUT/OUTPUT cho $CUSTOM_IP."
                ;;
            2)
                echo "[+] Thêm rule iptables cho $CUSTOM_IP (cổng 80/443)..."
                iptables -D INPUT -p tcp --dport 80 -j DROP 2>/dev/null
                iptables -D INPUT -p tcp --dport 443 -j DROP 2>/dev/null
                ip6tables -D INPUT -p tcp --dport 80 -j DROP 2>/dev/null
                ip6tables -D INPUT -p tcp --dport 443 -j DROP 2>/dev/null
                if [[ "$CUSTOM_IP" =~ : ]]; then
                    ip6tables -A INPUT -p tcp -s "$CUSTOM_IP" --dport 80 -j ACCEPT
                    ip6tables -A INPUT -p tcp -s "$CUSTOM_IP" --dport 443 -j ACCEPT
                else
                    iptables -A INPUT -p tcp -s "$CUSTOM_IP" --dport 80 -j ACCEPT
                    iptables -A INPUT -p tcp -s "$CUSTOM_IP" --dport 443 -j ACCEPT
                fi
                iptables -A INPUT -p tcp --dport 80 -j DROP
                iptables -A INPUT -p tcp --dport 443 -j DROP
                ip6tables -A INPUT -p tcp --dport 80 -j DROP
                ip6tables -A INPUT -p tcp --dport 443 -j DROP
                echo "[+] Đã thêm $CUSTOM_IP vào danh sách được phép (cổng 80/443)."
                ;;
            *)
                echo "[-] Lựa chọn không hợp lệ! Vui lòng chọn lại."
                continue
                ;;
        esac
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4
        ip6tables-save > /etc/iptables/rules.v6
        return 0
    done
}
remove_port_restrictions() {
    if ! check_iptables; then
        return 1
    fi
    echo "[+] Gỡ rule chặn cổng 80 và 443..."
    iptables -F
    iptables -P INPUT ACCEPT
    iptables -P FORWARD ACCEPT
    iptables -P OUTPUT ACCEPT
    ip6tables -F
    ip6tables -P INPUT ACCEPT
    ip6tables -P FORWARD ACCEPT
    ip6tables -P OUTPUT ACCEPT
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4
    ip6tables-save > /etc/iptables/rules.v6
    echo "[+] Đã gỡ rule chặn cổng 80 và 443."
}
install_iptables() {
    echo "[+] Cài đặt iptables..."
    install_package iptables
    if check_package iptables; then
        IPTABLES_VERSION=$(iptables --version | head -n1)
        echo "[+] Phiên bản iptables được cài đặt: $IPTABLES_VERSION"
        echo "[+] Đảm bảo ip6tables được cài đặt..."
        install_package ip6tables
        if check_package ip6tables; then
            IP6TABLES_VERSION=$(ip6tables --version | head -n1)
            echo "[+] Phiên bản ip6tables được cài đặt: $IP6TABLES_VERSION"
        fi
    fi
}
remove_all_firewalls() {
    while true; do
        echo "[+] Bạn có chắc chắn muốn gỡ cài đặt tất cả firewall?"
        echo "  0. Quay lại"
        echo "  1. Tiếp tục gỡ cài đặt"
        read -r confirm_choice
        case $confirm_choice in
            0)
                echo "[+] Quay lại menu chính."
                return 0
                ;;
            1)
                remove_package firewalld firewalld.service
                remove_package ufw ufw.service
                remove_package iptables iptables.service
                remove_package netfilter-persistent netfilter-persistent.service
                remove_package nftables nftables.service
                remove_package csf csf.service
                remove_package fail2ban fail2ban.service
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
                    mkdir -p /etc/iptables
                    iptables-save > /etc/iptables/rules.v4
                    ip6tables-save > /etc/iptables/rules.v6
                    echo "[+] Đã xóa sạch rule iptables và ip6tables"
                else
                    echo "[-] iptables không được cài đặt."
                fi
                if command -v nft >/dev/null 2>&1; then
                    echo "[+] Xóa toàn bộ ruleset nftables..."
                    nft flush ruleset
                    nft list ruleset > /etc/nftables.conf 2>/dev/null
                    echo "[+] Đã xóa sạch ruleset nftables"
                else
                    echo "[-] nftables không được cài đặt."
                fi
                if [ -f /etc/rc.local ] && grep -q -E "iptables|nft|ufw|firewalld|csf|fail2ban" /etc/rc.local; then
                    echo "[!] Cảnh báo: Tìm thấy script khởi động firewall trong /etc/rc.local. Vui lòng kiểm tra thủ công."
                fi
                return 0
                ;;
            *)
                echo "[-] Lựa chọn không hợp lệ! Vui lòng chọn lại."
                continue
                ;;
        esac
    done
}
# Kiểm tra và hiển thị danh sách firewall đã cài đặt
echo "[+] Các firewall hiện có:"
FIREWALLS=("firewalld" "ufw" "iptables" "netfilter-persistent" "nftables" "csf" "fail2ban")
FOUND_FIREWALL=false
for pkg in "${FIREWALLS[@]}"; do
    if [ "$pkg" = "iptables" ]; then
        if command -v iptables >/dev/null 2>&1; then
            IPTABLES_VERSION=$(iptables --version | head -n1 2>/dev/null || echo "Không xác định")
            echo " - $pkg: $IPTABLES_VERSION"
            FOUND_FIREWALL=true
        fi
    elif check_package "$pkg"; then
        echo " - $pkg: Đã cài đặt"
        FOUND_FIREWALL=true
    fi
done
if ! $FOUND_FIREWALL; then
    echo " - Không tìm thấy firewall nào."
fi
echo ""
while true; do
    echo "================================="
    echo " MENU QUẢN LÝ FIREWALL "
    echo "================================="
    echo "1. Cho phép IP Cloudflare, chặn cổng 80/443 cho IP khác"
    echo "2. Thêm IP/subnet vào danh sách được phép"
    echo "3. Gỡ rule chặn cổng 80/443"
    echo "4. Cài đặt iptables"
    echo "5. Gỡ cài đặt tất cả firewall"
    echo "6. Chặn toàn bộ IP Cloudflare (IPv4 & IPv6)"
    echo "0. Thoát"
    echo "================================="
    echo -n "Nhập lựa chọn của bạn [0-6]: "
    read choice
    case $choice in
        1)
            configure_cloudflare_rules
            echo ""
            ;;
        2)
            add_custom_ip_subnet
            echo ""
            ;;
        3)
            remove_port_restrictions
            echo ""
            ;;
        4)
            install_iptables
            echo ""
            ;;
        5)
            remove_all_firewalls
            echo ""
            ;;
        6)
            block_cloudflare_ips
            echo ""
            ;;
        0)
            echo "[+] Thoát chương trình."
            exit 0
            ;;
        *)
            echo "[-] Lựa chọn không hợp lệ! Vui lòng chọn lại."
            echo ""
            ;;
    esac
done
