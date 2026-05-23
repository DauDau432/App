#!/bin/bash
# ============================================================================
# SYS_MONITOR.SH - Cong cu giam sat he thong thoi gian thuc
# Hien thi CPU, RAM (物理), SWAP (虛擬), Disk lien tuc voi giao dien mau sac
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

# --- Ham lay thong tin RAM (Vat ly) ---
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

# ============================================================================
# MAIN LOOP
# ============================================================================

trap 'printf "\n${GREEN}${BOLD}  [OK] Da thoat System Monitor.${RST}\n"; tput cnorm 2>/dev/null; exit 0' INT TERM

tput civis 2>/dev/null

while true; do
    clear

    # === Thu thap du lieu ===
    cpu_percent=$(get_cpu_usage)

    ram_info=($(get_ram_info))
    ram_percent=${ram_info[0]}
    ram_used=${ram_info[1]}
    ram_total=${ram_info[2]}
    ram_avail=${ram_info[3]}

    swap_info=($(get_swap_info))
    swap_percent=${swap_info[0]}
    swap_used=${swap_info[1]}
    swap_total=${swap_info[2]}
    swap_avail=${swap_info[3]}

    load_avg=$(get_load_avg)
    uptime_str=$(get_uptime)
    proc_count=$(get_process_count)
    hostname_str=$(hostname)
    ip_str=$(hostname -I 2>/dev/null | awk '{print $1}')
    time_now=$(date '+%Y-%m-%d %H:%M:%S')
    cpu_cores=$(nproc)

    # === Ve giao dien ===
    echo ""

    # --- HEADER ---
    printf "${BOLD}${CYAN}+--------------------------------------------------------------+${RST}\n"
    printf "${BOLD}${CYAN}|${RST}${BOLD}${WHITE}         >>> SYSTEM MONITOR - REALTIME <<<                    ${RST}${BOLD}${CYAN}|${RST}\n"
    printf "${BOLD}${CYAN}+--------------------------------------------------------------+${RST}\n"
    printf "${BOLD}${CYAN}|${RST}  ${GRAY}Host:${RST} ${BOLD}${WHITE}%-16s${RST} ${GRAY}IP:${RST} ${BOLD}${WHITE}%-15s${RST} ${GRAY}%s${RST} ${BOLD}${CYAN}|${RST}\n" "$hostname_str" "$ip_str" "$time_now"
    printf "${BOLD}${CYAN}+--------------------------------------------------------------+${RST}\n"

    echo ""

    # --- CPU ---
    draw_section "CPU" "$cpu_percent" "${cpu_cores} cores"

    # --- RAM Vat ly (Physical) ---
    draw_section "RAM" "$ram_percent" "${ram_used}MB / ${ram_total}MB (Free: ${ram_avail}MB)"

    # --- SWAP Ao (Virtual) ---
    if [ "$swap_total" -gt 0 ]; then
        draw_section "SWAP" "$swap_percent" "${swap_used}MB / ${swap_total}MB (Free: ${swap_avail}MB)"
    fi

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