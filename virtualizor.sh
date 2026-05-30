#!/bin/bash
# ============================================================================
# VIRTUALIZOR.SH V3 - Host monitor + top VPS resource view
# Hien thi CPU, RAM, SWAP, Disk, Network cua host va top VPS con theo uu tien
# Su dung:
#   bash virtualizor.sh
#   bash virtualizor.sh --cpu --ram --disk --upload --download
#   bash virtualizor.sh --top 15 --ram --cpu
# ============================================================================

SCRIPT_VERSION="$(date +%Y.%m.%d).3"

RST='\e[0m'
BOLD='\e[1m'
DIM='\e[2m'
RED='\e[91m'
GREEN='\e[92m'
YELLOW='\e[93m'
BLUE='\e[94m'
MAGENTA='\e[95m'
CYAN='\e[96m'
WHITE='\e[97m'
GRAY='\e[90m'
ORANGE='\e[33m'

TOP_LIMIT=10
SORT_FIELDS=()
SHOW_VPS=1
REFRESH_SECONDS=2

while [ $# -gt 0 ]; do
    case "$1" in
        --top)
            if [ -n "$2" ] && echo "$2" | grep -Eq '^[0-9]+$'; then
                TOP_LIMIT="$2"
                shift
            fi
            ;;
        --cpu|cpu)
            SORT_FIELDS+=("cpu")
            ;;
        --ram|ram)
            SORT_FIELDS+=("ram")
            ;;
        --disk|disk)
            SORT_FIELDS+=("disk")
            ;;
        --upload|upload|--up|up)
            SORT_FIELDS+=("upload")
            ;;
        --download|download|--down|down)
            SORT_FIELDS+=("download")
            ;;
        --host-only)
            SHOW_VPS=0
            ;;
    esac
    shift
done

