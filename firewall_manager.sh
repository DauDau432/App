#!/bin/bash

# ============================================================
# FIREWALL MANAGER - Công cụ quản lý Firewall đa năng
# Hỗ trợ: Ubuntu, Debian, CentOS, RHEL, AlmaLinux, Rocky Linux,
#         CloudLinux, Fedora, Oracle Linux
# ============================================================

SCRIPT_VERSION="2.0.0"

# ===== MÀU SẮC (Sáng hơn) =====
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[1;36m'
WHITE='\033[1;37m'
MAGENTA='\033[1;35m'
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
        print_error "Cannot detect operating system!"
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
    print_info "Installing $pkg..."
    
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
            print_error "Auto installation not supported for this OS."
            return 1
            ;;
    esac
    
    if check_package "$pkg" || check_command "$pkg"; then
        print_info "$pkg đã được cài đặt thành công."
        return 0
    else
        print_error "Failed to install $pkg."
        return 1
    fi
}

# ===== GỠ CÀI ĐẶT GÓI =====
remove_package() {
    local pkg=$1
    local service_name=${2:-$pkg}
    
    # Kiểm tra gói hoặc command tồn tại
    if ! check_package "$pkg" && ! check_command "$pkg"; then
        print_error "Package $pkg is not installed."
        return 1
    fi
    
    print_info "Removing $pkg..."
    
    # Dừng service nếu đang chạy
    if systemctl is-active --quiet "$service_name" 2>/dev/null; then
        systemctl stop "$service_name" 2>/dev/null
        systemctl disable "$service_name" 2>/dev/null
        print_info "Stopped $service_name"
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
    
    print_info "$pkg removed."
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
        print_info "Installing conntrack..."
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
    echo -e "${WHITE}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${WHITE}║${NC}            ${CYAN}INSTALLED FIREWALLS ON SYSTEM${NC}                 ${WHITE}║${NC}"
    echo -e "${WHITE}╠══════════════════════════════════════════════════════════╣${NC}"
    printf "${WHITE}║${NC} %-14s %-12s %-8s %-18s ${WHITE}║${NC}\n" "NAME" "STATUS" "AUTO" "VERSION"
    echo -e "${WHITE}╠──────────────────────────────────────────────────────────╣${NC}"
    
    local found=false
    INSTALLED_FIREWALLS=()
    
    for pkg in firewalld ufw iptables nftables csf fail2ban; do
        local cmd="${FIREWALL_COMMANDS[$pkg]}"
        local service="${FIREWALL_SERVICES[$pkg]}"
        local is_installed=false
        
        # Kiểm tra package thực sự được cài đặt (không chỉ command)
        case $OS_FAMILY in
            rhel)
                case $pkg in
                    iptables)
                        rpm -q iptables >/dev/null 2>&1 && is_installed=true
                        ;;
                    nftables)
                        rpm -q nftables >/dev/null 2>&1 && is_installed=true
                        ;;
                    firewalld)
                        rpm -q firewalld >/dev/null 2>&1 && is_installed=true
                        ;;
                    *)
                        rpm -q "$pkg" >/dev/null 2>&1 && is_installed=true
                        ;;
                esac
                ;;
            debian)
                case $pkg in
                    iptables)
                        (dpkg-query -W iptables 2>/dev/null | grep -q .) && is_installed=true
                        ;;
                    nftables)
                        (dpkg-query -W nftables 2>/dev/null | grep -q .) && is_installed=true
                        ;;
                    firewalld)
                        (dpkg-query -W firewalld 2>/dev/null | grep -q .) && is_installed=true
                        ;;
                    ufw)
                        (dpkg-query -W ufw 2>/dev/null | grep -q .) && is_installed=true
                        ;;
                    *)
                        (dpkg-query -W "$pkg" 2>/dev/null | grep -q .) && is_installed=true
                        ;;
                esac
                ;;
            *)
                check_command "$cmd" && is_installed=true
                ;;
        esac
        
        if $is_installed; then
            found=true
            INSTALLED_FIREWALLS+=("$pkg")
            
            # Get version
            local version=""
            case $pkg in
                iptables)
                    version=$(iptables --version 2>/dev/null | grep -oE 'v[0-9.]+' | head -1)
                    ;;
                nftables)
                    version=$(nft --version 2>/dev/null | grep -oE 'v[0-9.]+' | head -1)
                    ;;
                firewalld)
                    version=$(firewall-cmd --version 2>/dev/null | head -1)
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
            [ -z "$version" ] && version="-"
            
            # Check service status
            local status="${YELLOW}Unknown${NC}"
            local autostart="${YELLOW}N/A${NC}"
            
            if systemctl list-unit-files "$service" 2>/dev/null | grep -q "$service"; then
                if systemctl is-active --quiet "$service" 2>/dev/null; then
                    status="${GREEN}Running${NC}"
                else
                    status="${RED}Stopped${NC}"
                fi
                
                if systemctl is-enabled --quiet "$service" 2>/dev/null; then
                    autostart="${GREEN}ON${NC}"
                else
                    autostart="${RED}OFF${NC}"
                fi
            else
                # Special check for iptables without service
                if [ "$pkg" = "iptables" ] && check_command iptables; then
                    local rule_count=$(iptables -L -n 2>/dev/null | wc -l)
                    if [ "$rule_count" -gt 8 ]; then
                        status="${GREEN}Active${NC}"
                    else
                        status="${YELLOW}Empty${NC}"
                    fi
                    autostart="${YELLOW}Manual${NC}"
                fi
            fi
            
            # Print with fixed width (accounting for color codes)
            printf "${WHITE}║${NC} %-14s " "$pkg"
            printf "%-21b " "$status"
            printf "%-17b " "$autostart"
            printf "%-18s " "$version"
            printf "${WHITE}║${NC}\n"
        fi
    done
    
    if ! $found; then
        printf "${WHITE}║${NC} %-56s ${WHITE}║${NC}\n" "No firewall installed."
    fi
    
    echo -e "${WHITE}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# ===== CẤU HÌNH CLOUDFLARE RULES =====
