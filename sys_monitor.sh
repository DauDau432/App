#!/bin/bash
# ============================================================================
# SYS_MONITOR.SH V2 - Cải tiến thêm Network Upload/Download
# Hien thi CPU, RAM, SWAP, Disk, Network lien tuc voi giao dien mau sac
# Su dung: bash /root/sys_monitor.sh
# ============================================================================

# --- Mau sac ANSI (tuong thich moi terminal) ---
RST='\e[0m'
BOLD='\e[1m'
DIM='\e[2m'

# Mau chu
RED='\e[91m'
GREEN='\e[92m'
YELLOW='\e[93m'
BLUE='\e[94m'
MAGENTA='\e[95m'
CYAN='\e[96m'
WHITE='\e[97m'
GRAY='\e[90m'
ORANGE='\e[33m'

# --- Ham format bytes sang KB/MB/GB ---
format_bytes() {
    local bytes=$1
    if [ "$bytes" -ge 1073741824 ]; then  # >= 1GB
        echo "$(awk "BEGIN {printf \"%.2f\", $bytes/1073741824}")GB/s"
    elif [ "$bytes" -ge 1048576 ]; then   # >= 1MB
        echo "$(awk "BEGIN {printf \"%.2f\", $bytes/1048576}")MB/s"
    elif [ "$bytes" -ge 1024 ]; then       # >= 1KB
        echo "$(awk "BEGIN {printf \"%.2f\", $bytes/1024}")KB/s"
    else
        echo "${bytes}B/s"
    fi
}

# --- Ham format bytes không có đơn vị (cho tổng traffic) ---

format_bits() {
    local bytes=$1
    local bits=$((bytes * 8))
    if [ "$bits" -ge 1000000000 ]; then
        echo "$(awk "BEGIN {printf \"%.2f\", $bits/1000000000}")Gb/s"
    elif [ "$bits" -ge 1000000 ]; then
        echo "$(awk "BEGIN {printf \"%.2f\", $bits/1000000}")Mb/s"
    elif [ "$bits" -ge 1000 ]; then
        echo "$(awk "BEGIN {printf \"%.2f\", $bits/1000}")Kb/s"
    else
        echo "${bits}b/s"
    fi
}

format_bytes_total() {
    local bytes=$1
    if [ "$bytes" -ge 1073741824 ]; then  # >= 1GB
        echo "$(awk "BEGIN {printf \"%.2f\", $bytes/1073741824}")GB"
    elif [ "$bytes" -ge 1048576 ]; then   # >= 1MB
        echo "$(awk "BEGIN {printf \"%.2f\", $bytes/1048576}")MB"
    elif [ "$bytes" -ge 1024 ]; then       # >= 1KB
        echo "$(awk "BEGIN {printf \"%.2f\", $bytes/1024}")KB"
    else
        echo "${bytes}B"
    fi
}

# --- Ham lay thong tin Network (Upload/Download rate + total) ---
get_net_info() {
    local iface=${1:-eth0}
    # Đọc bytes từ /proc/net/dev (Interface: bytes rx, bytes tx)
    local net_line=$(grep "$iface:" /proc/net/dev 2>/dev/null | head -1)
    if [ -z "$net_line" ]; then
        # Thử các interface khác
        net_line=$(grep -E "eth|ens|enp|venet" /proc/net/dev 2>/dev/null | head -1)
        if [ -z "$net_line" ]; then
            echo "0 0 0 0"
            return
        fi
    fi
    
    # Parse: Interface: rx_bytes rx_packets ... tx_bytes tx_packets
    local rx_bytes=$(echo "$net_line" | awk '{print $2}')
    local tx_bytes=$(echo "$net_line" | awk '{print $10}')
    
    echo "$rx_bytes $tx_bytes"
}