if [ ${#SORT_FIELDS[@]} -eq 0 ]; then
    SORT_FIELDS=("cpu" "ram" "disk")
fi

format_bytes() {
    local bytes=${1:-0}
    if [ "$bytes" -ge 1073741824 ] 2>/dev/null; then
        echo "$(awk "BEGIN {printf \"%.2f\", $bytes/1073741824}")GB/s"
    elif [ "$bytes" -ge 1048576 ] 2>/dev/null; then
        echo "$(awk "BEGIN {printf \"%.2f\", $bytes/1048576}")MB/s"
    elif [ "$bytes" -ge 1024 ] 2>/dev/null; then
        echo "$(awk "BEGIN {printf \"%.2f\", $bytes/1024}")KB/s"
    else
        echo "${bytes}B/s"
    fi
}

format_bits() {
    local bytes=${1:-0}
    local bits=$((bytes * 8))
    if [ "$bits" -ge 1000000000 ] 2>/dev/null; then
        echo "$(awk "BEGIN {printf \"%.2f\", $bits/1000000000}")Gb/s"
    elif [ "$bits" -ge 1000000 ] 2>/dev/null; then
        echo "$(awk "BEGIN {printf \"%.2f\", $bits/1000000}")Mb/s"
    elif [ "$bits" -ge 1000 ] 2>/dev/null; then
        echo "$(awk "BEGIN {printf \"%.2f\", $bits/1000}")Kb/s"
    else
        echo "${bits}b/s"
    fi
}

format_bytes_total() {
    local bytes=${1:-0}
    if [ "$bytes" -ge 1099511627776 ] 2>/dev/null; then
        echo "$(awk "BEGIN {printf \"%.2f\", $bytes/1099511627776}")TB"
    elif [ "$bytes" -ge 1073741824 ] 2>/dev/null; then
        echo "$(awk "BEGIN {printf \"%.2f\", $bytes/1073741824}")GB"
    elif [ "$bytes" -ge 1048576 ] 2>/dev/null; then
        echo "$(awk "BEGIN {printf \"%.2f\", $bytes/1048576}")MB"
    elif [ "$bytes" -ge 1024 ] 2>/dev/null; then
        echo "$(awk "BEGIN {printf \"%.2f\", $bytes/1024}")KB"
    else
        echo "${bytes}B"
    fi
}

format_kib_total() {
    local kib=${1:-0}
    local bytes=$((kib * 1024))
    format_bytes_total "$bytes"
}

get_net_info() {
    local iface=${1:-eth0}
    local net_line=$(grep "$iface:" /proc/net/dev 2>/dev/null | head -1)
    if [ -z "$net_line" ]; then
        net_line=$(grep -E "eth|ens|enp|venet|bond|br" /proc/net/dev 2>/dev/null | head -1)
        if [ -z "$net_line" ]; then
            echo "0 0"
            return
        fi
    fi
    local rx_bytes=$(echo "$net_line" | awk '{print $2}')
    local tx_bytes=$(echo "$net_line" | awk '{print $10}')
    echo "$rx_bytes $tx_bytes"
}

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

get_load_avg() {
    awk '{print $1, $2, $3}' /proc/loadavg
}

get_uptime() {
    local seconds=$(awk '{print int($1)}' /proc/uptime)
    local days=$((seconds / 86400))
    local hours=$(((seconds % 86400) / 3600))
    local minutes=$(((seconds % 3600) / 60))
    if [ "$days" -gt 0 ]; then
        echo "${days}d ${hours}h ${minutes}m"
    elif [ "$hours" -gt 0 ]; then
        echo "${hours}h ${minutes}m"
    else
        echo "${minutes}m"
    fi
}

get_process_count() {
    ps aux --no-heading 2>/dev/null | wc -l
}

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

get_primary_iface() {
    local iface=$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'dev \K[^ ]+' | head -1)
    [ -z "$iface" ] && iface="eth0"
    echo "$iface"
}

have_virsh() {
    command -v virsh >/dev/null 2>&1
}

get_vm_list() {
    if ! have_virsh; then
        return
    fi
    virsh list --name 2>/dev/null | sed '/^$/d'
}

get_vm_vcpu_count() {
    local vm="$1"
    virsh vcpucount "$vm" --current 2>/dev/null | awk '/current/ {print $3; exit}'
}

get_vm_netdev() {
    local vm="$1"
    virsh domiflist "$vm" 2>/dev/null | awk 'NR>2 && $1 != "" {print $1; exit}'
}

collect_vm_snapshot() {
    local outfile="$1"
    : > "$outfile"
    get_vm_list | while read -r vm; do
        [ -z "$vm" ] && continue
        local mem_kib=0
        local actual_kib=0
        local blk_kib=0
        local rx=0
        local tx=0
        local vcpus=1
        actual_kib=$(virsh dommemstat "$vm" 2>/dev/null | awk '/actual/ {print $2; exit}')
        mem_kib=$(virsh dommemstat "$vm" 2>/dev/null | awk '/rss/ {print $2; exit}')
        [ -z "$mem_kib" ] && mem_kib="$actual_kib"
        [ -z "$actual_kib" ] && actual_kib=0
        [ -z "$mem_kib" ] && mem_kib=0
        vcpus=$(get_vm_vcpu_count "$vm")
        [ -z "$vcpus" ] && vcpus=1
        while read -r target _; do
            [ -z "$target" ] && continue
            local cap alloc phy
            cap=$(virsh domblkinfo "$vm" "$target" 2>/dev/null | awk '/Capacity/ {print $2; exit}')
            alloc=$(virsh domblkinfo "$vm" "$target" 2>/dev/null | awk '/Allocation/ {print $2; exit}')
            phy=$(virsh domblkinfo "$vm" "$target" 2>/dev/null | awk '/Physical/ {print $2; exit}')
            if [ -n "$phy" ] && [ "$phy" -gt 0 ] 2>/dev/null; then
                blk_kib=$((blk_kib + phy / 1024))
            elif [ -n "$alloc" ] && [ "$alloc" -gt 0 ] 2>/dev/null; then
                blk_kib=$((blk_kib + alloc / 1024))
            elif [ -n "$cap" ] && [ "$cap" -gt 0 ] 2>/dev/null; then
                blk_kib=$((blk_kib + cap / 1024))
            fi
        done < <(virsh domblklist "$vm" --details 2>/dev/null | awk 'NR>2 && $3=="disk" {print $4}')
        local ifdev
        ifdev=$(get_vm_netdev "$vm")
        if [ -n "$ifdev" ] && [ -r "/sys/class/net/$ifdev/statistics/rx_bytes" ]; then
            rx=$(cat "/sys/class/net/$ifdev/statistics/rx_bytes" 2>/dev/null)
            tx=$(cat "/sys/class/net/$ifdev/statistics/tx_bytes" 2>/dev/null)
        fi
        echo "$vm|$vcpus|$mem_kib|$actual_kib|$blk_kib|$rx|$tx" >> "$outfile"
    done
}

print_vm_table() {
    local prev_file="$1"
    local curr_file="$2"
    [ ! -s "$curr_file" ] && return
    local sort_expr=""
    for f in "${SORT_FIELDS[@]}"; do
        case "$f" in
            cpu) sort_expr+=" -k2,2nr" ;;
            ram) sort_expr+=" -k3,3nr" ;;
            disk) sort_expr+=" -k4,4nr" ;;
            upload) sort_expr+=" -k5,5nr" ;;
            download) sort_expr+=" -k6,6nr" ;;
        esac
    done
    local merged
    merged=$(mktemp)
    awk -F'|' '
        FNR==NR { prev[$1]=$0; next }
        {
            name=$1; vcpus=$2+0; mem=$3+0; actual=$4+0; disk=$5+0; rx=$6+0; tx=$7+0;
            cpu=0; up=0; down=0;
            if (name in prev) {
                split(prev[name], p, "|");
                prx=p[6]+0; ptx=p[7]+0;
                if (rx >= prx) down=rx-prx;
                if (tx >= ptx) up=tx-ptx;
            }
            cpu=(vcpus>0)? int((up+down)/1048576) : 0;
            print name "|" cpu "|" mem "|" disk "|" up "|" down;
        }
    ' "$prev_file" "$curr_file" > "$merged"
    echo ""
    printf "${BOLD}${CYAN}+------------------------------------------------------------------------------------------------------------------+${RST}\n"
    printf "${BOLD}${CYAN}|${RST}${BOLD}${WHITE} %-110s ${RST}\n" "TOP ${TOP_LIMIT} VPS CON - Uu tien: ${SORT_FIELDS[*]}"
    printf "${BOLD}${CYAN}+------------------------------------------------------------------------------------------------------------------+${RST}\n"
    printf "${BOLD}${WHITE} %-24s %-8s %-14s %-14s %-16s %-16s${RST}\n" "VPS" "CPU*" "RAM RSS" "DISK" "UPLOAD" "DOWNLOAD"
    eval "sort -t'|' $sort_expr '$merged'" | head -n "$TOP_LIMIT" | \
    while IFS='|' read -r name cpu mem disk up down; do
        printf " %-24s %-8s %-14s %-14s %-16s %-16s\n" \
            "$name" "$cpu" "$(format_kib_total "$mem")" "$(format_kib_total "$disk")" "$(format_bytes $((up/REFRESH_SECONDS)))" "$(format_bytes $((down/REFRESH_SECONDS)))"
    done
    printf "${DIM}${GRAY} CPU* la chi so uu tien tam thoi duoc tinh tu luu luong I/O mang trong script nay. RAM/DISK/UPLOAD/DOWNLOAD la so lieu thuc te tu host.${RST}\n"
    rm -f "$merged"
}

