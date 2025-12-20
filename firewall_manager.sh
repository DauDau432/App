#!/bin/bash

# ============================================================
# FIREWALL MANAGER - Công cụ quản lý Firewall đa năng
# Hỗ trợ: Ubuntu, Debian, CentOS, RHEL, AlmaLinux, Rocky Linux,
#         CloudLinux, Fedora, Oracle Linux
# ============================================================

SCRIPT_VERSION="2.0.0"

# ===== MÀUSẮC =====
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ===== CLOUDFLARE IPS =====
CLOUDFLARE_IPS_V4="173.245.48.0/20
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
198.41.128.0/17"

CLOUDFLARE_IPS_V6="2400:cb00::/32
2606:4700::/32
2803:f800::/32
2405:b500::/32
2405:8100::/32
2a06:98c0::/29
2c0f:f248::/32"

# ===== HÀM HIỂN THỊ =====
print_info() {
    echo -e "${GREEN}[+]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[!]${NC} $1"
}

print_error() {
    echo -e "${RED}[-]${NC} $1"
}

print_header() {
    echo -e "${CYAN}$1${NC}"
}

# ===== KIỂM TRA QUYỀN ROOT =====
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        print_error "Script này cần được chạy với quyền root (sudo)."
        exit 1
    fi
}

# ===== PHÁT HIỆN HỆ ĐIỀU HÀNH =====
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        OS_VERSION=$VERSION_ID
        OS_NAME=$PRETTY_NAME
    elif [ -f /etc/redhat-release ]; then
        OS="rhel"
        OS_NAME=$(cat /etc/redhat-release)
    elif [ -f /etc/debian_version ]; then
        OS="debian"
        OS_NAME="Debian $(cat /etc/debian_version)"
    else
        print_error "Không xác định được hệ điều hành!"
        exit 1
    fi
    
    # Chuẩn hóa tên OS
    case $OS in
        centos|rhel|almalinux|rocky|cloudlinux|ol|oracle|fedora)
            OS_FAMILY="rhel"
            ;;
        ubuntu|debian|linuxmint|pop|elementary|zorin|kali)
            OS_FAMILY="debian"
            ;;
        opensuse*|sles)
            OS_FAMILY="suse"
            ;;
        arch|manjaro|endeavouros)
            OS_FAMILY="arch"
            ;;
        *)
            OS_FAMILY="unknown"
            ;;
    esac
}

# ===== KIỂM TRA GÓI ĐÃ CÀI ĐẶT =====
check_package() {
    local pkg=$1
    
    case $OS_FAMILY in
        rhel)
            # Sử dụng rpm -q cho RHEL-based distros
            rpm -q "$pkg" >/dev/null 2>&1 && return 0
            # Thử với command nếu rpm không tìm thấy
            command -v "$pkg" >/dev/null 2>&1 && return 0
            return 1
            ;;
        debian)
            # Sử dụng dpkg-query thay vì dpkg -l (chính xác hơn)
            dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed" && return 0
            # Kiểm tra thêm các gói liên quan
            case $pkg in
                iptables)
                    dpkg-query -W -f='${Status}' "iptables-persistent" 2>/dev/null | grep -q "install ok installed" && return 0
                    command -v iptables >/dev/null 2>&1 && return 0
                    ;;
            esac
            return 1
            ;;
        suse)
            rpm -q "$pkg" >/dev/null 2>&1 && return 0 || return 1
            ;;
        arch)
            pacman -Q "$pkg" >/dev/null 2>&1 && return 0 || return 1
            ;;
        *)
            # Fallback: kiểm tra command
            command -v "$pkg" >/dev/null 2>&1 && return 0 || return 1
            ;;
    esac
}

# ===== KIỂM TRA COMMAND TỒN TẠI =====
check_command() {
    command -v "$1" >/dev/null 2>&1
}

# ===== CÀI ĐẶT GÓI =====
install_package() {
    local pkg=$1
    print_info "Đang cài đặt $pkg..."
    
    case $OS_FAMILY in
        rhel)
            if check_command dnf; then
                dnf install -y "$pkg" >/dev/null 2>&1
            else
                yum install -y "$pkg" >/dev/null 2>&1
            fi
            ;;
        debian)
            apt-get update >/dev/null 2>&1
            DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" >/dev/null 2>&1
            ;;
        suse)
            zypper install -y "$pkg" >/dev/null 2>&1
            ;;
        arch)
            pacman -S --noconfirm "$pkg" >/dev/null 2>&1
            ;;
        *)
            print_error "Không hỗ trợ cài đặt tự động cho hệ điều hành này."
            return 1
            ;;
    esac
    
    if check_package "$pkg" || check_command "$pkg"; then
        print_info "$pkg đã được cài đặt thành công."
        return 0
    else
        print_error "Không thể cài đặt $pkg."
        return 1
    fi
}

# ===== GỠ CÀI ĐẶT GÓI =====
remove_package() {
    local pkg=$1
    local service_name=${2:-$pkg}
    
    # Kiểm tra gói hoặc command tồn tại
    if ! check_package "$pkg" && ! check_command "$pkg"; then
        print_error "Gói $pkg không được cài đặt."
        return 1
    fi
    
    print_info "Đang gỡ cài đặt $pkg..."
    
    # Dừng service nếu đang chạy
    if systemctl is-active --quiet "$service_name" 2>/dev/null; then
        systemctl stop "$service_name" 2>/dev/null
        systemctl disable "$service_name" 2>/dev/null
        print_info "Đã dừng $service_name"
    fi
    
    case $OS_FAMILY in
        rhel)
            if check_command dnf; then
                dnf remove -y "$pkg" >/dev/null 2>&1
            else
                yum remove -y "$pkg" >/dev/null 2>&1
            fi
            ;;
        debian)
            apt-get remove --purge -y "$pkg" >/dev/null 2>&1
            apt-get autoremove -y >/dev/null 2>&1
            ;;
        suse)
            zypper remove -y "$pkg" >/dev/null 2>&1
            ;;
        arch)
            pacman -Rns --noconfirm "$pkg" >/dev/null 2>&1
            ;;
    esac
    
    print_info "Đã gỡ cài đặt $pkg."
}