# --- Ham lay % CPU ---
get_cpu_usage() {
    local cpu1=($(head -1 /proc/stat))
    local idle1=${cpu1[4]}
    local total1=0
    for val in "${cpu1[@]:1}"; do total1=$((total1 + val)); done

    sleep 0.5

    local cpu2=($(head -1 /proc/stat))
    local idle2=${cpu2[4]}
    local total2=0
    for val in "${cpu2[@]:1}"; do total2=$((total2 + val)); done

    local diff_idle=$((idle2 - idle1))
    local diff_total=$((total2 - total1))

    if [ "$diff_total" -gt 0 ]; then
        echo $(( (diff_total - diff_idle) * 100 / diff_total ))
    else
        echo 0
    fi
}

# --- Ham lay thong tin RAM (Available, bao gom cache) ---
get_ram_info() {
    local mem_total=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    local mem_available=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
    local mem_used=$((mem_total - mem_available))
    local mem_percent=$((mem_used * 100 / mem_total))
    local total_mb=$((mem_total / 1024))
    local used_mb=$((mem_used / 1024))
    local avail_mb=$((mem_available / 1024))
    echo "${mem_percent} ${used_mb} ${total_mb} ${avail_mb}"
}

# --- Ham lay thong tin RAM Vat ly (MemFree, khong tinh cache) ---
get_phys_info() {
    local mem_total=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    local mem_free=$(awk '/MemFree/ {print $2}' /proc/meminfo)
    local mem_used=$((mem_total - mem_free))
    local mem_percent=$((mem_used * 100 / mem_total))
    local total_mb=$((mem_total / 1024))
    local used_mb=$((mem_used / 1024))
    local free_mb=$((mem_free / 1024))
    echo "${mem_percent} ${used_mb} ${total_mb} ${free_mb}"
}

# --- Ham lay thong tin SWAP (Ao) ---
get_swap_info() {
    local swap_total=$(awk '/SwapTotal/ {print $2}' /proc/meminfo)
    local swap_free=$(awk '/SwapFree/ {print $2}' /proc/meminfo)
    if [ "$swap_total" -gt 0 ]; then
        local swap_used=$((swap_total - swap_free))
        local swap_percent=$((swap_used * 100 / swap_total))
        local total_mb=$((swap_total / 1024))
        local used_mb=$((swap_used / 1024))
        local free_mb=$((swap_free / 1024))
        echo "${swap_percent} ${used_mb} ${total_mb} ${free_mb}"
    else
        echo "0 0 0 0"
    fi
}

# --- Ham lay Load Average ---
get_load_avg() {
    cat /proc/loadavg | awk '{print $1, $2, $3}'
}

# --- Ham lay Uptime ---
get_uptime() {
    local seconds=$(awk '{print int($1)}' /proc/uptime)
    local days=$((seconds / 86400))
    local hours=$(( (seconds % 86400) / 3600 ))
    local minutes=$(( (seconds % 3600) / 60 ))
    if [ "$days" -gt 0 ]; then
        echo "${days}d ${hours}h ${minutes}m"
    elif [ "$hours" -gt 0 ]; then
        echo "${hours}h ${minutes}m"
    else
        echo "${minutes}m"
    fi
}

# --- Ham lay so luong process ---
get_process_count() {
    ps aux --no-heading 2>/dev/null | wc -l
}

# --- Chon mau theo % ---
color_by_pct() {
    local pct=$1
    if [ "$pct" -lt 50 ]; then
        printf "${GREEN}"
    elif [ "$pct" -lt 75 ]; then
        printf "${YELLOW}"
    elif [ "$pct" -lt 90 ]; then
        printf "${ORANGE}"
    else
        printf "${RED}"
    fi
}

# --- Ham ve thanh progress bar (ASCII) ---
draw_bar() {
    local percent=$1
    local width=40
    local filled=$(( percent * width / 100 ))
    local empty=$(( width - filled ))
    local bar_color=""

    if [ "$percent" -lt 50 ]; then
        bar_color="${GREEN}"
    elif [ "$percent" -lt 75 ]; then
        bar_color="${YELLOW}"
    elif [ "$percent" -lt 90 ]; then
        bar_color="${ORANGE}"
    else
        bar_color="${RED}"
    fi

    printf "["
    printf "${bar_color}${BOLD}"
    for ((i=0; i<filled; i++)); do printf "#"; done
    printf "${RST}${DIM}${GRAY}"
    for ((i=0; i<empty; i++)); do printf "-"; done
    printf "${RST}]"
}