configure_cloudflare_rules() {
    if ! check_iptables; then
        return 1
    fi
    
    clear
    print_info "Configuring Cloudflare IP rules..."
    
    OPEN_PORTS=$(get_open_ports)
    print_info "Open ports: ${OPEN_PORTS:-None}"
    
    echo -n "Enter additional ports to allow (space separated, Enter to skip): "
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
                print_info "Allowed port $port (IPv4)"
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
    
    print_info "Cloudflare IP rules configured."
    echo ""
    echo -n "Press Enter to continue..."
    read -r
}

# ===== ADD CUSTOM IP/SUBNET =====
add_custom_ip_subnet() {
    if ! check_iptables; then
        return 1
    fi
    
    clear
    while true; do
        echo ""
        echo -n "Enter IP or subnet (e.g. 192.168.1.1 or 192.168.1.0/24): "
        read -r CUSTOM_IP
        
        if [ -z "$CUSTOM_IP" ]; then
            print_error "Please enter IP/subnet."
            continue
        fi
        
        echo ""
        echo "Select rule type:"
        echo "  1. Allow all connections from/to this IP"
        echo "  2. Allow only port 80/443"
        echo "  0. Back"
        echo -n "Select [0-2]: "
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
                print_info "Added rule for $CUSTOM_IP (all connections)."
                ;;
            2)
                if [[ "$CUSTOM_IP" =~ : ]]; then
                    ip6tables -I INPUT -p tcp -s "$CUSTOM_IP" --dport 80 -j ACCEPT
                    ip6tables -I INPUT -p tcp -s "$CUSTOM_IP" --dport 443 -j ACCEPT
                else
                    iptables -I INPUT -p tcp -s "$CUSTOM_IP" --dport 80 -j ACCEPT
                    iptables -I INPUT -p tcp -s "$CUSTOM_IP" --dport 443 -j ACCEPT
                fi
                print_info "Added rule for $CUSTOM_IP (port 80/443)."
                ;;
            *)
                print_error "Invalid selection!"
                continue
                ;;
        esac
        
        save_iptables_rules
        echo ""
        echo -n "Press Enter to continue..."
        read -r
        return 0
    done
}

# ===== BLOCK CLOUDFLARE IPS =====
block_cloudflare_ips() {
    if ! check_iptables; then
        return 1
    fi
    
    clear
    print_info "Blocking all Cloudflare IPs..."
    
    OPEN_PORTS=$(get_open_ports)
    print_info "Open ports: ${OPEN_PORTS:-None}"
    
    echo -n "Enter additional ports to allow (space separated, Enter to skip): "
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
    
    print_info "All Cloudflare IPs blocked."
    echo ""
    echo -n "Press Enter to continue..."
    read -r
}

