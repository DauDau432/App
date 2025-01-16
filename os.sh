#!/bin/bash

# Kiểm tra phiên bản hệ điều hành và in ra thông tin chi tiết
clear
echo "=== Kiểm tra phiên bản hệ điều hành ==="

if [ -f /etc/redhat-release ]; then
    # Dành cho CentOS, RHEL
    echo "Thông tin từ /etc/redhat-release:"
    cat /etc/redhat-release
elif [ -f /etc/centos-release ]; then
    # Dành cho CentOS
    echo "Thông tin từ /etc/centos-release:"
    cat /etc/centos-release
elif [ -f /etc/os-release ]; then
    # Dành cho Ubuntu, Debian và các bản Linux khác
    echo "Thông tin từ /etc/os-release:"
    grep -E '^PRETTY_NAME=' /etc/os-release | cut -d= -f2 | tr -d \"
elif command -v lsb_release >/dev/null 2>&1; then
    # Dành cho hệ thống có lệnh lsb_release
    echo "Thông tin từ lsb_release:"
    lsb_release -d | cut -f2
else
    # Nếu không tìm được thông tin
    echo "Không thể xác định phiên bản hệ điều hành."
fi