# --- Ham ve 1 dong thong so ---
draw_section() {
    local label=$1
    local percent=$2
    local detail=$3

    printf "  ${BOLD}${WHITE}%-8s${RST} " "$label"
    draw_bar "$percent"
    printf " ${BOLD}"
    color_by_pct "$percent"
    printf "%3d%%${RST}" "$percent"
    printf "  ${GRAY}%s${RST}\n" "$detail"
}

# --- Ham lay primary network interface ---
get_primary_iface() {
    local iface=$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'dev \K[^ ]+' | head -1)
    if [ -z "$iface" ]; then
        iface="eth0"
    fi
    echo "$iface"
}

# ============================================================================
# MAIN LOOP
# ============================================================================

trap 'printf "\n${GREEN}${BOLD}  [OK] Da thoat System Monitor.${RST}\n"; tput cnorm 2>/dev/null; exit 0' INT TERM

tput civis 2>/dev/null

# Biến lưu bytes trước đó
prev_rx=0
prev_tx=0
first_run=1

# Xác định interface
PRIMARY_IFACE=$(get_primary_iface)

while true; do
    clear

    # === Thu thap du lieu ===
    cpu_percent=$(get_cpu_usage)

    ram_info=($(get_ram_info))
    ram_percent=${ram_info[0]}
    ram_used=${ram_info[1]}
    ram_total=${ram_info[2]}
    ram_free=${ram_info[3]}

    phys_info=($(get_phys_info))
    phys_percent=${phys_info[0]}
    phys_used=${phys_info[1]}
    phys_total=${phys_info[2]}
    phys_free=${phys_info[3]}

    swap_info=($(get_swap_info))
    swap_percent=${swap_info[0]}
    swap_used=${swap_info[1]}
    swap_total=${swap_info[2]}
    swap_free=${swap_info[3]}

    load_avg=$(get_load_avg)
    uptime_str=$(get_uptime)
    proc_count=$(get_process_count)
    hostname_str=$(hostname)
    ip_str=$(hostname -I 2>/dev/null | awk '{print $1}')
    time_now=$(date '+%Y-%m-%d %H:%M:%S')
    cpu_cores=$(nproc)

    # === Network Stats ===
    net_info=($(get_net_info "$PRIMARY_IFACE"))
    rx_bytes=${net_info[0]}
    tx_bytes=${net_info[1]}

    if [ "$first_run" -eq 1 ]; then
        prev_rx=$rx_bytes
        prev_tx=$tx_bytes
        first_run=0
        dl_speed="0B/s"
        ul_speed="0B/s"
        dl_speed_bits="0b/s"
        ul_speed_bits="0b/s"
        dl_total="0B"
        ul_total="0B"
    else
        # Tính delta (bytes trong ~2 giây)
        dl_bytes=$((rx_bytes - prev_rx))
        ul_bytes=$((tx_bytes - prev_tx))
        
        # Chuyển bytes/s (delta / 2 giây interval)
        dl_speed=$(format_bytes $((dl_bytes / 2)))
        ul_speed=$(format_bytes $((ul_bytes / 2)))
        ul_speed_bits=$(format_bits $((ul_bytes / 2)))
        dl_speed_bits=$(format_bits $((dl_bytes / 2)))
        
        # Tổng traffic
        dl_total=$(format_bytes_total $rx_bytes)
        ul_total=$(format_bytes_total $tx_bytes)
        
        prev_rx=$rx_bytes
        prev_tx=$tx_bytes
        
        # Tránh giá trị âm khi reset
        [ "$dl_speed" = "0.00B/s" ] && dl_speed="0B/s"
        [ "$ul_speed" = "0.00B/s" ] && ul_speed="0B/s"
    fi

    # === Ve giao dien ===
    echo ""

    # --- HEADER ---
    printf "${BOLD}${CYAN}+--------------------------------------------------------------+${RST}\n"
    printf "${BOLD}${CYAN}|${RST}${BOLD}${WHITE}         >>> SYSTEM MONITOR V2 - REALTIME <<<                   ${RST}${BOLD}${CYAN}|${RST}\n"
    printf "${BOLD}${CYAN}+--------------------------------------------------------------+${RST}\n"
    printf "${BOLD}${CYAN}|${RST}  ${GRAY}Host:${RST} ${BOLD}${WHITE}%-16s${RST} ${GRAY}IP:${RST} ${BOLD}${WHITE}%-15s${RST} ${GRAY}%s${RST} ${BOLD}${CYAN}|${RST}\n" "$hostname_str" "$ip_str" "$time_now"
    printf "${BOLD}${CYAN}+--------------------------------------------------------------+${RST}\n"

    echo ""

    # --- CPU ---
    draw_section "CPU" "$cpu_percent" "${cpu_cores} cores"

    # --- RAM (Available, bao gom cache) ---
    draw_section "RAM" "$ram_percent" "${ram_used}MB / ${ram_total}MB (Free: ${ram_free}MB)"

    # --- RAM Vat ly (Physical, khong tinh cache) ---
    draw_section "PHSY" "$phys_percent" "${phys_used}MB / ${phys_total}MB (Free: ${phys_free}MB)"

    # --- SWAP Ao (Virtual) ---
    if [ "$swap_total" -gt 0 ]; then
        draw_section "SWAP" "$swap_percent" "${swap_used}MB / ${swap_total}MB (Free: ${swap_free}MB)"
    fi

    echo ""

    # --- NETWORK ---
    printf "  ${BOLD}${WHITE}%-8s${RST} " "NET"
    printf "  ${BLUE}${BOLD}↑${RST} ${BLUE}%-24s${RST}" "UL: $ul_speed ($ul_speed_bits)"
    printf "  ${GREEN}${BOLD}↓${RST} ${GREEN}%-24s${RST}" "DL: $dl_speed ($dl_speed_bits)"
    printf "  ${GRAY}(%s | %s)${RST}\n" "Total ↑: $ul_total" "Total ↓: $dl_total"

    echo ""

    # --- DISK ---
    printf "  ${BOLD}${WHITE}DISK PARTITIONS:${RST}\n"

    disk_data=$(df -h --output=target,size,used,avail,pcent -x tmpfs -x devtmpfs -x overlay 2>/dev/null | tail -n +2)

    while IFS= read -r line; do
        mount=$(echo "$line" | awk '{print $1}')
        size=$(echo "$line" | awk '{print $2}')
        used=$(echo "$line" | awk '{print $3}')
        avail=$(echo "$line" | awk '{print $4}')
        pcent=$(echo "$line" | awk '{print $5}' | tr -d '%')

        if [ -n "$pcent" ] && [ "$pcent" -eq "$pcent" ] 2>/dev/null; then
            printf "     ${GRAY}%-22s${RST} " "$mount"
            draw_bar "$pcent"
            printf " ${BOLD}"
            color_by_pct "$pcent"
            printf "%3d%%${RST}" "$pcent"
            printf "  ${GRAY}%s / %s (Free: %s)${RST}\n" "$used" "$size" "$avail"
        fi
    done <<< "$disk_data"

    echo ""

    # --- FOOTER ---
    printf "${BOLD}${CYAN}+--------------------------------------------------------------+${RST}\n"
    printf "${BOLD}${CYAN}|${RST}  ${MAGENTA}Uptime:${RST} ${BOLD}${WHITE}%-10s${RST}" "$uptime_str"
    printf "  ${MAGENTA}Load:${RST} ${BOLD}${WHITE}%-18s${RST}" "$load_avg"
    printf "  ${MAGENTA}Procs:${RST} ${BOLD}${WHITE}%-5s${RST}" "$proc_count"
    printf "${BOLD}${CYAN}|${RST}\n"
    printf "${BOLD}${CYAN}+--------------------------------------------------------------+${RST}\n"

    printf "\n  ${DIM}${GRAY}Press ${WHITE}${BOLD}Ctrl+C${RST}${DIM}${GRAY} to exit  |  Refresh every ~2s${RST}\n"

    sleep 1.5
done