# ===== REMOVE ALL RULES =====
remove_all_rules() {
    if ! check_iptables; then
        return 1
    fi
    
    print_warn "Warning: All ports will be open!"
    echo -n "Are you sure? (y/N): "
    read -r confirm
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_info "Cancelled."
        return 0
    fi
    
    print_info "Removing all rules..."
    
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
    
    print_info "All rules removed. All ports are open."
    echo ""
    echo -n "Press Enter to continue..."
    read -r
}

# ===== INSTALL IPTABLES =====
install_iptables_pkg() {
    print_info "Installing iptables..."
    
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
    print_warn "Stop all firewalls and disable auto-start."
    print_info "Firewalls will NOT be uninstalled, can be re-enabled later."
    echo ""
    echo -n "Are you sure? (y/N): "
    read -r confirm
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_info "Cancelled."
        return 0
    fi
    
    local stopped_count=0
    local disabled_count=0
    
    echo ""
    for pkg in firewalld ufw iptables ip6tables nftables csf lfd fail2ban netfilter-persistent; do
        local service="${FIREWALL_SERVICES[$pkg]}"
        
        if systemctl list-unit-files "$service" >/dev/null 2>&1; then
            if systemctl is-active --quiet "$service" 2>/dev/null; then
                systemctl stop "$service" 2>/dev/null
                print_info "Stopped: $pkg"
                ((stopped_count++))
            fi
            
            if systemctl is-enabled --quiet "$service" 2>/dev/null; then
                systemctl disable "$service" 2>/dev/null
                print_info "Disabled auto-start: $pkg"
                ((disabled_count++))
            fi
        fi
    done
    
    # Clear iptables rules (keep package)
    if check_command iptables; then
        print_info "Clearing iptables rules..."
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
    
    if check_command nft; then
        nft flush ruleset 2>/dev/null
        print_info "Cleared nftables ruleset"
    fi
    
    # Backup old rules
    if [ -f /etc/iptables/rules.v4 ]; then
        cp /etc/iptables/rules.v4 /etc/iptables/rules.v4.backup.$(date +%Y%m%d%H%M%S) 2>/dev/null
    fi
    if [ -f /etc/iptables/rules.v6 ]; then
        cp /etc/iptables/rules.v6 /etc/iptables/rules.v6.backup.$(date +%Y%m%d%H%M%S) 2>/dev/null
    fi
    
    # Create empty rules (ACCEPT all)
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
    print_info "Result:"
    print_info "  - Stopped: $stopped_count services"
    print_info "  - Disabled: $disabled_count services"
    print_info "  - Old rules backed up"
    echo ""
    print_warn "VPS has no firewall protection!"
    print_info "Use menu '2. Start/Enable firewall' to re-enable."
    echo ""
    echo -n "Press Enter to continue..."
    read -r
}