trap 'printf "\n${GREEN}${BOLD}  [OK] Da thoat Virtualizor Monitor.${RST}\n"; tput cnorm 2>/dev/null; rm -f /tmp/virtualizor_prev_$$ /tmp/virtualizor_curr_$$; exit 0' INT TERM

tput civis 2>/dev/null
prev_rx=0
prev_tx=0
first_run=1
PRIMARY_IFACE=$(get_primary_iface)
PREV_VM_FILE="/tmp/virtualizor_prev_$$"
CURR_VM_FILE="/tmp/virtualizor_curr_$$"
: > "$PREV_VM_FILE"

while true; do
    clear
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
        dl_bytes=$((rx_bytes - prev_rx))
        ul_bytes=$((tx_bytes - prev_tx))
        [ "$dl_bytes" -lt 0 ] && dl_bytes=0
        [ "$ul_bytes" -lt 0 ] && ul_bytes=0
        dl_speed=$(format_bytes $((dl_bytes / REFRESH_SECONDS)))
        ul_speed=$(format_bytes $((ul_bytes / REFRESH_SECONDS)))
        ul_speed_bits=$(format_bits $((ul_bytes / REFRESH_SECONDS)))
        dl_speed_bits=$(format_bits $((dl_bytes / REFRESH_SECONDS)))
        dl_total=$(format_bytes_total $rx_bytes)
        ul_total=$(format_bytes_total $tx_bytes)
        prev_rx=$rx_bytes
        prev_tx=$tx_bytes
    fi

    echo ""
    printf "${BOLD}${CYAN}+--------------------------------------------------------------+${RST}\n"
    printf "${BOLD}${CYAN}|${RST}${BOLD}${WHITE}       >>> VIRTUALIZOR MONITOR v${SCRIPT_VERSION} - REALTIME <<<              ${RST}\n"
    printf "${BOLD}${CYAN}+--------------------------------------------------------------+${RST}\n"
    printf "${BOLD}${CYAN}|${RST}  ${GRAY}Host:${RST} ${BOLD}${WHITE}%-16s${RST} ${GRAY}IP:${RST} ${BOLD}${WHITE}%-15s${RST} ${GRAY}%s${RST}\n" "$hostname_str" "$ip_str" "$time_now"
    printf "${BOLD}${CYAN}+--------------------------------------------------------------+${RST}\n"
    echo ""
    draw_section "CPU" "$cpu_percent" "${cpu_cores} cores"
    draw_section "RAM" "$ram_percent" "${ram_used}MB / ${ram_total}MB (Free: ${ram_free}MB)"
    draw_section "PHSY" "$phys_percent" "${phys_used}MB / ${phys_total}MB (Free: ${phys_free}MB)"
    if [ "$swap_total" -gt 0 ]; then
        draw_section "SWAP" "$swap_percent" "${swap_used}MB / ${swap_total}MB (Free: ${swap_free}MB)"
    fi
    echo ""
    printf "  ${BOLD}${WHITE}%-8s${RST} " "NET"
    printf "${BLUE}Upload ${BOLD}↑${RST}: ${BLUE}%-24s${RST}" "$ul_speed ($ul_speed_bits)"
    printf "${GREEN}Download ${BOLD}↓${RST}: ${GREEN}%-24s${RST}\n" "$dl_speed ($dl_speed_bits)"
    printf "  ${GRAY}Iface: ${WHITE}%s${RST} ${GRAY}(Total ↑: %s  Total ↓: %s)${RST}\n" "$PRIMARY_IFACE" "$ul_total" "$dl_total"
    echo ""
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
    printf "${BOLD}${CYAN}+--------------------------------------------------------------+${RST}\n"
    printf "${BOLD}${CYAN}|${RST}  ${MAGENTA}Uptime:${RST} ${BOLD}${WHITE}%-10s${RST}" "$uptime_str"
    printf "  ${MAGENTA}Load:${RST} ${BOLD}${WHITE}%-18s${RST}" "$load_avg"
    printf "  ${MAGENTA}Procs:${RST} ${BOLD}${WHITE}%-5s${RST}\n" "$proc_count"
    printf "${BOLD}${CYAN}+--------------------------------------------------------------+${RST}\n"

    if [ "$SHOW_VPS" -eq 1 ] && have_virsh; then
        collect_vm_snapshot "$CURR_VM_FILE"
        if [ -s "$PREV_VM_FILE" ] && [ -s "$CURR_VM_FILE" ]; then
            print_vm_table "$PREV_VM_FILE" "$CURR_VM_FILE"
        fi
        cp "$CURR_VM_FILE" "$PREV_VM_FILE" 2>/dev/null
    fi

    printf "\n  ${DIM}${GRAY}Press ${WHITE}${BOLD}Ctrl+C${RST}${DIM}${GRAY} to exit  |  Refresh every ~%ss${RST}\n" "$REFRESH_SECONDS"
    sleep "$REFRESH_SECONDS"
done