# ===== KIỂM TRA IPTABLES =====
check_iptables() {
    if check_command iptables; then
        IPTABLES_VERSION=$(iptables --version 2>/dev/null | head -n1)
        return 0
    else
        print_error "iptables chưa được cài đặt."
        return 1
    fi
}

# ===== ĐẢM BẢO CONNTRACK =====
ensure_conntrack() {
    if ! check_command conntrack; then
        print_info "Đang cài đặt conntrack..."
        case $OS_FAMILY in
            rhel)
                install_package conntrack-tools
                ;;
            debian)
                install_package conntrack
                ;;
            *)
                install_package conntrack
                ;;
        esac
    fi
}

# ===== LẤY DANH SÁCH CỔNG ĐANG MỞ =====
get_open_ports() {
    local ports=""
    if check_command ss; then
        ports=$(ss -tulnp 2>/dev/null | grep -E 'LISTEN' | awk '{print $5}' | grep -oE '[0-9]+$' | sort -nu | tr '\n' ' ')
    elif check_command netstat; then
        ports=$(netstat -tulnp 2>/dev/null | grep -E 'LISTEN' | awk '{print $4}' | grep -oE '[0-9]+$' | sort -nu | tr '\n' ' ')
    fi
    echo "$ports"
}

# ===== LƯU RULES IPTABLES =====
save_iptables_rules() {
    mkdir -p /etc/iptables
    
    if check_command iptables-save; then
        iptables-save > /etc/iptables/rules.v4 2>/dev/null
    fi
    
    if check_command ip6tables-save; then
        ip6tables-save > /etc/iptables/rules.v6 2>/dev/null
    fi
    
    # Cho Debian/Ubuntu với iptables-persistent
    if [ "$OS_FAMILY" = "debian" ]; then
        if [ -d /etc/iptables ]; then
            iptables-save > /etc/iptables/rules.v4 2>/dev/null
            ip6tables-save > /etc/iptables/rules.v6 2>/dev/null
        fi
    fi
    
    # Cho RHEL-based với iptables-services
    if [ "$OS_FAMILY" = "rhel" ]; then
        if [ -f /etc/sysconfig/iptables ]; then
            iptables-save > /etc/sysconfig/iptables 2>/dev/null
        fi
        if [ -f /etc/sysconfig/ip6tables ]; then
            ip6tables-save > /etc/sysconfig/ip6tables 2>/dev/null
        fi
    fi
}

# ===== DANH SÁCH FIREWALL VÀ SERVICE =====
declare -A FIREWALL_SERVICES=(
    ["firewalld"]="firewalld.service"
    ["ufw"]="ufw.service"
    ["iptables"]="iptables.service"
    ["ip6tables"]="ip6tables.service"
    ["nftables"]="nftables.service"
    ["csf"]="csf.service"
    ["lfd"]="lfd.service"
    ["fail2ban"]="fail2ban.service"
    ["netfilter-persistent"]="netfilter-persistent.service"
)

declare -A FIREWALL_COMMANDS=(
    ["firewalld"]="firewall-cmd"
    ["ufw"]="ufw"
    ["iptables"]="iptables"
    ["ip6tables"]="ip6tables"
    ["nftables"]="nft"
    ["csf"]="csf"
    ["fail2ban"]="fail2ban-client"
)

# ===== LIỆT KÊ FIREWALL ĐANG CÀI =====
list_installed_firewalls() {
    print_header "╔════════════════════════════════════════════════════════════════╗"
    print_header "║                 FIREWALL ĐANG CÀI ĐẶT TRÊN HỆ THỐNG            ║"
    print_header "╠════════════════════════════════════════════════════════════════╣"
    
    local found=false
    INSTALLED_FIREWALLS=()
    
    # Định dạng cột
    printf "║ %-18s %-12s %-10s %-20s ║\n" "TÊN" "TRẠNG THÁI" "TỰ ĐỘNG" "PHIÊN BẢN"
    print_header "╠────────────────────────────────────────────────────────────────╣"
    
    for pkg in firewalld ufw iptables nftables csf fail2ban; do
        local cmd="${FIREWALL_COMMANDS[$pkg]}"
        local service="${FIREWALL_SERVICES[$pkg]}"
        
        if check_command "$cmd"; then
            found=true
            INSTALLED_FIREWALLS+=("$pkg")
            
            # Lấy version
            local version=""
            case $pkg in
                iptables)
                    version=$(iptables --version 2>/dev/null | grep -oE 'v[0-9.]+' | head -1)
                    ;;
                nftables)
                    version=$(nft --version 2>/dev/null | grep -oE 'v[0-9.]+' | head -1)
                    ;;
                firewalld)
                    version=$(firewall-cmd --version 2>/dev/null)
                    ;;
                ufw)
                    version=$(ufw version 2>/dev/null | grep -oE '[0-9.]+' | head -1)
                    ;;
                csf)
                    version=$(csf -v 2>/dev/null | grep -oE '[0-9.]+' | head -1)
                    ;;
                fail2ban)
                    version=$(fail2ban-client --version 2>/dev/null | grep -oE 'v[0-9.]+' | head -1)
                    ;;
            esac
            [ -z "$version" ] && version="N/A"
            
            # Kiểm tra trạng thái service
            local status="Không rõ"
            local autostart="Không rõ"
            
            if systemctl list-unit-files "$service" >/dev/null 2>&1; then
                if systemctl is-active --quiet "$service" 2>/dev/null; then
                    status="${GREEN}Đang chạy${NC}"
                else
                    status="${RED}Đã dừng${NC}"
                fi
                
                if systemctl is-enabled --quiet "$service" 2>/dev/null; then
                    autostart="${GREEN}Bật${NC}"
                else
                    autostart="${YELLOW}Tắt${NC}"
                fi
            else
                # Kiểm tra đặc biệt cho iptables (có thể không có service)
                if [ "$pkg" = "iptables" ]; then
                    local rule_count=$(iptables -L -n 2>/dev/null | wc -l)
                    if [ "$rule_count" -gt 8 ]; then
                        status="${GREEN}Có rules${NC}"
                    else
                        status="${YELLOW}Trống${NC}"
                    fi
                    autostart="${YELLOW}Thủ công${NC}"
                fi
            fi
            
            printf "║ %-18s ${status}%-1s %-1s${autostart}%-1s %-20s ║\n" "$pkg" "" "" "" "$version"
        fi
    done
    
    if ! $found; then
        printf "║ %-62s ║\n" "Không tìm thấy firewall nào được cài đặt."
    fi
    
    print_header "╚════════════════════════════════════════════════════════════════╝"
    echo ""
}