# ===== BẬT LẠI FIREWALL ĐÃ TẮT =====
enable_firewall_autostart() {
    echo ""
    echo -e "${CYAN}Select firewall to START/ENABLE:${NC}"
    print_info "Only showing installed firewalls"
    echo ""
    
    local idx=1
    local available_services=()
    
    for pkg in firewalld ufw iptables nftables csf fail2ban; do
        local cmd="${FIREWALL_COMMANDS[$pkg]}"
        local service="${FIREWALL_SERVICES[$pkg]}"
        local is_installed=false
        
        # Check if really installed
        case $OS_FAMILY in
            rhel) rpm -q "$pkg" >/dev/null 2>&1 && is_installed=true ;;
            debian) (dpkg-query -W "$pkg" 2>/dev/null | grep -q .) && is_installed=true ;;
            *) check_command "$cmd" && is_installed=true ;;
        esac
        
        if $is_installed; then
            local status_text=""
            if systemctl is-active --quiet "$service" 2>/dev/null; then
                status_text="${GREEN}[Running]${NC}"
            else
                status_text="${RED}[Stopped]${NC}"
            fi
            
            local auto_text=""
            if systemctl is-enabled --quiet "$service" 2>/dev/null; then
                auto_text="${GREEN}[Auto: ON]${NC}"
            else
                auto_text="${YELLOW}[Auto: OFF]${NC}"
            fi
            
            echo -e "  $idx. $pkg $status_text $auto_text"
            available_services+=("$service:$pkg")
            ((idx++))
        fi
    done
    
    if [ ${#available_services[@]} -eq 0 ]; then
        print_error "No firewall installed!"
        echo ""
        echo -n "Press Enter to continue..."
        read -r
        return 0
    fi
    
    echo ""
    echo "  A. Enable ALL firewalls"
    echo "  0. Back"
    echo ""
    echo -n "Select: "
    read -r choice
    
    if [ "$choice" = "0" ] || [ -z "$choice" ]; then
        return 0
    fi
    
    if [ "$choice" = "A" ] || [ "$choice" = "a" ]; then
        print_info "Enabling all firewalls..."
        for item in "${available_services[@]}"; do
            local service="${item%%:*}"
            local pkg="${item##*:}"
            
            systemctl unmask "$service" 2>/dev/null
            systemctl enable "$service" 2>/dev/null
            systemctl start "$service" 2>/dev/null
            
            if systemctl is-active --quiet "$service" 2>/dev/null; then
                print_info "$pkg: Started and running"
            else
                print_warn "$pkg: Enabled but failed to start"
            fi
        done
        echo ""
        echo -n "Press Enter to continue..."
        read -r
        return 0
    fi
    
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -lt "$idx" ]; then
        local selected="${available_services[$((choice-1))]}"
        local service="${selected%%:*}"
        local pkg="${selected##*:}"
        
        print_info "Starting $pkg..."
        
        systemctl unmask "$service" 2>/dev/null
        systemctl enable "$service" 2>/dev/null
        systemctl start "$service" 2>/dev/null
        
        if systemctl is-active --quiet "$service" 2>/dev/null; then
            print_info "$pkg is now running!"
        else
            print_warn "$pkg enabled but failed to start."
            print_info "Check: systemctl status $service"
        fi
        
        # For iptables, offer to restore rules
        if [ "$pkg" = "iptables" ]; then
            local latest_backup=$(ls -t /etc/iptables/rules.v4.backup.* 2>/dev/null | head -1)
            if [ -n "$latest_backup" ]; then
                echo -n "Backup rules found. Restore? (y/N): "
                read -r restore
                if [[ "$restore" =~ ^[Yy]$ ]]; then
                    iptables-restore < "$latest_backup" 2>/dev/null
                    print_info "Rules restored from backup."
                fi
            fi
        fi
        echo ""
        echo -n "Press Enter to continue..."
        read -r
    else
        print_error "Invalid selection!"
    fi
}

