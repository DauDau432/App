#!/bin/bash
#
# Script tối ưu ulimit và sysctl cho Linux
# Hỗ trợ: Ubuntu, Debian, CentOS, RHEL, Fedora, Arch Linux và các distro Linux khác
# Tác giả: H2Cloud
# Phiên bản: 2.0
#

# ================== MÀU SẮC ==================
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
BLUE="\033[1;34m"
RED="\033[1;31m"
RESET="\033[0m"

# ================== PHÁT HIỆN HỆ ĐIỀU HÀNH ==================
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        OS_VERSION=$VERSION_ID
    elif [ -f /etc/redhat-release ]; then
        OS="rhel"
        OS_VERSION=$(cat /etc/redhat-release | sed -E 's/.*release ([0-9]+).*/\1/')
    elif [ -f /etc/debian_version ]; then
        OS="debian"
        OS_VERSION=$(cat /etc/debian_version)
    else
        OS="unknown"
    fi
    
    # Kiểm tra package manager
    if command -v apt-get &> /dev/null; then
        PKG_MANAGER="apt"
    elif command -v yum &> /dev/null; then
        PKG_MANAGER="yum"
    elif command -v dnf &> /dev/null; then
        PKG_MANAGER="dnf"
    elif command -v pacman &> /dev/null; then
        PKG_MANAGER="pacman"
    else
        PKG_MANAGER="unknown"
    fi
    
    # Kiểm tra systemd
    if command -v systemctl &> /dev/null && systemctl --version &> /dev/null; then
        HAS_SYSTEMD=1
    else
        HAS_SYSTEMD=0
    fi
    
    # Xác định file PAM
    if [ -f /etc/pam.d/common-session ]; then
        PAM_SESSION_FILE="/etc/pam.d/common-session"
    elif [ -f /etc/pam.d/system-auth ]; then
        PAM_SESSION_FILE="/etc/pam.d/system-auth"
    else
        PAM_SESSION_FILE=""
    fi
    
    # Xác định SSH service name
    if [ $HAS_SYSTEMD -eq 1 ]; then
        if systemctl list-units --type=service 2>/dev/null | grep -q "ssh.service"; then
            SSH_SERVICE="ssh"
        elif systemctl list-units --type=service 2>/dev/null | grep -q "sshd.service"; then
            SSH_SERVICE="sshd"
        else
            SSH_SERVICE="sshd"
        fi
    else
        SSH_SERVICE="sshd"
    fi
    
    echo -e "${BLUE}[*] Phát hiện hệ thống: ${OS} ${OS_VERSION} (${PKG_MANAGER})${RESET}"
    [ $HAS_SYSTEMD -eq 1 ] && echo -e "${BLUE}[*] Systemd: Có${RESET}" || echo -e "${YELLOW}[*] Systemd: Không${RESET}"
}

# ================== CÀI ĐẶT NET-TOOLS ==================
install_net_tools() {
    if ! command -v netstat &> /dev/null; then
        echo -e "${YELLOW}[+] Đang cài đặt net-tools...${RESET}"
        case $PKG_MANAGER in
            apt)
                apt-get update -qq && apt-get install -y net-tools
                ;;
            yum)
                yum install -y net-tools
                ;;
            dnf)
                dnf install -y net-tools
                ;;
            pacman)
                pacman -S --noconfirm net-tools
                ;;
            *)
                echo -e "${RED}[-] Không thể cài đặt net-tools. Vui lòng cài thủ công.${RESET}"
                return 1
                ;;
        esac
    fi
}

# ================== HÀM: THÔNG TIN HIỆN TẠI ==================
show_limits() {
    echo -e "${BLUE}[>>] Thông tin hệ thống hiện tại:${RESET}"
    echo -e "[*] ulimit -n (nofile):        $(ulimit -n)"
    echo -e "[*] ulimit -u (nproc):         $(ulimit -u)"
    echo -e "[*] kernel.pid_max:            $(cat /proc/sys/kernel/pid_max 2>/dev/null || echo 'N/A')"
    echo -e "[*] fs.file-max:               $(cat /proc/sys/fs/file-max 2>/dev/null || echo 'N/A')"
    if command -v netstat &> /dev/null; then
        echo -e "[*] Kết nối cổng 443:         $(netstat -alntp 2>/dev/null | grep :443 | wc -l)"
    fi
    echo
}