# ===== CẤU HÌNH CLOUDFLARE RULES =====
configure_cloudflare_rules() {
    if ! check_iptables; then
        return 1
    fi
    
    print_info "Cấu hình cho phép IP Cloudflare..."
    
    # Lấy danh sách cổng đang mở
    OPEN_PORTS=$(get_open_ports)
    print_info "Các cổng đang mở: ${OPEN_PORTS:-Không có}"
    
    echo -n "Nhập thêm cổng cần cho phép (cách nhau bằng dấu cách, Enter để bỏ qua): "
    read -r CUSTOM_PORTS
    
    # Reset IPv4 rules
    iptables -F
    iptables -P INPUT ACCEPT
    iptables -P FORWARD ACCEPT
    iptables -P OUTPUT ACCEPT
    
    # Rules cơ bản
    iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables -A INPUT -i lo -j ACCEPT
    iptables -A INPUT -p tcp --dport 22 -j ACCEPT
    
    # Cho phép các cổng đang mở (trừ 80/443)
    for port in $OPEN_PORTS $CUSTOM_PORTS; do
        if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
            if [[ "$port" != "80" && "$port" != "443" && "$port" != "22" ]]; then
                iptables -A INPUT -p tcp --dport "$port" -j ACCEPT
                print_info "Đã cho phép cổng $port (IPv4)"
            fi
        fi
    done
    
    # Cho phép Cloudflare IPs
    for ip in $CLOUDFLARE_IPS_V4; do
        iptables -A INPUT -p tcp -s "$ip" --dport 80 -j ACCEPT
        iptables -A INPUT -p tcp -s "$ip" --dport 443 -j ACCEPT
    done
    
    # Chặn 80/443 từ các IP khác
    iptables -A INPUT -p tcp --dport 80 -j DROP
    iptables -A INPUT -p tcp --dport 443 -j DROP
    
    # Tương tự cho IPv6
    if check_command ip6tables; then
        ip6tables -F
        ip6tables -P INPUT ACCEPT
        ip6tables -P FORWARD ACCEPT
        ip6tables -P OUTPUT ACCEPT
        
        ip6tables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
        ip6tables -A INPUT -i lo -j ACCEPT
        ip6tables -A INPUT -p tcp --dport 22 -j ACCEPT
        
        for port in $OPEN_PORTS $CUSTOM_PORTS; do
            if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
                if [[ "$port" != "80" && "$port" != "443" && "$port" != "22" ]]; then
                    ip6tables -A INPUT -p tcp --dport "$port" -j ACCEPT
                fi
            fi
        done
        
        for ip in $CLOUDFLARE_IPS_V6; do
            ip6tables -A INPUT -p tcp -s "$ip" --dport 80 -j ACCEPT
            ip6tables -A INPUT -p tcp -s "$ip" --dport 443 -j ACCEPT
        done
        
        ip6tables -A INPUT -p tcp --dport 80 -j DROP
        ip6tables -A INPUT -p tcp --dport 443 -j DROP
    fi
    
    save_iptables_rules
    
    # Xóa kết nối cũ
    ensure_conntrack
    conntrack -D -p tcp --dport 80 >/dev/null 2>&1
    conntrack -D -p tcp --dport 443 >/dev/null 2>&1
    
    print_info "Đã cấu hình cho phép IP Cloudflare."
}

# ===== THÊM IP/SUBNET TÙY CHỈNH =====
add_custom_ip_subnet() {
    if ! check_iptables; then
        return 1
    fi
    
    while true; do
        echo -n "Nhập IP hoặc subnet (ví dụ: 192.168.1.1 hoặc 192.168.1.0/24): "
        read -r CUSTOM_IP
        
        if [ -z "$CUSTOM_IP" ]; then
            print_error "Vui lòng nhập IP/subnet."
            continue
        fi
        
        echo ""
        echo "Chọn kiểu rule:"
        echo "  1. Cho phép tất cả kết nối từ/đến IP này"
        echo "  2. Chỉ cho phép truy cập cổng 80/443"
        echo "  0. Quay lại"
        echo -n "Lựa chọn [0-2]: "
        read -r rule_choice
        
        case $rule_choice in
            0)
                return 0
                ;;
            1)
                if [[ "$CUSTOM_IP" =~ : ]]; then
                    ip6tables -I INPUT -s "$CUSTOM_IP" -j ACCEPT
                    ip6tables -I OUTPUT -d "$CUSTOM_IP" -j ACCEPT
                else
                    iptables -I INPUT -s "$CUSTOM_IP" -j ACCEPT
                    iptables -I OUTPUT -d "$CUSTOM_IP" -j ACCEPT
                fi
                print_info "Đã thêm rule cho $CUSTOM_IP (tất cả kết nối)."
                ;;
            2)
                if [[ "$CUSTOM_IP" =~ : ]]; then
                    ip6tables -I INPUT -p tcp -s "$CUSTOM_IP" --dport 80 -j ACCEPT
                    ip6tables -I INPUT -p tcp -s "$CUSTOM_IP" --dport 443 -j ACCEPT
                else
                    iptables -I INPUT -p tcp -s "$CUSTOM_IP" --dport 80 -j ACCEPT
                    iptables -I INPUT -p tcp -s "$CUSTOM_IP" --dport 443 -j ACCEPT
                fi
                print_info "Đã thêm rule cho $CUSTOM_IP (cổng 80/443)."
                ;;
            *)
                print_error "Lựa chọn không hợp lệ!"
                continue
                ;;
        esac
        
        save_iptables_rules
        return 0
    done
}