# ===== GỠ FIREWALL ĐƯỢC CHỌN =====
remove_selected_firewalls() {
    echo ""
    echo -e "${CYAN}Select firewall to UNINSTALL:${NC}"
    print_warn "Only showing installed firewalls"
    echo ""
    
    local idx=1
    local available_firewalls=()
    
    # Check if package is really installed
    for pkg in firewalld ufw iptables nftables csf fail2ban; do
        local is_installed=false
        
        case $OS_FAMILY in
            rhel)
                case $pkg in
                    iptables) rpm -q iptables >/dev/null 2>&1 && is_installed=true ;;
                    nftables) rpm -q nftables >/dev/null 2>&1 && is_installed=true ;;
                    *) rpm -q "$pkg" >/dev/null 2>&1 && is_installed=true ;;
                esac
                ;;
            debian)
                case $pkg in
                    iptables) (dpkg-query -W iptables 2>/dev/null | grep -q .) && is_installed=true ;;
                    nftables) (dpkg-query -W nftables 2>/dev/null | grep -q .) && is_installed=true ;;
                    ufw) (dpkg-query -W ufw 2>/dev/null | grep -q .) && is_installed=true ;;
                    *) (dpkg-query -W "$pkg" 2>/dev/null | grep -q .) && is_installed=true ;;
                esac
                ;;
            *)
                local cmd="${FIREWALL_COMMANDS[$pkg]}"
                check_command "$cmd" && is_installed=true
                ;;
        esac
        
        if $is_installed; then
            echo -e "  ${GREEN}$idx.${NC} $pkg"
            available_firewalls+=("$pkg")
            ((idx++))
        fi
    done
    
    if [ ${#available_firewalls[@]} -eq 0 ]; then
        print_error "No firewall installed!"
        echo ""
        echo -n "Press Enter to continue..."
        read -r
        return 0
    fi
    
    echo -e "  ${RED}A.${NC} Uninstall ALL"
    echo "  0. Back"
    echo ""
    echo -n "Select: "
    read -r choice
    
    if [ "$choice" = "0" ] || [ -z "$choice" ]; then
        return 0
    fi
    
    if [ "$choice" = "A" ] || [ "$choice" = "a" ]; then
        print_warn "You are about to uninstall ALL firewalls!"
        echo -n "Type 'yes' to confirm: "
        read -r confirm
        if [ "$confirm" != "yes" ]; then
            print_info "Cancelled."
            return 0
        fi
        
        for pkg in "${available_firewalls[@]}"; do
            remove_single_firewall "$pkg"
        done
        print_info "All firewalls uninstalled!"
        echo ""
        echo -n "Press Enter to continue..."
        read -r
        return 0
    fi
    
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -lt "$idx" ]; then
        local selected="${available_firewalls[$((choice-1))]}"
        print_warn "You are about to uninstall: $selected"
        echo -n "Confirm? (y/N): "
        read -r confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            remove_single_firewall "$selected"
            echo ""
            echo -n "Press Enter to continue..."
            read -r
        else
            print_info "Cancelled."
        fi
    else
        print_error "Invalid selection!"
    fi
}

# ===== REMOVE SINGLE FIREWALL =====
remove_single_firewall() {
    local pkg=$1
    local service="${FIREWALL_SERVICES[$pkg]}"
    
    print_info "Removing $pkg..."
    
    # Stop service
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
    
    print_info "$pkg removed successfully!"
}

# ===== MENU QUẢN LÝ FIREWALL =====
firewall_management_menu() {
    while true; do
        clear
        echo ""
        local os_short=$(echo "$OS_NAME" | head -c 40)
        
        echo -e "${WHITE}╔══════════════════════════════════════════════════╗${NC}"
        printf "${WHITE}║${NC}  ${GREEN}OS:${NC} %-44s ${WHITE}║${NC}\n" "$os_short"
        echo -e "${WHITE}╚══════════════════════════════════════════════════╝${NC}"
        echo ""
        
        list_installed_firewalls
        
        echo -e "${WHITE}╔══════════════════════════════════════════════════╗${NC}"
        echo -e "${WHITE}║${NC}          ${CYAN}FIREWALL MANAGEMENT${NC}                     ${WHITE}║${NC}"
        echo -e "${WHITE}╠══════════════════════════════════════════════════╣${NC}"
        echo -e "${WHITE}║${NC}  ${YELLOW}1.${NC} Stop all firewalls (keep installed)       ${WHITE}║${NC}"
        echo -e "${WHITE}║${NC}  ${GREEN}2.${NC} Start/Enable firewall                     ${WHITE}║${NC}"
        echo -e "${WHITE}║${NC}  ${RED}3.${NC} Uninstall firewall (select)               ${WHITE}║${NC}"
        echo -e "${WHITE}║${NC}  ${GREEN}4.${NC} Install iptables                          ${WHITE}║${NC}"
        echo -e "${WHITE}╠──────────────────────────────────────────────────╣${NC}"
        echo -e "${WHITE}║${NC}  ${BLUE}0.${NC} Back to main menu                         ${WHITE}║${NC}"
        echo -e "${WHITE}╚══════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -n "Select [0-4]: "
        read -r choice
        echo ""
        
        case $choice in
            1) stop_disable_all_firewalls ;;
            2) enable_firewall_autostart ;;
            3) remove_selected_firewalls ;;
            4) install_iptables_pkg ;;
            0) return 0 ;;
            *)
                print_error "Invalid selection!"
                ;;
        esac
    done
}

