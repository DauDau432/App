#!/bin/bash

# Màu sắc
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

function print_current_limits() {
    echo -e "${YELLOW}[>>] Thông tin hệ thống hiện tại:${NC}"
    echo -e "[*] ulimit -n (nofile):        $(ulimit -n)"
    echo -e "[*] ulimit -u (nproc):         $(ulimit -u)"
    echo -e "[*] kernel.pid_max:            $(cat /proc/sys/kernel/pid_max)"
    echo
}

function ask_reboot() {
    echo
    read -p "[>>] Bạn có muốn khởi động lại ngay? (y/n): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        echo -e "${YELLOW}[>>] Đang khởi động lại hệ thống...${NC}"
        reboot
    else
        echo -e "${GREEN}[+] Bạn đã chọn KHÔNG khởi động lại. Hãy nhớ reboot sau nếu cần.${NC}"
    fi
}

function increase_limits_max() {
    echo -e "${GREEN}[+] Đang tăng giới hạn lên tối đa tuyệt đối...${NC}"

    sysctl -w kernel.pid_max=4194303
    sed -i '/kernel.pid_max/d' /etc/sysctl.conf
    echo "kernel.pid_max = 4194303" >> /etc/sysctl.conf

    LIMITS_FILE="/etc/security/limits.conf"
    sed -i '/nofile/d' $LIMITS_FILE
    sed -i '/nproc/d' $LIMITS_FILE

    cat <<EOF >> $LIMITS_FILE
* soft nofile 1048576
* hard nofile 1048576
* soft nproc 4194303
* hard nproc 4194303
EOF

    PAM_FILE="/etc/pam.d/common-session"
    grep -q pam_limits.so $PAM_FILE || echo "session required pam_limits.so" >> $PAM_FILE 2>/dev/null

    mkdir -p /etc/systemd/system.conf.d
    cat <<EOF > /etc/systemd/system.conf.d/ulimit.conf
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=4194303
EOF

    sysctl -p >/dev/null
    echo -e "${GREEN}[+] Đã áp dụng cấu hình tối đa.${NC}"
    ask_reboot
}

function auto_config_limits() {
    echo -e "${YELLOW}[>>] Đang tính toán cấu hình tự động theo tài nguyên VPS...${NC}"

    TOTAL_RAM_GB=$(awk '/MemTotal/ {printf "%.0f", $2 / 1024 / 1024}' /proc/meminfo)
    TOTAL_RAM_MB=$(awk '/MemTotal/ {printf "%.0f", $2 / 1024}' /proc/meminfo)
    CPU_CORES=$(nproc)

    NOFILE=$((TOTAL_RAM_GB * 16384))
    NPROC=$((TOTAL_RAM_MB * 2))
    PID_MAX=$((NPROC * 3 / 2))
    [ "$PID_MAX" -gt 4194303 ] && PID_MAX=4194303

    echo -e "[*] RAM: ${TOTAL_RAM_GB} GB"
    echo -e "[*] CPU: ${CPU_CORES} cores"
    echo -e "[*] Sẽ đặt: nofile = ${NOFILE}, nproc = ${NPROC}, pid_max = ${PID_MAX}"
    echo

    sysctl -w kernel.pid_max=$PID_MAX
    sed -i '/kernel.pid_max/d' /etc/sysctl.conf
    echo "kernel.pid_max = $PID_MAX" >> /etc/sysctl.conf

    LIMITS_FILE="/etc/security/limits.conf"
    sed -i '/nofile/d' $LIMITS_FILE
    sed -i '/nproc/d' $LIMITS_FILE

    cat <<EOF >> $LIMITS_FILE
* soft nofile $NOFILE
* hard nofile $NOFILE
* soft nproc $NPROC
* hard nproc $NPROC
EOF

    PAM_FILE="/etc/pam.d/common-session"
    grep -q pam_limits.so $PAM_FILE || echo "session required pam_limits.so" >> $PAM_FILE 2>/dev/null

    mkdir -p /etc/systemd/system.conf.d
    cat <<EOF > /etc/systemd/system.conf.d/ulimit.conf
[Manager]
DefaultLimitNOFILE=$NOFILE
DefaultLimitNPROC=$NPROC
EOF

    sysctl -p >/dev/null
    echo -e "${GREEN}[+] Đã cấu hình theo tài nguyên VPS.${NC}"
    ask_reboot
}

function reset_defaults() {
    echo -e "${RED}[-] Đang khôi phục giới hạn về mặc định hệ thống...${NC}"

    sysctl -w kernel.pid_max=32768
    sed -i '/kernel.pid_max/d' /etc/sysctl.conf
    echo "kernel.pid_max = 32768" >> /etc/sysctl.conf

    sed -i '/nofile/d' /etc/security/limits.conf
    sed -i '/nproc/d' /etc/security/limits.conf

    sed -i '/pam_limits.so/d' /etc/pam.d/common-session 2>/dev/null

    rm -f /etc/systemd/system.conf.d/ulimit.conf

    sysctl -p >/dev/null

    echo -e "${RED}[-] Đã khôi phục về mặc định.${NC}"
    ask_reboot
}

# === MAIN ===

clear
print_current_limits

echo -e "${YELLOW}[>>] Chọn hành động:${NC}"
echo "  [1] Mở tối đa tuyệt đối"
echo "  [2] Cấu hình tự động theo tài nguyên VPS (CPU, RAM)"
echo "  [3] Khôi phục mặc định hệ thống"
read -p "[>>] Nhập lựa chọn (1, 2 hoặc 3): " choice

case $choice in
    1) increase_limits_max ;;
    2) auto_config_limits ;;
    3) reset_defaults ;;
    *) echo -e "${RED}[!!] Lựa chọn không hợp lệ.${NC}" ;;
esac