# ===== CHẶN IP CLOUDFLARE =====
block_cloudflare_ips() {
    if ! check_iptables; then
        return 1
    fi
    
    print_info "Chặn tất cả IP Cloudflare..."
    
    OPEN_PORTS=$(get_open_ports)
    print_info "Các cổng đang mở: ${OPEN_PORTS:-Không có}"
    
    echo -n "Nhập thêm cổng cần cho phép (cách nhau bằng dấu cách, Enter để bỏ qua): "
    read -r CUSTOM_PORTS
    
    # Reset và cấu hình IPv4
    iptables -F
    iptables -P INPUT ACCEPT
    iptables -P FORWARD ACCEPT
    iptables -P OUTPUT ACCEPT
    
    iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables -A INPUT -i lo -j ACCEPT
    iptables -A INPUT -p tcp --dport 22 -j ACCEPT
    
    for port in $OPEN_PORTS $CUSTOM_PORTS; do
        if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
            if [[ "$port" != "22" ]]; then
                iptables -A INPUT -p tcp --dport "$port" -j ACCEPT
            fi
        fi
    done
    
    for ip in $CLOUDFLARE_IPS_V4; do
        iptables -A INPUT -s "$ip" -j DROP
    done
    
    # IPv6
    if check_command ip6tables; then
        ip6tables -F
        ip6tables -P INPUT ACCEPT
        ip6tables -P FORWARD ACCEPT
        ip6tables -P OUTPUT ACCEPT
        
        ip6tables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
        ip6tables -A INPUT -i lo -j ACCEPT
        ip6tables -A INPUT -p tcp --dport 22 -j ACCEPT
        
        for port in $OPEN_PORTS $CUSTOM_PORTS; do
            if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
                if [[ "$port" != "22" ]]; then
                    ip6tables -A INPUT -p tcp --dport "$port" -j ACCEPT
                fi
            fi
        done
        
        for ip in $CLOUDFLARE_IPS_V6; do
            ip6tables -A INPUT -s "$ip" -j DROP
        done
    fi
    
    save_iptables_rules
    
    ensure_conntrack
    conntrack -D -p tcp --dport 80 >/dev/null 2>&1
    conntrack -D -p tcp --dport 443 >/dev/null 2>&1
    
    print_info "Đã chặn tất cả IP Cloudflare."
}

# ===== GỠ BỎ TẤT CẢ RULES =====
remove_all_rules() {
    if ! check_iptables; then
        return 1
    fi
    
    print_warn "Cảnh báo: Tất cả các cổng sẽ được mở!"
    echo -n "Bạn có chắc chắn? (y/N): "
    read -r confirm
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_info "Đã hủy."
        return 0
    fi
    
    print_info "Đang gỡ toàn bộ rules..."
    
    iptables -F
    iptables -X
    iptables -P INPUT ACCEPT
    iptables -P FORWARD ACCEPT
    iptables -P OUTPUT ACCEPT
    
    if check_command ip6tables; then
        ip6tables -F
        ip6tables -X
        ip6tables -P INPUT ACCEPT
        ip6tables -P FORWARD ACCEPT
        ip6tables -P OUTPUT ACCEPT
    fi
    
    save_iptables_rules
    
    print_info "Đã gỡ toàn bộ rules. Tất cả cổng đã mở."
}

# ===== CÀI ĐẶT IPTABLES =====
install_iptables_pkg() {
    print_info "Đang cài đặt iptables..."
    
    case $OS_FAMILY in
        rhel)
            install_package iptables
            install_package iptables-services
            systemctl enable iptables 2>/dev/null
            systemctl start iptables 2>/dev/null
            ;;
        debian)
            install_package iptables
            install_package iptables-persistent
            ;;
        *)
            install_package iptables
            ;;
    esac
    
    if check_command iptables; then
        print_info "iptables: $(iptables --version 2>/dev/null | head -n1)"
    fi
}