# ===== HIỂN THỊ CỔNG ĐANG MỞ VÀ SỐ KẾT NỐI =====
show_ports_and_connections() {
    clear
    echo ""
    echo -e "${WHITE}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${WHITE}║${NC}           ${CYAN}LISTENING PORTS & CONNECTIONS${NC}                   ${WHITE}║${NC}"
    echo -e "${WHITE}╠════════════════════════════════════════════════════════════╣${NC}"
    printf "${WHITE}║${NC} %-8s %-10s %-12s %-24s ${WHITE}║${NC}\n" "PORT" "PROTOCOL" "CONNECTIONS" "PROCESS"
    echo -e "${WHITE}╠────────────────────────────────────────────────────────────╣${NC}"
    
    if check_command ss; then
        # TCP ports
        while read -r line; do
            local port=$(echo "$line" | awk '{print $5}' | grep -oE '[0-9]+$')
            local proto="TCP"
            local process=$(echo "$line" | awk -F'"' '{print $2}' | head -c 20)
            
            if [ -n "$port" ]; then
                local conn_count=$(ss -tn state established 2>/dev/null | grep -c ":$port " || echo "0")
                printf "${WHITE}║${NC} %-8s %-10s %-12s %-24s ${WHITE}║${NC}\n" "$port" "$proto" "$conn_count" "${process:-N/A}"
            fi
        done < <(ss -tlnp 2>/dev/null | grep -E 'LISTEN' | sort -t: -k2 -n | uniq)
        
        # UDP ports
        while read -r line; do
            local port=$(echo "$line" | awk '{print $5}' | grep -oE '[0-9]+$')
            local proto="UDP"
            local process=$(echo "$line" | awk -F'"' '{print $2}' | head -c 20)
            
            if [ -n "$port" ]; then
                printf "${WHITE}║${NC} %-8s %-10s %-12s %-24s ${WHITE}║${NC}\n" "$port" "$proto" "-" "${process:-N/A}"
            fi
        done < <(ss -ulnp 2>/dev/null | grep -v "State" | sort -t: -k2 -n | uniq)
        
    elif check_command netstat; then
        netstat -tlnp 2>/dev/null | grep -E 'LISTEN' | while read -r line; do
            local port=$(echo "$line" | awk '{print $4}' | grep -oE '[0-9]+$')
            local process=$(echo "$line" | awk '{print $7}' | cut -d'/' -f2 | head -c 20)
            local conn_count=$(netstat -tn 2>/dev/null | grep -c ":$port " || echo "0")
            printf "${WHITE}║${NC} %-8s %-10s %-12s %-24s ${WHITE}║${NC}\n" "$port" "TCP" "$conn_count" "${process:-N/A}"
        done
    else
        printf "${WHITE}║${NC} %-56s ${WHITE}║${NC}\n" "No ss or netstat available!"
    fi
    
    echo -e "${WHITE}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    if check_command ss; then
        local total_conn=$(ss -tn state established 2>/dev/null | wc -l)
        print_info "Total active TCP connections: $((total_conn - 1))"
    fi
}

