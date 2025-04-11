#!/bin/bash

# ================== MÀU SẮC ==================
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
BLUE="\033[1;34m"
RESET="\033[0m"

# ================== HÀM: THÔNG TIN HIỆN TẠI ==================
show_limits() {
    echo -e "${BLUE}[>>] Thông tin hệ thống hiện tại:${RESET}"
    echo -e "[*] ulimit -n (nofile):        $(ulimit -n)"
    echo -e "[*] ulimit -u (nproc):         $(ulimit -u)"
    echo -e "[*] kernel.pid_max:            $(cat /proc/sys/kernel/pid_max)"
    echo
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

    # Sửa systemd
    mkdir -p /etc/systemd/system.conf.d
    cat <<EOF > /etc/systemd/system.conf.d/ulimit.conf
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=4194303
EOF

    # Sửa PAM
    if ! grep -q "pam_limits.so" /etc/pam.d/common-session 2>/dev/null; then
        echo "session required pam_limits.so" >> /etc/pam.d/common-session
    fi
    if ! grep -q "pam_limits.so" /etc/pam.d/sshd 2>/dev/null; then
        echo "session required pam_limits.so" >> /etc/pam.d/sshd
    fi

    # Sửa SSH
    sed -i 's/^#UsePAM no/UsePAM yes/' /etc/ssh/sshd_config
    sed -i 's/^UsePAM no/UsePAM yes/' /etc/ssh/sshd_config

    # Tăng pid_max nếu cần
    sysctl -w kernel.pid_max=4194303
    grep -q "kernel.pid_max" /etc/sysctl.conf || echo "kernel.pid_max = 4194303" >> /etc/sysctl.conf

    # Override SSH systemd service
    mkdir -p /etc/systemd/system/ssh.service.d
    cat <<EOF > /etc/systemd/system/ssh.service.d/override.conf
[Service]
LimitNOFILE=1048576
LimitNPROC=4194303
EOF

    # Thêm vào ~/.bashrc nếu chưa có
    if ! grep -q "ulimit -n 1048576" ~/.bashrc; then
        echo "ulimit -n 1048576" >> ~/.bashrc
        echo -e "${YELLOW}[+] Đã thêm 'ulimit -n 1048576' vào ~/.bashrc${RESET}"
    fi

    # Reload systemd & SSH
    systemctl daemon-reexec
    systemctl daemon-reload
    systemctl restart ssh

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

    # Giống như max_out nhưng giá trị thay đổi
    sed -i '/nofile/d;/nproc/d' /etc/security/limits.conf
    cat <<EOF >> /etc/security/limits.conf
* soft nofile $nofile
* hard nofile $nofile
* soft nproc $nproc
* hard nproc $nproc
EOF

    mkdir -p /etc/systemd/system.conf.d
    cat <<EOF > /etc/systemd/system.conf.d/ulimit.conf
[Manager]
DefaultLimitNOFILE=$nofile
DefaultLimitNPROC=$nproc
EOF

    sysctl -w kernel.pid_max=4194303
    grep -q "kernel.pid_max" /etc/sysctl.conf || echo "kernel.pid_max = 4194303" >> /etc/sysctl.conf

    mkdir -p /etc/systemd/system/ssh.service.d
    cat <<EOF > /etc/systemd/system/ssh.service.d/override.conf
[Service]
LimitNOFILE=$nofile
LimitNPROC=$nproc
EOF

    if ! grep -q "ulimit -n $nofile" ~/.bashrc; then
        echo "ulimit -n $nofile" >> ~/.bashrc
        echo -e "${YELLOW}[+] Đã thêm 'ulimit -n $nofile' vào ~/.bashrc${RESET}"
    fi

    systemctl daemon-reexec
    systemctl daemon-reload
    systemctl restart ssh

    echo -e "${GREEN}[+] Hoàn tất cấu hình tự động.${RESET}"
}

# ================== HÀM: KHÔI PHỤC MẶC ĐỊNH ==================
reset_defaults() {
    echo -e "${YELLOW}[-] Đang khôi phục mặc định...${RESET}"
    sed -i '/nofile/d;/nproc/d' /etc/security/limits.conf
    rm -f /etc/systemd/system.conf.d/ulimit.conf
    rm -f /etc/systemd/system/ssh.service.d/override.conf
    sed -i '/pam_limits.so/d' /etc/pam.d/common-session 2>/dev/null
    sed -i '/pam_limits.so/d' /etc/pam.d/sshd 2>/dev/null
    sed -i 's/^UsePAM yes/#UsePAM no/' /etc/ssh/sshd_config

    sed -i '/ulimit -n/d' ~/.bashrc

    sysctl -w kernel.pid_max=32768
    sed -i '/kernel.pid_max/d' /etc/sysctl.conf

    systemctl daemon-reexec
    systemctl daemon-reload
    systemctl restart ssh

    echo -e "${GREEN}[-] Đã khôi phục mặc định hệ thống.${RESET}"
}

# ================== BẮT ĐẦU ==================
clear
show_limits

echo -e "${BLUE}[>>] Chọn hành động:${RESET}"
echo "  [1] Mở tối đa tuyệt đối"
echo "  [2] Cấu hình tự động theo tài nguyên VPS (CPU, RAM)"
echo "  [3] Khôi phục mặc định hệ thống"
read -rp "[>>] Nhập lựa chọn (1, 2 hoặc 3): " choice

case $choice in
    1) max_out_limits ;;
    2) auto_configure_limits ;;
    3) reset_defaults ;;
    *) echo "Lựa chọn không hợp lệ!" ;;
esac

# ================== HỎI KHỞI ĐỘNG LẠI ==================
echo
read -rp "[?] Bạn có muốn khởi động lại hệ thống để áp dụng (y/n)? " reboot_choice
if [[ "$reboot_choice" == "y" || "$reboot_choice" == "Y" ]]; then
    echo "[+] Đang khởi động lại..."
    reboot
else
    echo "[*] Bạn có thể khởi động lại sau để đảm bảo cấu hình hoạt động đầy đủ."
fi