# ================== HÀM: KIỂM TRA KẾT NỐI CỔNG 443 ==================
check_port_443() {
    install_net_tools
    if command -v netstat &> /dev/null; then
        count=$(netstat -alntp 2>/dev/null | grep :443 | wc -l)
        echo -e "${BLUE}[>>] Số kết nối tại cổng 443: ${count}${RESET}"
    else
        echo -e "${RED}[-] Không thể kiểm tra (netstat chưa được cài đặt)${RESET}"
    fi
}

# ================== HÀM: MỞ TỐI ĐA ==================
max_out_limits() {
    echo -e "${GREEN}[+] Đang mở tối đa tất cả giới hạn...${RESET}"

    # Sửa /etc/security/limits.conf
    if ! grep -q 'nofile' /etc/security/limits.conf; then
        cat <<EOF >> /etc/security/limits.conf
* soft nofile 1048576
* hard nofile 1048576
* soft nproc 4194303
* hard nproc 4194303
EOF
    fi

    # Sửa /etc/security/limits.d/nofile.conf (ưu tiên hơn limits.conf)
    mkdir -p /etc/security/limits.d
    cat <<EOF > /etc/security/limits.d/nofile.conf
* soft nofile 1048576
* hard nofile 1048576
* soft nproc 4194303
* hard nproc 4194303
EOF

    # Sửa systemd (nếu có)
    if [ $HAS_SYSTEMD -eq 1 ]; then
        mkdir -p /etc/systemd/system.conf.d
        cat <<EOF > /etc/systemd/system.conf.d/ulimit.conf
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=4194303
EOF

        # Override SSH systemd service
        mkdir -p /etc/systemd/system/${SSH_SERVICE}.service.d
        cat <<EOF > /etc/systemd/system/${SSH_SERVICE}.service.d/override.conf
[Service]
LimitNOFILE=1048576
LimitNPROC=4194303
EOF
    fi

    # Sửa PAM (hỗ trợ nhiều distro)
    if [ -n "$PAM_SESSION_FILE" ] && [ -f "$PAM_SESSION_FILE" ]; then
        if ! grep -q "pam_limits.so" "$PAM_SESSION_FILE" 2>/dev/null; then
            echo "session required pam_limits.so" >> "$PAM_SESSION_FILE"
        fi
    fi
    if [ -f /etc/pam.d/sshd ]; then
        if ! grep -q "pam_limits.so" /etc/pam.d/sshd 2>/dev/null; then
            echo "session required pam_limits.so" >> /etc/pam.d/sshd
        fi
    fi

    # Sửa SSH
    if [ -f /etc/ssh/sshd_config ]; then
        sed -i 's/^#UsePAM no/UsePAM yes/' /etc/ssh/sshd_config
        sed -i 's/^UsePAM no/UsePAM yes/' /etc/ssh/sshd_config
    fi

    # Tăng pid_max nếu cần
    sysctl -w kernel.pid_max=4194303 2>/dev/null
    grep -q "kernel.pid_max" /etc/sysctl.conf 2>/dev/null || echo "kernel.pid_max = 4194303" >> /etc/sysctl.conf

    # Thêm vào ~/.bashrc nếu chưa có
    if ! grep -q "ulimit -n 1048576" ~/.bashrc 2>/dev/null; then
        echo "ulimit -n 1048576" >> ~/.bashrc
        echo -e "${YELLOW}[+] Đã thêm 'ulimit -n 1048576' vào ~/.bashrc${RESET}"
    fi

    # Reload systemd & SSH (nếu có)
    if [ $HAS_SYSTEMD -eq 1 ]; then
        systemctl daemon-reexec 2>/dev/null
        systemctl daemon-reload 2>/dev/null
        systemctl restart ${SSH_SERVICE} 2>/dev/null || service ${SSH_SERVICE} restart 2>/dev/null
    else
        if [ -f /etc/init.d/sshd ]; then
            /etc/init.d/sshd restart 2>/dev/null
        fi
    fi

    echo -e "${GREEN}[+] Hoàn tất mở tối đa giới hạn.${RESET}"
}