# ===== CLEAR CONNECTIONS ON PORT =====
clear_port_connections() {
    show_ports_and_connections
    
    ensure_conntrack
    
    echo ""
    echo -n "Enter port to clear connections (0 to go back): "
    read -r PORT
    
    if [ "$PORT" = "0" ]; then
        return 0
    fi
    
    if [[ ! "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
        print_error "Invalid port!"
        sleep 1
        return 1
    fi
    
    local before_count=0
    if check_command ss; then
        before_count=$(ss -tn state established 2>/dev/null | grep -c ":$PORT " || echo "0")
    fi
    
    print_info "Current connections on port $PORT: $before_count"
    
    if [ "$before_count" -eq 0 ]; then
        print_warn "No connections on port $PORT."
        echo ""
        echo -n "Press Enter to continue..."
        read -r
        return 0
    fi
    
    echo -n "Confirm clear $before_count connections? (y/N): "
    read -r confirm
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_info "Cancelled."
        return 0
    fi
    
    print_info "Clearing connections on port $PORT..."
    conntrack -D -p tcp --dport "$PORT" 2>/dev/null
    conntrack -D -p tcp --sport "$PORT" 2>/dev/null
    
    local after_count=0
    if check_command ss; then
        sleep 1
        after_count=$(ss -tn state established 2>/dev/null | grep -c ":$PORT " || echo "0")
    fi
    
    print_info "Connections cleared. Remaining: $after_count on port $PORT."
    echo ""
    echo -n "Press Enter to continue..."
    read -r
}

# ===== ALLOW CUSTOM PORTS =====
allow_custom_ports() {
    if ! check_iptables; then
        return 1
    fi
    
    clear
    OPEN_PORTS=$(get_open_ports)
    print_info "Currently open ports: ${OPEN_PORTS:-None}"
    echo ""
    echo -n "Enter ports to allow (space separated): "
    read -r CUSTOM_PORTS
    
    if [ -z "$CUSTOM_PORTS" ]; then
        print_info "No ports entered."
        return 0
    fi
    
    for port in $CUSTOM_PORTS; do
        if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
            iptables -A INPUT -p tcp --dport "$port" -j ACCEPT
            if check_command ip6tables; then
                ip6tables -A INPUT -p tcp --dport "$port" -j ACCEPT
            fi
            print_info "Allowed port $port."
        else
            print_error "Port $port invalid, skipped."
        fi
    done
    
    save_iptables_rules
    echo ""
    echo -n "Press Enter to continue..."
    read -r
}

# ===== XEM RULES HIỆN TẠI =====
show_current_rules() {
    clear
    echo ""
    echo -e "${CYAN}Select firewall to view rules:${NC}"
    echo ""
    
    local idx=1
    local available=()
    
    if check_command iptables; then
        echo -e "  ${GREEN}$idx.${NC} iptables (IPv4 & IPv6)"
        available+=("iptables")
        ((idx++))
    fi
    
    if check_command nft; then
        echo -e "  ${GREEN}$idx.${NC} nftables"
        available+=("nftables")
        ((idx++))
    fi
    
    if check_command firewall-cmd; then
        echo -e "  ${GREEN}$idx.${NC} firewalld"
        available+=("firewalld")
        ((idx++))
    fi
    
    if check_command ufw; then
        echo -e "  ${GREEN}$idx.${NC} ufw"
        available+=("ufw")
        ((idx++))
    fi
    
    if [ ${#available[@]} -eq 0 ]; then
        print_error "No firewall installed!"
        echo ""
        echo -n "Press Enter to continue..."
        read -r
        return 0
    fi
    
    echo "  0. Back"
    echo ""
    echo -n "Select: "
    read -r choice
    
    if [ "$choice" = "0" ] || [ -z "$choice" ]; then
        return 0
    fi
    
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -lt "$idx" ]; then
        local selected="${available[$((choice-1))]}"
        clear
        echo ""
        
        case $selected in
            iptables)
                echo -e "${WHITE}═══════════════════════════════════════════════${NC}"
                echo -e "${CYAN}                IPTABLES IPv4${NC}"
                echo -e "${WHITE}═══════════════════════════════════════════════${NC}"
                iptables -L -n -v --line-numbers 2>/dev/null || print_error "Cannot display"
                echo ""
                echo -e "${WHITE}═══════════════════════════════════════════════${NC}"
                echo -e "${CYAN}                IPTABLES IPv6${NC}"
                echo -e "${WHITE}═══════════════════════════════════════════════${NC}"
                ip6tables -L -n -v --line-numbers 2>/dev/null || print_error "Cannot display"
                ;;
            nftables)
                echo -e "${WHITE}═══════════════════════════════════════════════${NC}"
                echo -e "${CYAN}              NFTABLES RULESET${NC}"
                echo -e "${WHITE}═══════════════════════════════════════════════${NC}"
                nft list ruleset 2>/dev/null || print_error "Cannot display"
                ;;
            firewalld)
                echo -e "${WHITE}═══════════════════════════════════════════════${NC}"
                echo -e "${CYAN}              FIREWALLD INFO${NC}"
                echo -e "${WHITE}═══════════════════════════════════════════════${NC}"
                echo ""
                print_info "State:"
                firewall-cmd --state 2>/dev/null
                echo ""
                print_info "Default zone:"
                firewall-cmd --get-default-zone 2>/dev/null
                echo ""
                print_info "Active zones:"
                firewall-cmd --get-active-zones 2>/dev/null
                echo ""
                print_info "Allowed services:"
                firewall-cmd --list-services 2>/dev/null
                echo ""
                print_info "Allowed ports:"
                firewall-cmd --list-ports 2>/dev/null
                echo ""
                print_info "Default zone details:"
                firewall-cmd --list-all 2>/dev/null
                ;;
            ufw)
                echo -e "${WHITE}═══════════════════════════════════════════════${NC}"
                echo -e "${CYAN}                UFW STATUS${NC}"
                echo -e "${WHITE}═══════════════════════════════════════════════${NC}"
                ufw status verbose 2>/dev/null || print_error "Cannot display"
                echo ""
                print_info "Numbered rules:"
                ufw status numbered 2>/dev/null
                ;;
        esac
    else
        print_error "Invalid selection!"
    fi
}