# ===== TẮT TẤT CẢ FIREWALL (GIỮ LẠI ĐỂ BẬT LẠI) =====
stop_disable_all_firewalls() {
    echo ""
    print_warn "Tắt tất cả firewall và vô hiệu hóa khởi động tự động."
    print_info "Các firewall sẽ KHÔNG bị gỡ cài đặt, có thể bật lại sau."
    echo ""
    echo -n "Bạn có chắc chắn? (y/N): "
    read -r confirm
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_info "Đã hủy."
        return 0
    fi
    
    local stopped_count=0
    local disabled_count=0
    
    echo ""
    for pkg in firewalld ufw iptables ip6tables nftables csf lfd fail2ban netfilter-persistent; do
        local service="${FIREWALL_SERVICES[$pkg]}"
        
        # Kiểm tra service có tồn tại không
        if systemctl list-unit-files "$service" >/dev/null 2>&1; then
            # Dừng service nếu đang chạy
            if systemctl is-active --quiet "$service" 2>/dev/null; then
                systemctl stop "$service" 2>/dev/null
                print_info "Đã dừng: $pkg ($service)"
                ((stopped_count++))
            fi
            
            # Disable autostart (không mask để có thể bật lại dễ dàng)
            if systemctl is-enabled --quiet "$service" 2>/dev/null; then
                systemctl disable "$service" 2>/dev/null
                print_info "Đã tắt tự khởi động: $pkg"
                ((disabled_count++))
            fi
        fi
    done
    
    # Xóa tất cả rules iptables (nhưng giữ lại package)
    if check_command iptables; then
        print_info "Xóa tất cả rules iptables (giữ lại phần mềm)..."
        iptables -F
        iptables -X
        iptables -t nat -F 2>/dev/null
        iptables -t nat -X 2>/dev/null
        iptables -t mangle -F 2>/dev/null
        iptables -t mangle -X 2>/dev/null
        iptables -P INPUT ACCEPT
        iptables -P FORWARD ACCEPT
        iptables -P OUTPUT ACCEPT
    fi
    
    if check_command ip6tables; then
        ip6tables -F
        ip6tables -X
        ip6tables -t nat -F 2>/dev/null
        ip6tables -t nat -X 2>/dev/null
        ip6tables -t mangle -F 2>/dev/null
        ip6tables -t mangle -X 2>/dev/null
        ip6tables -P INPUT ACCEPT
        ip6tables -P FORWARD ACCEPT
        ip6tables -P OUTPUT ACCEPT
    fi
    
    # Xóa rules nftables
    if check_command nft; then
        nft flush ruleset 2>/dev/null
        print_info "Đã xóa ruleset nftables"
    fi
    
    # Backup file rules cũ và tạo file rules trống
    if [ -f /etc/iptables/rules.v4 ]; then
        cp /etc/iptables/rules.v4 /etc/iptables/rules.v4.backup.$(date +%Y%m%d%H%M%S) 2>/dev/null
    fi
    if [ -f /etc/iptables/rules.v6 ]; then
        cp /etc/iptables/rules.v6 /etc/iptables/rules.v6.backup.$(date +%Y%m%d%H%M%S) 2>/dev/null
    fi
    
    # Tạo file rules trống (ACCEPT all)
    mkdir -p /etc/iptables 2>/dev/null
    cat > /etc/iptables/rules.v4 << 'EOF'
*filter
:INPUT ACCEPT [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
COMMIT
EOF
    cp /etc/iptables/rules.v4 /etc/iptables/rules.v6 2>/dev/null
    
    echo ""
    print_info "Kết quả:"
    print_info "  - Đã dừng: $stopped_count service"
    print_info "  - Đã tắt tự khởi động: $disabled_count service"
    print_info "  - File rules cũ đã được backup"
    echo ""
    print_warn "VPS sẽ không có firewall bảo vệ!"
    print_info "Sử dụng menu '2. Bật lại firewall đã tắt' để kích hoạt lại."
}

# ===== BẬT LẠI FIREWALL ĐÃ TẮT =====
enable_firewall_autostart() {
    echo ""
    print_header "Chọn firewall để BẬT LẠI:"
    print_info "Chỉ hiển thị các firewall đang được cài đặt."
    echo ""
    
    local idx=1
    local available_services=()
    
    for pkg in firewalld ufw iptables nftables csf fail2ban; do
        local cmd="${FIREWALL_COMMANDS[$pkg]}"
        local service="${FIREWALL_SERVICES[$pkg]}"
        
        if check_command "$cmd"; then
            # Kiểm tra trạng thái hiện tại
            local status_text=""
            if systemctl is-active --quiet "$service" 2>/dev/null; then
                status_text="${GREEN}[Đang chạy]${NC}"
            else
                status_text="${RED}[Đã dừng]${NC}"
            fi
            
            local auto_text=""
            if systemctl is-enabled --quiet "$service" 2>/dev/null; then
                auto_text="${GREEN}[Tự động: Bật]${NC}"
            else
                auto_text="${YELLOW}[Tự động: Tắt]${NC}"
            fi
            
            echo -e "  $idx. $pkg $status_text $auto_text"
            available_services+=("$service:$pkg")
            ((idx++))
        fi
    done
    
    if [ ${#available_services[@]} -eq 0 ]; then
        print_error "Không có firewall nào được cài đặt!"
        return 0
    fi
    
    echo ""
    echo "  A. Bật TẤT CẢ firewall"
    echo "  0. Quay lại"
    echo ""
    echo -n "Lựa chọn: "
    read -r choice
    
    if [ "$choice" = "0" ] || [ -z "$choice" ]; then
        return 0
    fi
    
    if [ "$choice" = "A" ] || [ "$choice" = "a" ]; then
        print_info "Bật tất cả firewall..."
        for item in "${available_services[@]}"; do
            local service="${item%%:*}"
            local pkg="${item##*:}"
            
            systemctl unmask "$service" 2>/dev/null
            systemctl enable "$service" 2>/dev/null
            systemctl start "$service" 2>/dev/null
            
            if systemctl is-active --quiet "$service" 2>/dev/null; then
                print_info "$pkg: Đã bật và đang chạy"
            else
                print_warn "$pkg: Đã bật nhưng không thể khởi động"
            fi
        done
        return 0
    fi
    
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -lt "$idx" ]; then
        local selected="${available_services[$((choice-1))]}"
        local service="${selected%%:*}"
        local pkg="${selected##*:}"
        
        print_info "Đang bật $pkg..."
        
        # Unmask nếu bị mask
        systemctl unmask "$service" 2>/dev/null
        
        # Enable và start
        systemctl enable "$service" 2>/dev/null
        systemctl start "$service" 2>/dev/null
        
        # Kiểm tra kết quả
        if systemctl is-active --quiet "$service" 2>/dev/null; then
            print_info "$pkg đã được bật và đang chạy!"
        else
            print_warn "$pkg đã được enable nhưng không thể khởi động."
            print_info "Kiểm tra lỗi: systemctl status $service"
        fi
        
        # Với iptables, cần restore rules
        if [ "$pkg" = "iptables" ]; then
            if [ -f /etc/iptables/rules.v4.backup.* ] 2>/dev/null; then
                local latest_backup=$(ls -t /etc/iptables/rules.v4.backup.* 2>/dev/null | head -1)
                if [ -n "$latest_backup" ]; then
                    echo -n "Tìm thấy backup rules. Khôi phục? (y/N): "
                    read -r restore
                    if [[ "$restore" =~ ^[Yy]$ ]]; then
                        iptables-restore < "$latest_backup" 2>/dev/null
                        print_info "Đã khôi phục rules từ backup."
                    fi
                fi
            fi
        fi
    else
        print_error "Lựa chọn không hợp lệ!"
    fi
}

# ===== GỠ FIREWALL ĐƯỢC CHỌN =====
remove_selected_firewalls() {
    echo ""
    print_header "Chọn firewall để GỠ CÀI ĐẶT:"
    print_warn "Lưu ý: Chỉ hiển thị các firewall đang được cài đặt!"
    echo ""
    
    local idx=1
    local available_firewalls=()
    
    # Liệt kê các firewall đang cài
    for pkg in firewalld ufw iptables nftables csf fail2ban; do
        local cmd="${FIREWALL_COMMANDS[$pkg]}"
        if check_command "$cmd"; then
            echo -e "  ${GREEN}$idx.${NC} $pkg"
            available_firewalls+=("$pkg")
            ((idx++))
        fi
    done
    
    if [ ${#available_firewalls[@]} -eq 0 ]; then
        print_error "Không có firewall nào được cài đặt!"
        return 0
    fi
    
    echo -e "  ${RED}A.${NC} Gỡ TẤT CẢ firewall đang cài"
    echo "  0. Quay lại"
    echo ""
    echo -n "Nhập lựa chọn: "
    read -r choice
    
    if [ "$choice" = "0" ] || [ -z "$choice" ]; then
        return 0
    fi
    
    if [ "$choice" = "A" ] || [ "$choice" = "a" ]; then
        print_warn "Bạn sắp gỡ TẤT CẢ firewall!"
        echo -n "Nhập 'yes' để xác nhận: "
        read -r confirm
        if [ "$confirm" != "yes" ]; then
            print_info "Đã hủy."
            return 0
        fi
        
        for pkg in "${available_firewalls[@]}"; do
            remove_single_firewall "$pkg"
        done
        print_info "Đã gỡ tất cả firewall!"
        return 0
    fi
    
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -lt "$idx" ]; then
        local selected="${available_firewalls[$((choice-1))]}"
        print_warn "Bạn sắp gỡ: $selected"
        echo -n "Xác nhận? (y/N): "
        read -r confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            remove_single_firewall "$selected"
        else
            print_info "Đã hủy."
        fi
    else
        print_error "Lựa chọn không hợp lệ!"
    fi
}

# ===== GỠ MỘT FIREWALL CỤ THỂ =====
remove_single_firewall() {
    local pkg=$1
    local service="${FIREWALL_SERVICES[$pkg]}"
    
    print_info "Đang gỡ $pkg..."
    
    # Dừng service
    systemctl stop "$service" 2>/dev/null
    systemctl disable "$service" 2>/dev/null
    
    case $pkg in
        firewalld)
            case $OS_FAMILY in
                rhel) 
                    if check_command dnf; then
                        dnf remove -y firewalld >/dev/null 2>&1
                    else
                        yum remove -y firewalld >/dev/null 2>&1
                    fi
                    ;;
                debian) apt-get remove --purge -y firewalld >/dev/null 2>&1 ;;
            esac
            ;;
        ufw)
            apt-get remove --purge -y ufw >/dev/null 2>&1
            ;;
        iptables)
            case $OS_FAMILY in
                rhel)
                    if check_command dnf; then
                        dnf remove -y iptables-services >/dev/null 2>&1
                    else
                        yum remove -y iptables-services >/dev/null 2>&1
                    fi
                    ;;
                debian)
                    apt-get remove --purge -y iptables-persistent netfilter-persistent >/dev/null 2>&1
                    ;;
            esac
            # Xóa rules
            if check_command iptables; then
                iptables -F && iptables -X
                iptables -P INPUT ACCEPT
                iptables -P FORWARD ACCEPT
                iptables -P OUTPUT ACCEPT
            fi
            if check_command ip6tables; then
                ip6tables -F && ip6tables -X
                ip6tables -P INPUT ACCEPT
                ip6tables -P FORWARD ACCEPT
                ip6tables -P OUTPUT ACCEPT
            fi
            rm -f /etc/iptables/rules.v4 /etc/iptables/rules.v6 2>/dev/null
            rm -f /etc/sysconfig/iptables /etc/sysconfig/ip6tables 2>/dev/null
            ;;
        nftables)
            nft flush ruleset 2>/dev/null
            case $OS_FAMILY in
                rhel)
                    if check_command dnf; then
                        dnf remove -y nftables >/dev/null 2>&1
                    else
                        yum remove -y nftables >/dev/null 2>&1
                    fi
                    ;;
                debian) apt-get remove --purge -y nftables >/dev/null 2>&1 ;;
            esac
            ;;
        csf)
            if [ -x /usr/sbin/csf ]; then
                /usr/sbin/csf -x 2>/dev/null
                if [ -f /etc/csf/uninstall.sh ]; then
                    sh /etc/csf/uninstall.sh 2>/dev/null
                fi
            fi
            ;;
        fail2ban)
            case $OS_FAMILY in
                rhel)
                    if check_command dnf; then
                        dnf remove -y fail2ban >/dev/null 2>&1
                    else
                        yum remove -y fail2ban >/dev/null 2>&1
                    fi
                    ;;
                debian) apt-get remove --purge -y fail2ban >/dev/null 2>&1 ;;
            esac
            ;;
    esac
    
    # Cleanup
    case $OS_FAMILY in
        debian) apt-get autoremove -y >/dev/null 2>&1 ;;
    esac
    
    print_info "Đã gỡ $pkg thành công!"
}

