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
SCRIPT_VERSION="1.8.2"
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
# ===== HÀM DÙNG CHUNG =====
check_package() {
    local pkg=$1
    case $OS in
        centos|almalinux|rhel|cloudlinux)
            rpm -q "$pkg" >/dev/null 2>&1 && return 0 || return 1 ;;
        ubuntu|debian)
            # Kiểm tra gói chính hoặc gói liên quan (iptables-persistent)
            dpkg -l "$pkg" 2>/dev/null | grep -q "^ii $pkg " && return 0
            if [ "$pkg" = "iptables" ]; then
                dpkg -l "iptables-persistent" 2>/dev/null | grep -q "^ii iptables-persistent " && return 0
            fi
            return 1 ;;
        *) return 1 ;;
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
            yum install -y "$pkg" >/dev/null 2>&1 || dnf install -y "$pkg" >/dev/null 2>&1 ;;
        ubuntu|debian)
            apt-get update >/dev/null 2>&1
            apt-get install -y "$pkg" >/dev/null 2>&1 ;;
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
                echo "[+] Đã gỡ $pkg" ;;
            ubuntu|debian)
                apt-get remove --purge -y "$pkg" >/dev/null 2>&1
                dpkg --purge "$pkg" >/dev/null 2>&1
                apt-get autoremove -y >/dev/null 2>&1
                echo "[+] Đã gỡ $pkg" ;;
        esac
    else
        echo "[-] Gói $pkg không được cài đặt."
    fi
}
ensure_conntrack() {
    if ! command -v conntrack >/dev/null 2>&1; then
        echo "[-] conntrack chưa có. Đang cài đặt..."
        case $OS in
            centos|almalinux|rhel|cloudlinux)
                yum install -y conntrack-tools >/dev/null 2>&1 || dnf install -y conntrack-tools >/dev/null 2>&1 ;;
            ubuntu|debian)
                apt-get update >/dev/null 2>&1
                apt-get install -y conntrack >/dev/null 2>&1 ;;
        esac
    fi
}
# ===== CÁC HÀM GỐC (ĐÃ SỬA) =====
configure_cloudflare_rules() {
    if ! check_iptables; then
        return 1
    fi
    echo "[+] Sử dụng danh sách IP Cloudflare tĩnh (IPv4 và IPv6)..."
    # Tự động phát hiện các cổng đang mở
    echo "[+] Phát hiện các cổng đang mở trên hệ thống..."
    OPEN_PORTS=$(ss -tulnp 2>/dev/null | grep -E 'LISTEN' | awk '{print $5}' | cut -d: -f2 | sort -u || echo "")
    if [ -z "$OPEN_PORTS" ]; then
        echo "[-] Không tìm thấy cổng đang mở hoặc công cụ ss không được cài đặt."
        echo "[+] Nhập các cổng cần cho phép (cách nhau bằng dấu cách, ví dụ: 35053 8080, hoặc nhấn Enter để bỏ qua):"
        read -r CUSTOM_PORTS
    else
        echo "[+] Các cổng đang mở: $OPEN_PORTS"
        echo "[+] Nhập thêm cổng cần cho phép (nếu có, cách nhau bằng dấu cách, hoặc nhấn Enter để bỏ qua):"
        read -r CUSTOM_PORTS
    fi
    echo "[+] Cấu hình rule iptables cho Cloudflare (IPv4)..."
    iptables -F
    iptables -P INPUT ACCEPT
    iptables -P FORWARD ACCEPT
    iptables -P OUTPUT ACCEPT
    iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables -A INPUT -p tcp --dport 22 -j ACCEPT
    # Thêm quy tắc ACCEPT cho các cổng đang mở
    for port in $OPEN_PORTS; do
        if [[ "$port" != "80" && "$port" != "443" && "$port" != "22" ]]; then
            iptables -A INPUT -p tcp --dport "$port" -j ACCEPT
            echo "[+] Đã cho phép cổng $port (IPv4)."
        fi
    done
    # Thêm quy tắc ACCEPT cho các cổng tùy chỉnh
    for port in $CUSTOM_PORTS; do
        if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] && [[ "$port" != "80" && "$port" != "443" && "$port" != "22" ]]; then
            iptables -A INPUT -p tcp --dport "$port" -j ACCEPT
            echo "[+] Đã cho phép cổng tùy chỉnh $port (IPv4)."
        fi
    done
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
    ip6tables -P INPUT ACCEPT
    ip6tables -P FORWARD ACCEPT
    ip6tables -P OUTPUT ACCEPT
    ip6tables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    ip6tables -A INPUT -p tcp --dport 22 -j ACCEPT
    for port in $OPEN_PORTS; do
        if [[ "$port" != "80" && "$port" != "443" && "$port" != "22" ]]; then
            ip6tables -A INPUT -p tcp --dport "$port" -j ACCEPT
            echo "[+] Đã cho phép cổng $port (IPv6)."
        fi
    done
    for port in $CUSTOM_PORTS; do
        if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] && [[ "$port" != "80" && "$port" != "443" && "$port" != "22" ]]; then
            ip6tables -A INPUT -p tcp --dport "$port" -j ACCEPT
            echo "[+] Đã cho phép cổng tùy chỉnh $port (IPv6)."
        fi
    done
    for ip in $CLOUDFLARE_IPS_V6; do
        ip6tables -A INPUT -p tcp -s "$ip" --dport 80 -j ACCEPT
        ip6tables -A INPUT -p tcp -s "$ip" --dport 443 -j ACCEPT
    done
    ip6tables -A INPUT -p tcp --dport 80 -j DROP
    ip6tables -A INPUT -p tcp --dport 443 -j DROP
    ip6tables-save > /etc/iptables/rules.v6
    ensure_conntrack
    echo "[+] Xóa toàn bộ kết nối cũ trên cổng 80/443..."
    conntrack -D -p tcp --dport 80 >/dev/null 2>&1
    conntrack -D -p tcp --dport 443 >/dev/null 2>&1
    echo "[+] Đã cấu hình rule cho Cloudflare (IPv4 & IPv6) và xóa kết nối cũ."
    echo "[+] Tất cả các cổng khác ngoài 80/443 đều được phép truy cập."
}
add_custom_ip_subnet() {
    if ! check_iptables; then
        return 1
    fi
    iptables -P INPUT ACCEPT
    iptables -P FORWARD ACCEPT
    iptables -P OUTPUT ACCEPT
    ip6tables -P INPUT ACCEPT
    ip6tables -P FORWARD ACCEPT
    ip6tables -P OUTPUT ACCEPT
    echo "[+] Phát hiện các cổng đang mở trên hệ thống..."
    OPEN_PORTS=$(ss -tulnp 2>/dev/null | grep -E 'LISTEN' | awk '{print $5}' | cut -d: -f2 | sort -u || echo "")
    if [ -z "$OPEN_PORTS" ]; then
        echo "[-] Không tìm thấy cổng đang mở hoặc công cụ ss không được cài đặt."
        echo "[+] Nhập các cổng cần cho phép (cách nhau bằng dấu cách, ví dụ: 35053 8080, hoặc nhấn Enter để bỏ qua):"
        read -r CUSTOM_PORTS
    else
        echo "[+] Các cổng đang mở: $OPEN_PORTS"
        echo "[+] Nhập thêm cổng cần cho phép (nếu có, cách nhau bằng dấu cách, hoặc nhấn Enter để bỏ qua):"
        read -r CUSTOM_PORTS
    fi
    while true; do
        echo "[+] Nhập địa chỉ IP hoặc subnet (ví dụ: 192.168.1.1 hoặc 192.168.1.0/24):"
        read -r CUSTOM_IP
        if [[ ! "$CUSTOM_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]] && [[ ! "$CUSTOM_IP" =~ ^([0-9a-fA-F:]+(/[0-9]{1,3})?)$ ]]; then
            echo "[-] Địa chỉ IP hoặc subnet không hợp lệ!"
            continue
        fi
        echo "[+] Chọn kiểu rule:"
        echo " 0. Quay lại"
        echo " 1. Thêm rule INPUT/OUTPUT cho IP/subnet"
        echo " 2. Thêm rule cho cổng 80/443"
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
                for port in $OPEN_PORTS; do
                    if [[ "$port" != "80" && "$port" != "443" && "$port" != "22" ]]; then
                        iptables -A INPUT -p tcp --dport "$port" -j ACCEPT
                        ip6tables -A INPUT -p tcp --dport "$port" -j ACCEPT
                        echo "[+] Đã cho phép cổng $port."
                    fi
                done
                for port in $CUSTOM_PORTS; do
                    if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] && [[ "$port" != "80" && "$port" != "443" && "$port" != "22" ]]; then
                        iptables -A INPUT -p tcp --dport "$port" -j ACCEPT
                        ip6tables -A INPUT -p tcp --dport "$port" -j ACCEPT
                        echo "[+] Đã cho phép cổng tùy chỉnh $port."
                    fi
                done
                iptables -A INPUT -p tcp --dport 80 -j DROP
                iptables -A INPUT -p tcp --dport 443 -j DROP
                ip6tables -A INPUT -p tcp --dport 80 -j DROP
                ip6tables -A INPUT -p tcp --dport 443 -j DROP
                echo "[+] Đã thêm $CUSTOM_IP vào danh sách được phép (cổng 80/443)."
                echo "[+] Tất cả các cổng khác ngoài 80/443 đều được phép truy cập."
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
    echo "[+] Phát hiện các cổng đang mở trên hệ thống..."
    OPEN_PORTS=$(ss -tulnp 2>/dev/null | grep -E 'LISTEN' | awk '{print $5}' | cut -d: -f2 | sort -u || echo "")
    if [ -z "$OPEN_PORTS" ]; then
        echo "[-] Không tìm thấy cổng đang mở hoặc công cụ ss không được cài đặt."
    else
        echo "[+] Các cổng đang mở: $OPEN_PORTS"
    fi
    echo "[!] Cảnh báo: Tất cả các cổng sẽ được mở (bao gồm cổng của aaPanel, 80, 443, v.v.). Hệ thống sẽ không có firewall bảo vệ."
    echo "[+] Gỡ toàn bộ quy tắc firewall..."
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
    echo "[+] Đã gỡ toàn bộ quy tắc firewall. Tất cả các cổng giờ đây được phép."
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
        echo "[+] Phát hiện các cổng đang mở trên hệ thống..."
        OPEN_PORTS=$(ss -tulnp 2>/dev/null | grep -E 'LISTEN' | awk '{print $5}' | cut -d: -f2 | sort -u || echo "")
        if [ -z "$OPEN_PORTS" ]; then
            echo "[-] Không tìm thấy cổng đang mở hoặc công cụ ss không được cài đặt."
        else
            echo "[+] Các cổng đang mở: $OPEN_PORTS"
        fi
        echo "[!] Cảnh báo: Gỡ tất cả firewall sẽ mở toàn bộ cổng (bao gồm cổng của aaPanel, 80, 443, v.v.). Hệ thống có thể không được bảo vệ."
        echo "[+] Bạn có chắc chắn muốn gỡ cài đặt tất cả firewall?"
        echo " 0. Quay lại"
        echo " 1. Tiếp tục gỡ cài đặt"
        read -r confirm_choice
        case $confirm_choice in
            0)
                echo "[+] Quay lại menu chính."
                return 0
                ;;
            1)
                remove_package firewalld firewalld.service
                remove_package ufw ufw.service
                # Kiểm tra và gỡ cả iptables và iptables-persistent
                if command -v iptables >/dev/null 2>&1; then
                    echo "[+] Gói iptables được phát hiện, tiến hành gỡ cài đặt..."
                    case $OS in
                        centos|almalinux|rhel|cloudlinux)
                            yum remove -y iptables iptables-services >/dev/null 2>&1 || dnf remove -y iptables iptables-services >/dev/null 2>&1
                            echo "[+] Đã gỡ iptables" ;;
                        ubuntu|debian)
                            apt-get remove --purge -y iptables iptables-persistent >/dev/null 2>&1
                            dpkg --purge iptables iptables-persistent >/dev/null 2>&1
                            apt-get autoremove -y >/dev/null 2>&1
                            echo "[+] Đã gỡ iptables và iptables-persistent" ;;
                    esac
                else
                    echo "[-] Gói iptables không được cài đặt."
                fi
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
block_cloudflare_ips() {
    if ! check_iptables; then
        return 1
    fi
    echo "[+] Phát hiện các cổng đang mở trên hệ thống..."
    OPEN_PORTS=$(ss -tulnp 2>/dev/null | grep -E 'LISTEN' | awk '{print $5}' | cut -d: -f2 | sort -u || echo "")
    if [ -z "$OPEN_PORTS" ]; then
        echo "[-] Không tìm thấy cổng đang mở hoặc công cụ ss không được cài đặt."
        echo "[+] Nhập các cổng cần cho phép (cách nhau bằng dấu cách, ví dụ: 35053 8080, hoặc nhấn Enter để bỏ qua):"
        read -r CUSTOM_PORTS
    else
        echo "[+] Các cổng đang mở: $OPEN_PORTS"
        echo "[+] Nhập thêm cổng cần cho phép (nếu có, cách nhau bằng dấu cách, hoặc nhấn Enter để bỏ qua):"
        read -r CUSTOM_PORTS
    fi
    echo "[+] Chặn IP Cloudflare bằng iptables (IPv4)..."
    iptables -F
    iptables -P INPUT ACCEPT
    iptables -P FORWARD ACCEPT
    iptables -P OUTPUT ACCEPT
    iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables -A INPUT -p tcp --dport 22 -j ACCEPT
    for port in $OPEN_PORTS; do
        if [[ "$port" != "80" && "$port" != "443" && "$port" != "22" ]]; then
            iptables -A INPUT -p tcp --dport "$port" -j ACCEPT
            echo "[+] Đã cho phép cổng $port (IPv4)."
        fi
    done
    for port in $CUSTOM_PORTS; do
        if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] && [[ "$port" != "80" && "$port" != "443" && "$port" != "22" ]]; then
            iptables -A INPUT -p tcp --dport "$port" -j ACCEPT
            echo "[+] Đã cho phép cổng tùy chỉnh $port (IPv4)."
        fi
    done
    for ip in $CLOUDFLARE_IPS_V4; do
        iptables -A INPUT -s "$ip" -j DROP
    done
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4
    echo "[+] Chặn IP Cloudflare bằng ip6tables (IPv6)..."
    ip6tables -F
    ip6tables -P INPUT ACCEPT
    ip6tables -P FORWARD ACCEPT
    ip6tables -P OUTPUT ACCEPT
    ip6tables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    ip6tables -A INPUT -p tcp --dport 22 -j ACCEPT
    for port in $OPEN_PORTS; do
        if [[ "$port" != "80" && "$port" != "443" && "$port" != "22" ]]; then
            ip6tables -A INPUT -p tcp --dport "$port" -j ACCEPT
            echo "[+] Đã cho phép cổng $port (IPv6)."
        fi
    done
    for port in $CUSTOM_PORTS; do
        if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] && [[ "$port" != "80" && "$port" != "443" && "$port" != "22" ]]; then
            ip6tables -A INPUT -p tcp --dport "$port" -j ACCEPT
            echo "[+] Đã cho phép cổng tùy chỉnh $port (IPv6)."
        fi
    done
    for ip in $CLOUDFLARE_IPS_V6; do
        ip6tables -A INPUT -s "$ip" -j DROP
    done
    ip6tables-save > /etc/iptables/rules.v6
    ensure_conntrack
    echo "[+] Xóa toàn bộ kết nối cũ trên cổng 80/443..."
    conntrack -D -p tcp --dport 80 >/dev/null 2>&1
    conntrack -D -p tcp --dport 443 >/dev/null 2>&1
    echo "[+] Đã chặn toàn bộ IP Cloudflare (IPv4 & IPv6) và xóa kết nối cũ."
    echo "[+] Tất cả các cổng khác ngoài 80/443 đều được phép truy cập."
}
clear_connections_on_port() {
    ensure_conntrack
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
allow_custom_ports() {
    if ! check_iptables; then
        return 1
    fi
    echo "[+] Phát hiện các cổng đang mở trên hệ thống..."
    OPEN_PORTS=$(ss -tulnp 2>/dev/null | grep -E 'LISTEN' | awk '{print $5}' | cut -d: -f2 | sort -u || echo "")
    if [ -z "$OPEN_PORTS" ]; then
        echo "[-] Không tìm thấy cổng đang mở hoặc công cụ ss không được cài đặt."
    else
        echo "[+] Các cổng đang mở: $OPEN_PORTS"
    fi
    echo "[+] Nhập danh sách cổng cần cho phép (cách nhau bằng dấu cách, ví dụ: 35053 8080):"
    read -r CUSTOM_PORTS
    for port in $CUSTOM_PORTS; do
        if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
            iptables -A INPUT -p tcp --dport "$port" -j ACCEPT
            ip6tables -A INPUT -p tcp --dport "$port" -j ACCEPT
            echo "[+] Đã cho phép cổng $port."
        else
            echo "[-] Cổng $port không hợp lệ, bỏ qua."
        fi
    done
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4
    ip6tables-save > /etc/iptables/rules.v6
    echo "[+] Đã lưu quy tắc iptables."
}
# ===== LIỆT KÊ FIREWALL ĐANG CÀI =====
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
# ===== MENU =====
while true; do
    echo "================================="
    echo " MENU QUẢN LÝ FIREWALL "
    echo "================================="
    echo "1. Cho phép IP Cloudflare, chặn 80/443 cho IP khác (xóa kết nối cũ)"
    echo "2. Thêm IP/subnet vào danh sách được phép"
    echo "3. Gỡ toàn bộ quy tắc firewall và mở tất cả cổng"
    echo "4. Cài đặt iptables"
    echo "5. Gỡ cài đặt tất cả firewall"
    echo "6. Chặn toàn bộ IP Cloudflare (xóa kết nối cũ)"
    echo "7. Xóa toàn bộ kết nối hiện tại trên 1 cổng"
    echo "8. Cho phép các cổng tùy chỉnh"
    echo "0. Thoát"
    echo "================================="
    echo -n "Nhập lựa chọn của bạn [0-8]: "
    read choice
    case $choice in
        1) configure_cloudflare_rules; echo "" ;;
        2) add_custom_ip_subnet; echo "" ;;
        3) remove_port_restrictions; echo "" ;;
        4) install_iptables; echo "" ;;
        5) remove_all_firewalls; echo "" ;;
        6) block_cloudflare_ips; echo "" ;;
        7) clear_connections_on_port; echo "" ;;
        8) allow_custom_ports; echo "" ;;
        0) echo "[+] Thoát chương trình."; exit 0 ;;
        *) echo "[-] Lựa chọn không hợp lệ! Vui lòng chọn lại."; echo "" ;;
    esac
done