# ===== MAIN MENU =====
show_menu() {
    clear
    echo ""
    local os_short=$(echo "$OS_NAME" | head -c 30)
    local kernel_short=$(uname -r | head -c 20)
    
    echo -e "${WHITE}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${WHITE}║${NC}       ${MAGENTA}FIREWALL MANAGER${NC} ${CYAN}v$SCRIPT_VERSION${NC}               ${WHITE}║${NC}"
    echo -e "${WHITE}╠══════════════════════════════════════════════════╣${NC}"
    printf "${WHITE}║${NC}  ${GREEN}OS:${NC} %-30s ${GREEN}Kernel:${NC} %-10s ${WHITE}║${NC}\n" "$os_short" "$kernel_short"
    echo -e "${WHITE}╠══════════════════════════════════════════════════╣${NC}"
    echo -e "${WHITE}║${NC}  ${CYAN}CLOUDFLARE${NC}                                     ${WHITE}║${NC}"
    echo -e "${WHITE}║${NC}  ${GREEN}1.${NC} Allow Cloudflare IPs (block others)        ${WHITE}║${NC}"
    echo -e "${WHITE}║${NC}  ${GREEN}2.${NC} Block all Cloudflare IPs                   ${WHITE}║${NC}"
    echo -e "${WHITE}╠──────────────────────────────────────────────────╣${NC}"
    echo -e "${WHITE}║${NC}  ${CYAN}RULES MANAGEMENT${NC}                               ${WHITE}║${NC}"
    echo -e "${WHITE}║${NC}  ${GREEN}3.${NC} Add custom IP/subnet                       ${WHITE}║${NC}"
    echo -e "${WHITE}║${NC}  ${GREEN}4.${NC} Allow custom ports                         ${WHITE}║${NC}"
    echo -e "${WHITE}║${NC}  ${GREEN}5.${NC} View current rules                         ${WHITE}║${NC}"
    echo -e "${WHITE}║${NC}  ${GREEN}6.${NC} Remove all rules (open all ports)          ${WHITE}║${NC}"
    echo -e "${WHITE}╠──────────────────────────────────────────────────╣${NC}"
    echo -e "${WHITE}║${NC}  ${CYAN}SYSTEM${NC}                                         ${WHITE}║${NC}"
    echo -e "${WHITE}║${NC}  ${MAGENTA}7.${NC} Firewall Management >>>                     ${WHITE}║${NC}"
    echo -e "${WHITE}║${NC}  ${GREEN}8.${NC} Clear connections on port                  ${WHITE}║${NC}"
    echo -e "${WHITE}╠──────────────────────────────────────────────────╣${NC}"
    echo -e "${WHITE}║${NC}  ${RED}0.${NC} Exit                                        ${WHITE}║${NC}"
    echo -e "${WHITE}╚══════════════════════════════════════════════════╝${NC}"
    echo ""
}

# ===== MAIN =====
main() {
    check_root
    detect_os
    
    # Show initial screen
    clear
    echo ""
    echo -e "${WHITE}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${WHITE}║${NC}       ${MAGENTA}FIREWALL MANAGER${NC} ${CYAN}v$SCRIPT_VERSION${NC}               ${WHITE}║${NC}"
    echo -e "${WHITE}╚══════════════════════════════════════════════════╝${NC}"
    echo ""
    print_info "OS: $OS_NAME"
    print_info "Kernel: $(uname -r)"
    echo ""
    
    list_installed_firewalls
    
    echo -n "Press Enter to continue..."
    read -r
    
    while true; do
        show_menu
        echo -n "Select [0-8]: "
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
                clear
                print_info "Goodbye!"
                exit 0 
                ;;
            *)
                print_error "Invalid selection!"
                sleep 1
                ;;
        esac
    done
}

# Run script
main "$@"