# ================== HÀM: TỰ ĐỘNG THEO VPS ==================
auto_configure_limits() {
    echo -e "${YELLOW}[+] Đang cấu hình tự động theo VPS...${RESET}"
    total_mem=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    cpu_cores=$(nproc)

    nofile=$((total_mem * 1024 / 2))
    nproc=$((cpu_cores * 100000))

    [ $nofile -gt 1048576 ] && nofile=1048576
    [ $nproc -gt 4194303 ] && nproc=4194303

    echo -e "${BLUE}[*] Tính toán: nofile=$nofile, nproc=$nproc${RESET}"

    # Giống như max_out nhưng giá trị thay đổi
    sed -i '/nofile/d;/nproc/d' /etc/security/limits.conf
    cat <<EOF >> /etc/security/limits.conf
* soft nofile $nofile
* hard nofile $nofile
* soft nproc $nproc
* hard nproc $nproc
EOF

    # Sửa /etc/security/limits.d/nofile.conf
    mkdir -p /etc/security/limits.d
    cat <<EOF > /etc/security/limits.d/nofile.conf
* soft nofile $nofile
* hard nofile $nofile
* soft nproc $nproc
* hard nproc $nproc
EOF

    if [ $HAS_SYSTEMD -eq 1 ]; then
        mkdir -p /etc/systemd/system.conf.d
        cat <<EOF > /etc/systemd/system.conf.d/ulimit.conf
[Manager]
DefaultLimitNOFILE=$nofile
DefaultLimitNPROC=$nproc
EOF

        mkdir -p /etc/systemd/system/${SSH_SERVICE}.service.d
        cat <<EOF > /etc/systemd/system/${SSH_SERVICE}.service.d/override.conf
[Service]
LimitNOFILE=$nofile
LimitNPROC=$nproc
EOF
    fi

    sysctl -w kernel.pid_max=4194303 2>/dev/null
    grep -q "kernel.pid_max" /etc/sysctl.conf 2>/dev/null || echo "kernel.pid_max = 4194303" >> /etc/sysctl.conf

    if ! grep -q "ulimit -n $nofile" ~/.bashrc 2>/dev/null; then
        echo "ulimit -n $nofile" >> ~/.bashrc
        echo -e "${YELLOW}[+] Đã thêm 'ulimit -n $nofile' vào ~/.bashrc${RESET}"
    fi

    if [ $HAS_SYSTEMD -eq 1 ]; then
        systemctl daemon-reexec 2>/dev/null
        systemctl daemon-reload 2>/dev/null
        systemctl restart ${SSH_SERVICE} 2>/dev/null || service ${SSH_SERVICE} restart 2>/dev/null
    else
        if [ -f /etc/init.d/sshd ]; then
            /etc/init.d/sshd restart 2>/dev/null
        fi
    fi

    echo -e "${GREEN}[+] Hoàn tất cấu hình tự động.${RESET}"
}