# ===== MENU QUẢN LÝ FIREWALL =====
firewall_management_menu() {
    while true; do
        echo ""
        # Hiển thị thông tin OS
        print_header "╔════════════════════════════════════════════╗"
        local os_display=$(echo "$OS_NAME" | head -c 40)
        printf "║  ${GREEN}OS:${NC} %-39s ║\n" "$os_display"
        print_header "╚════════════════════════════════════════════╝"
        
        list_installed_firewalls
        
        print_header "╔════════════════════════════════════════════╗"
        print_header "║         QUẢN LÝ FIREWALL HỆ THỐNG          ║"
        print_header "╠════════════════════════════════════════════╣"
        echo -e "║  ${YELLOW}1.${NC} Tắt tất cả firewall (giữ lại để bật)  ║"
        echo -e "║  ${GREEN}2.${NC} Bật lại firewall đã tắt               ║"
        echo -e "║  ${RED}3.${NC} Gỡ cài đặt firewall (chọn cụ thể)     ║"
        echo -e "║  ${GREEN}4.${NC} Cài đặt iptables                      ║"
        print_header "╠────────────────────────────────────────────╣"
        echo -e "║  ${BLUE}0.${NC} Quay lại menu chính                   ║"
        print_header "╚════════════════════════════════════════════╝"
        echo ""
        echo -n "Nhập lựa chọn [0-4]: "
        read -r choice
        echo ""
        
        case $choice in
            1) stop_disable_all_firewalls ;;
            2) enable_firewall_autostart ;;
            3) remove_selected_firewalls ;;
            4) install_iptables_pkg ;;
            0) return 0 ;;
            *)
                print_error "Lựa chọn không hợp lệ!"
                ;;
        esac
    done
}

