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
SCRIPT_VERSION="1.7.0"
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

# Hàm kiểm tra package
check_package() {
    local pkg=$1
    case $OS in
        centos|almalinux|rhel|cloudlinux)
            rpm -q "$pkg" >/dev/null 2>&1 && return 0 || return 1 ;;
        ubuntu|debian)
            dpkg -l "$pkg" 2>/dev/null | grep -q "^ii  $pkg " && return 0 || return 1 ;;
        *) return 1 ;;
    esac
}

# Kiểm tra iptables
check_iptables() {
    if command -v iptables >/dev/null 2>&1; then
        IPTABLES_VERSION=$(iptables --version | head -n1)
        return 0
    else
        echo "[-] iptables chưa được cài đặt. Vui lòng cài đặt iptables trước khi sử dụng chức năng này."
        return 1
    fi
}

# Lựa chọn 1: Cho phép Cloudflare 80/443, chặn IP khác + xóa kết nối cũ
configure_cloudflare_rules() {
    if ! check_iptables; then return 1; fi
    echo "[+] Sử dụng danh sách IP Cloudflare tĩnh (IPv4 và IPv6)..."

    echo "[+] Cấu hình rule iptables cho Cloudflare (IPv4)..."
    iptables -F
    iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables -A INPUT -p tcp --dport 22 -j ACCEPT

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
    ip6tables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    ip6tables -A INPUT -p tcp --dport 22 -j ACCEPT

    for ip in $CLOUDFLARE_IPS_V6; do
        ip6tables -A INPUT -p tcp -s "$ip" --dport 80 -j ACCEPT
        ip6tables -A INPUT -p tcp -s "$ip" --dport 443 -j ACCEPT
    done
    ip6tables -A INPUT -p tcp --dport 80 -j DROP
    ip6tables -A INPUT -p tcp --dport 443 -j DROP
    ip6tables-save > /etc/iptables/rules.v6

    echo "[+] Xóa toàn bộ kết nối cũ trên cổng 80/443..."
    conntrack -D -p tcp --dport 80 >/dev/null 2>&1
    conntrack -D -p tcp --dport 443 >/dev/null 2>&1

    echo "[+] Đã cấu hình rule cho Cloudflare (IPv4 & IPv6) và xóa kết nối cũ."
}

# Lựa chọn 6: Chặn toàn bộ Cloudflare + xóa kết nối cũ
block_cloudflare_ips() {
    if ! check_iptables; then return 1; fi
    echo "[+] Chặn IP Cloudflare bằng iptables (IPv4)..."
    iptables -F
    iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables -A INPUT -p tcp --dport 22 -j ACCEPT

    for ip in $CLOUDFLARE_IPS_V4; do
        iptables -A INPUT -s "$ip" -j DROP
    done
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4

    echo "[+] Chặn IP Cloudflare bằng ip6tables (IPv6)..."
    ip6tables -F
    ip6tables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    ip6tables -A INPUT -p tcp --dport 22 -j ACCEPT

    for ip in $CLOUDFLARE_IPS_V6; do
        ip6tables -A INPUT -s "$ip" -j DROP
    done
    ip6tables-save > /etc/iptables/rules.v6

    echo "[+] Xóa toàn bộ kết nối cũ trên cổng 80/443..."
    conntrack -D -p tcp --dport 80 >/dev/null 2>&1
    conntrack -D -p tcp --dport 443 >/dev/null 2>&1

    echo "[+] Đã chặn toàn bộ IP Cloudflare và xóa kết nối cũ (80/443)."
}

# Lựa chọn 7: Xóa kết nối trên port bất kỳ
clear_connections_on_port() {
    if ! command -v conntrack >/dev/null 2>&1; then
        echo "[-] Gói conntrack chưa được cài. Đang cài đặt..."
        case $OS in
            centos|almalinux|rhel|cloudlinux)
                yum install -y conntrack-tools >/dev/null 2>&1 || dnf install -y conntrack-tools >/dev/null 2>&1 ;;
            ubuntu|debian)
                apt-get update >/dev/null 2>&1
                apt-get install -y conntrack >/dev/null 2>&1 ;;
        esac
    fi

    echo -n "[+] Nhập số cổng muốn xóa kết nối (ví dụ 80, 443, 22): "
    read -r PORT
    if [[ ! "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
        echo "[-] Cổng không hợp lệ!"
        return 1
    fi

    echo "[+] Đang xóa toàn bộ kết nối hiện tại đến/đi từ cổng $PORT..."
    conntrack -D -p tcp --dport "$PORT" >/dev/null 2>&1
    conntrack -D -p tcp --sport "$PORT" >/dev/null 2>&1
    echo "[+] Đã xóa tất cả kết nối TCP liên quan đến cổng $PORT."
}

# Menu
while true; do
    echo "================================="
    echo " MENU QUẢN LÝ FIREWALL "
    echo "================================="
    echo "1. Cho phép IP Cloudflare, chặn 80/443 cho IP khác (xóa kết nối cũ)"
    echo "2. Thêm IP/subnet vào danh sách được phép"
    echo "3. Gỡ rule chặn cổng 80/443"
    echo "4. Cài đặt iptables"
    echo "5. Gỡ cài đặt tất cả firewall"
    echo "6. Chặn toàn bộ IP Cloudflare (xóa kết nối cũ)"
    echo "7. Xóa toàn bộ kết nối hiện tại trên 1 cổng"
    echo "0. Thoát"
    echo "================================="
    echo -n "Nhập lựa chọn của bạn [0-7]: "
    read choice
    case $choice in
        1) configure_cloudflare_rules; echo "" ;;
        2) add_custom_ip_subnet; echo "" ;;
        3) remove_port_restrictions; echo "" ;;
        4) install_iptables; echo "" ;;
        5) remove_all_firewalls; echo "" ;;
        6) block_cloudflare_ips; echo "" ;;
        7) clear_connections_on_port; echo "" ;;
        0) echo "[+] Thoát chương trình."; exit 0 ;;
        *) echo "[-] Lựa chọn không hợp lệ! Vui lòng chọn lại."; echo "" ;;
    esac
done