# ================== HÀM: KHÔI PHỤC MẶC ĐỊNH ==================
reset_defaults() {
    echo -e "${YELLOW}[-] Đang khôi phục mặc định...${RESET}"
    sed -i '/nofile/d;/nproc/d' /etc/security/limits.conf
    rm -f /etc/security/limits.d/nofile.conf
    rm -f /etc/systemd/system.conf.d/ulimit.conf
    rm -f /etc/systemd/system/${SSH_SERVICE}.service.d/override.conf
    rm -rf /etc/systemd/system/${SSH_SERVICE}.service.d
    
    if [ -n "$PAM_SESSION_FILE" ] && [ -f "$PAM_SESSION_FILE" ]; then
        sed -i '/pam_limits.so/d' "$PAM_SESSION_FILE" 2>/dev/null
    fi
    if [ -f /etc/pam.d/sshd ]; then
        sed -i '/pam_limits.so/d' /etc/pam.d/sshd 2>/dev/null
    fi
    
    if [ -f /etc/ssh/sshd_config ]; then
        sed -i 's/^UsePAM yes/#UsePAM no/' /etc/ssh/sshd_config
    fi

    sed -i '/ulimit -n/d' ~/.bashrc 2>/dev/null

    sysctl -w kernel.pid_max=32768 2>/dev/null
    sed -i '/kernel.pid_max/d' /etc/sysctl.conf 2>/dev/null

    if [ $HAS_SYSTEMD -eq 1 ]; then
        systemctl daemon-reexec 2>/dev/null
        systemctl daemon-reload 2>/dev/null
        systemctl restart ${SSH_SERVICE} 2>/dev/null || service ${SSH_SERVICE} restart 2>/dev/null
    else
        if [ -f /etc/init.d/sshd ]; then
            /etc/init.d/sshd restart 2>/dev/null
        fi
    fi

    echo -e "${GREEN}[-] Đã khôi phục mặc định hệ thống.${RESET}"
}

# ================== HÀM: CẤU HÌNH SYSCTL TỐI ƯU ==================
configure_sysctl_optimized() {
    echo -e "${GREEN}[+] Đang cấu hình sysctl tối ưu...${RESET}"
    
    # Backup sysctl.conf nếu chưa có backup
    if [ ! -f /etc/sysctl.conf.bak ]; then
        if [ -f /etc/sysctl.conf ]; then
            cp /etc/sysctl.conf /etc/sysctl.conf.bak
            echo -e "${YELLOW}[+] Đã backup /etc/sysctl.conf thành /etc/sysctl.conf.bak${RESET}"
        fi
    fi
    
    # Tạo file sysctl.conf mới với cấu hình tối ưu
    cat <<EOF > /etc/sysctl.conf
# Cấu hình kernel
kernel.printk = 4 4 1 7
kernel.panic = 10
kernel.sysrq = 0
kernel.shmmax = 4294967296
kernel.shmall = 4194304
kernel.core_uses_pid = 1
kernel.msgmnb = 65536
kernel.msgmax = 65536
kernel.pid_max = 4194303

# Cấu hình virtual memory
vm.swappiness = 20
vm.dirty_ratio = 80
vm.dirty_background_ratio = 5

# Cấu hình file system
fs.file-max = 2097152

# Cấu hình network core
net.core.netdev_max_backlog = 262144
net.core.rmem_default = 31457280
net.core.rmem_max = 67108864
net.core.wmem_default = 31457280
net.core.wmem_max = 67108864
net.core.somaxconn = 65535
net.core.optmem_max = 25165824

# Cấu hình IPv4 neighbor
net.ipv4.neigh.default.gc_thresh1 = 4096
net.ipv4.neigh.default.gc_thresh2 = 8192
net.ipv4.neigh.default.gc_thresh3 = 16384
net.ipv4.neigh.default.gc_interval = 5
net.ipv4.neigh.default.gc_stale_time = 120

# Cấu hình netfilter conntrack
net.netfilter.nf_conntrack_max = 10000000
net.netfilter.nf_conntrack_tcp_loose = 0
net.netfilter.nf_conntrack_tcp_timeout_established = 1800
net.netfilter.nf_conntrack_tcp_timeout_close = 10
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 10
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 20
net.netfilter.nf_conntrack_tcp_timeout_last_ack = 20
net.netfilter.nf_conntrack_tcp_timeout_syn_recv = 20
net.netfilter.nf_conntrack_tcp_timeout_syn_sent = 20
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 10

# Cấu hình TCP
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.ip_local_port_range = 1024 65000
net.ipv4.ip_no_pmtu_disc = 1
net.ipv4.route.flush = 1
net.ipv4.route.max_size = 8048576
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.tcp_congestion_control = htcp
net.ipv4.tcp_mem = 65536 131072 262144
net.ipv4.udp_mem = 65536 131072 262144
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.udp_rmem_min = 16384
net.ipv4.tcp_wmem = 4096 87380 33554432
net.ipv4.udp_wmem_min = 16384
net.ipv4.tcp_max_tw_buckets = 1440000
net.ipv4.tcp_tw_recycle = 0
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_max_orphans = 400000
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_synack_retries = 1
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_fack = 1
net.ipv4.tcp_ecn = 2
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 60
net.ipv4.tcp_keepalive_probes = 10
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.ip_forward = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.all.rp_filter = 1
net.ipv4.ip_nonlocal_bind = 1
EOF

    # Áp dụng cấu hình
    if sysctl -p > /dev/null 2>&1; then
        echo -e "${GREEN}[+] Đã cấu hình sysctl tối ưu.${RESET}"
        echo -e "${YELLOW}[*] Backup gốc: /etc/sysctl.conf.bak${RESET}"
        echo -e "${BLUE}[*] Để khôi phục: mv /etc/sysctl.conf.bak /etc/sysctl.conf && sysctl -p${RESET}"
    else
        echo -e "${RED}[-] Có lỗi khi áp dụng sysctl. Kiểm tra lại cấu hình.${RESET}"
        echo -e "${YELLOW}[*] Có thể khôi phục: mv /etc/sysctl.conf.bak /etc/sysctl.conf${RESET}"
    fi
}