# ===== HIỂN THỊ CỔNG ĐANG MỞ VÀ SỐ KẾT NỐI =====
show_ports_and_connections() {
    echo ""
    print_header "╔════════════════════════════════════════════════════════════════╗"
    print_header "║              CỔNG ĐANG LẮNG NGHE VÀ SỐ KẾT NỐI                 ║"
    print_header "╠════════════════════════════════════════════════════════════════╣"
    
    # Lấy danh sách cổng đang lắng nghe
    if check_command ss; then
        printf "║ %-8s %-15s %-12s %-25s ║\n" "CỔNG" "PROTOCOL" "KẾT NỐI" "PROCESS"
        print_header "╠────────────────────────────────────────────────────────────────╣"
        
        # Lấy các cổng TCP đang lắng nghe
        while read -r line; do
            local port=$(echo "$line" | awk '{print $5}' | grep -oE '[0-9]+$')
            local proto="TCP"
            local process=$(echo "$line" | awk -F'"' '{print $2}' | head -c 20)
            
            if [ -n "$port" ]; then
                # Đếm số kết nối ESTABLISHED trên cổng này
                local conn_count=$(ss -tn state established 2>/dev/null | grep -c ":$port " || echo "0")
                printf "║ %-8s %-15s %-12s %-25s ║\n" "$port" "$proto" "$conn_count" "${process:-N/A}"
            fi
        done < <(ss -tlnp 2>/dev/null | grep -E 'LISTEN' | sort -t: -k2 -n | uniq)
        
        # Lấy các cổng UDP
        while read -r line; do
            local port=$(echo "$line" | awk '{print $5}' | grep -oE '[0-9]+$')
            local proto="UDP"
            local process=$(echo "$line" | awk -F'"' '{print $2}' | head -c 20)
            
            if [ -n "$port" ]; then
                printf "║ %-8s %-15s %-12s %-25s ║\n" "$port" "$proto" "-" "${process:-N/A}"
            fi
        done < <(ss -ulnp 2>/dev/null | grep -v "State" | sort -t: -k2 -n | uniq)
        
    elif check_command netstat; then
        printf "║ %-8s %-15s %-12s %-25s ║\n" "CỔNG" "PROTOCOL" "KẾT NỐI" "PROCESS"
        print_header "╠────────────────────────────────────────────────────────────────╣"
        
        netstat -tlnp 2>/dev/null | grep -E 'LISTEN' | while read -r line; do
            local port=$(echo "$line" | awk '{print $4}' | grep -oE '[0-9]+$')
            local process=$(echo "$line" | awk '{print $7}' | cut -d'/' -f2 | head -c 20)
            local conn_count=$(netstat -tn 2>/dev/null | grep -c ":$port " || echo "0")
            printf "║ %-8s %-15s %-12s %-25s ║\n" "$port" "TCP" "$conn_count" "${process:-N/A}"
        done
    else
        printf "║ %-62s ║\n" "Không có công cụ ss hoặc netstat!"
    fi
    
    print_header "╚════════════════════════════════════════════════════════════════╝"
    echo ""
    
    # Hiển thị tổng số kết nối
    if check_command ss; then
        local total_conn=$(ss -tn state established 2>/dev/null | wc -l)
        print_info "Tổng số kết nối TCP đang hoạt động: $((total_conn - 1))"
    fi
}