# ================== BẮT ĐẦU ==================
clear

# Phát hiện hệ điều hành
detect_os
echo

# Kiểm tra quyền root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}[-] Script này cần chạy với quyền root (sudo)${RESET}"
    exit 1
fi

show_limits

echo -e "${BLUE}[>>] Chọn hành động:${RESET}"
echo "  [1] Mở tối đa tuyệt đối (ulimit + sysctl)"
echo "  [2] Cấu hình tự động theo tài nguyên VPS (CPU, RAM)"
echo "  [3] Cấu hình sysctl tối ưu (network, kernel)"
echo "  [4] Kiểm tra số kết nối cổng 443"
echo "  [5] Khôi phục mặc định hệ thống"
read -rp "[>>] Nhập lựa chọn (1-5): " choice

case $choice in
    1) 
        max_out_limits
        echo
        read -rp "[?] Bạn có muốn cấu hình sysctl tối ưu luôn (y/n)? " sysctl_choice
        if [[ "$sysctl_choice" == "y" || "$sysctl_choice" == "Y" ]]; then
            configure_sysctl_optimized
        fi
        ;;
    2) 
        auto_configure_limits
        echo
        read -rp "[?] Bạn có muốn cấu hình sysctl tối ưu luôn (y/n)? " sysctl_choice
        if [[ "$sysctl_choice" == "y" || "$sysctl_choice" == "Y" ]]; then
            configure_sysctl_optimized
        fi
        ;;
    3) configure_sysctl_optimized ;;
    4) check_port_443 ;;
    5) reset_defaults ;;
    *) echo -e "${RED}Lựa chọn không hợp lệ!${RESET}" ;;
esac

# ================== HỎI KHỞI ĐỘNG LẠI ==================
if [ "$choice" != "4" ]; then
    echo
    read -rp "[?] Bạn có muốn khởi động lại hệ thống để áp dụng (y/n)? " reboot_choice
    if [[ "$reboot_choice" == "y" || "$reboot_choice" == "Y" ]]; then
        echo "[+] Đang khởi động lại..."
        reboot
    else
        echo "[*] Bạn có thể khởi động lại sau để đảm bảo cấu hình hoạt động đầy đủ."
    fi
fi