# ===== XÓA KẾT NỐI TRÊN CỔNG =====
clear_port_connections() {
    # Hiển thị thông tin cổng và kết nối trước
    show_ports_and_connections
    
    ensure_conntrack
    
    echo -n "Nhập số cổng muốn xóa kết nối (hoặc 0 để quay lại): "
    read -r PORT
    
    if [ "$PORT" = "0" ]; then
        return 0
    fi
    
    if [[ ! "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
        print_error "Cổng không hợp lệ!"
        return 1
    fi
    
    # Đếm số kết nối trước khi xóa
    local before_count=0
    if check_command ss; then
        before_count=$(ss -tn state established 2>/dev/null | grep -c ":$PORT " || echo "0")
    fi
    
    print_info "Số kết nối hiện tại trên cổng $PORT: $before_count"
    
    if [ "$before_count" -eq 0 ]; then
        print_warn "Không có kết nối nào trên cổng $PORT."
        return 0
    fi
    
    echo -n "Xác nhận xóa $before_count kết nối? (y/N): "
    read -r confirm
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_info "Đã hủy."
        return 0
    fi
    
    print_info "Đang xóa kết nối trên cổng $PORT..."
    conntrack -D -p tcp --dport "$PORT" 2>/dev/null
    conntrack -D -p tcp --sport "$PORT" 2>/dev/null
    
    # Đếm lại sau khi xóa
    local after_count=0
    if check_command ss; then
        sleep 1
        after_count=$(ss -tn state established 2>/dev/null | grep -c ":$PORT " || echo "0")
    fi
    
    print_info "Đã xóa kết nối. Còn lại: $after_count kết nối trên cổng $PORT."
}

# ===== CHO PHÉP CỔNG TÙY CHỈNH =====
allow_custom_ports() {
    if ! check_iptables; then
        return 1
    fi
    
    OPEN_PORTS=$(get_open_ports)
    print_info "Các cổng đang mở: ${OPEN_PORTS:-Không có}"
    
    echo -n "Nhập danh sách cổng cần cho phép (cách nhau bằng dấu cách): "
    read -r CUSTOM_PORTS
    
    for port in $CUSTOM_PORTS; do
        if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
            iptables -A INPUT -p tcp --dport "$port" -j ACCEPT
            if check_command ip6tables; then
                ip6tables -A INPUT -p tcp --dport "$port" -j ACCEPT
            fi
            print_info "Đã cho phép cổng $port."
        else
            print_error "Cổng $port không hợp lệ, bỏ qua."
        fi
    done
    
    save_iptables_rules
}

# ===== XEM RULES HIỆN TẠI =====
show_current_rules() {
    echo ""
    print_header "Chọn firewall để xem rules:"
    
    local idx=1
    local available=()
    
    if check_command iptables; then
        echo "  $idx. iptables (IPv4 & IPv6)"
        available+=("iptables")
        ((idx++))
    fi
    
    if check_command nft; then
        echo "  $idx. nftables"
        available+=("nftables")
        ((idx++))
    fi
    
    if check_command firewall-cmd; then
        echo "  $idx. firewalld"
        available+=("firewalld")
        ((idx++))
    fi
    
    if check_command ufw; then
        echo "  $idx. ufw"
        available+=("ufw")
        ((idx++))
    fi
    
    if [ ${#available[@]} -eq 0 ]; then
        print_error "Không có firewall nào được cài đặt!"
        return 0
    fi
    
    echo "  0. Quay lại"
    echo ""
    echo -n "Lựa chọn: "
    read -r choice
    
    if [ "$choice" = "0" ] || [ -z "$choice" ]; then
        return 0
    fi
    
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -lt "$idx" ]; then
        local selected="${available[$((choice-1))]}"
        echo ""
        
        case $selected in
            iptables)
                print_header "╔════════════════════════════════════════════╗"
                print_header "║              IPTABLES IPv4                 ║"
                print_header "╚════════════════════════════════════════════╝"
                iptables -L -n -v --line-numbers 2>/dev/null || print_error "Không thể hiển thị"
                echo ""
                print_header "╔════════════════════════════════════════════╗"
                print_header "║              IPTABLES IPv6                 ║"
                print_header "╚════════════════════════════════════════════╝"
                ip6tables -L -n -v --line-numbers 2>/dev/null || print_error "Không thể hiển thị"
                ;;
            nftables)
                print_header "╔════════════════════════════════════════════╗"
                print_header "║              NFTABLES RULESET              ║"
                print_header "╚════════════════════════════════════════════╝"
                nft list ruleset 2>/dev/null || print_error "Không thể hiển thị"
                ;;
            firewalld)
                print_header "╔════════════════════════════════════════════╗"
                print_header "║              FIREWALLD INFO                ║"
                print_header "╚════════════════════════════════════════════╝"
                echo ""
                print_info "Trạng thái:"
                firewall-cmd --state 2>/dev/null
                echo ""
                print_info "Zone mặc định:"
                firewall-cmd --get-default-zone 2>/dev/null
                echo ""
                print_info "Active zones:"
                firewall-cmd --get-active-zones 2>/dev/null
                echo ""
                print_info "Services được phép:"
                firewall-cmd --list-services 2>/dev/null
                echo ""
                print_info "Ports được phép:"
                firewall-cmd --list-ports 2>/dev/null
                echo ""
                print_info "Chi tiết zone mặc định:"
                firewall-cmd --list-all 2>/dev/null
                ;;
            ufw)
                print_header "╔════════════════════════════════════════════╗"
                print_header "║                 UFW STATUS                 ║"
                print_header "╚════════════════════════════════════════════╝"
                ufw status verbose 2>/dev/null || print_error "Không thể hiển thị"
                echo ""
                print_info "Numbered rules:"
                ufw status numbered 2>/dev/null
                ;;
        esac
    else
        print_error "Lựa chọn không hợp lệ!"
    fi
}

# ===== MENU CHÍNH =====
show_menu() {
    echo ""
    print_header "╔════════════════════════════════════════════╗"
    print_header "║       FIREWALL MANAGER v$SCRIPT_VERSION          ║"
    print_header "╠════════════════════════════════════════════╣"
    # Hiển thị thông tin OS
    local os_display=$(echo "$OS_NAME" | head -c 40)
    printf "║  ${GREEN}OS:${NC} %-39s ║\n" "$os_display"
    printf "║  ${GREEN}Kernel:${NC} %-35s ║\n" "$(uname -r | head -c 35)"
    print_header "╠════════════════════════════════════════════╣"
    print_header "║  QUẢN LÝ CLOUDFLARE                        ║"
    echo -e "║  ${GREEN}1.${NC} Cho phép IP Cloudflare (chặn IP khác)  ║"
    echo -e "║  ${GREEN}2.${NC} Chặn tất cả IP Cloudflare              ║"
    print_header "╠────────────────────────────────────────────╣"
    print_header "║  QUẢN LÝ RULES                             ║"
    echo -e "║  ${GREEN}3.${NC} Thêm IP/subnet tùy chỉnh               ║"
    echo -e "║  ${GREEN}4.${NC} Cho phép cổng tùy chỉnh                ║"
    echo -e "║  ${GREEN}5.${NC} Xem rules hiện tại                     ║"
    echo -e "║  ${GREEN}6.${NC} Gỡ toàn bộ rules (mở tất cả cổng)      ║"
    print_header "╠────────────────────────────────────────────╣"
    print_header "║  QUẢN LÝ HỆ THỐNG                          ║"
    echo -e "║  ${CYAN}7.${NC} Quản lý Firewall (menu con) >>>        ║"
    echo -e "║  ${GREEN}8.${NC} Xóa kết nối trên cổng cụ thể           ║"
    print_header "╠────────────────────────────────────────────╣"
    echo -e "║  ${RED}0.${NC} Thoát                                  ║"
    print_header "╚════════════════════════════════════════════╝"
    echo ""
}

# ===== MAIN =====
main() {
    check_root
    detect_os
    
    clear
    echo ""
    print_header "╔════════════════════════════════════════════╗"
    print_header "║       FIREWALL MANAGER v$SCRIPT_VERSION          ║"
    print_header "╚════════════════════════════════════════════╝"
    echo ""
    print_info "Hệ điều hành: $OS_NAME"
    print_info "OS Family: $OS_FAMILY"
    echo ""
    
    list_installed_firewalls
    
    while true; do
        show_menu
        echo -n "Nhập lựa chọn [0-8]: "
        read -r choice
        echo ""
        
        case $choice in
            1) configure_cloudflare_rules ;;
            2) block_cloudflare_ips ;;
            3) add_custom_ip_subnet ;;
            4) allow_custom_ports ;;
            5) show_current_rules ;;
            6) remove_all_rules ;;
            7) firewall_management_menu ;;
            8) clear_port_connections ;;
            0) 
                print_info "Thoát chương trình."
                exit 0 
                ;;
            *)
                print_error "Lựa chọn không hợp lệ!"
                ;;
        esac
    done
}

# Chạy script
main "$@"

