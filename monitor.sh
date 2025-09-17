#!/bin/bash

LOG_DIR="/www/wwwlogs"
INTERVAL=2

declare -A last_count

while true; do
    clear

    # In netstat info
    echo "Tình trạng kết nối (netstat):"
    echo "  Kết nối :80       : $(netstat -alntp 2>/dev/null | grep :80 | wc -l)"
    echo "  Kết nối :443      : $(netstat -alntp 2>/dev/null | grep :443 | wc -l)"
    echo "  ESTABLISHED       : $(netstat -tun 2>/dev/null | grep ESTABLISHED | wc -l)"
    echo "  SYN_RECV          : $(netstat -tunap 2>/dev/null | grep SYN_RECV | wc -l)"
    echo

    echo "Thống kê kết nối theo miền (real-time)"
    printf "%-28s %10s\n" "Domain" "RPS"
    echo "----------------------------------------------"

    results=()

    for f in "$LOG_DIR"/*.log; do
        base=$(basename "$f")
        # bỏ qua file error
        [[ "$base" == *error* ]] && continue
        [[ "$base" == "access.log" ]] && continue
        [[ "$base" == "access_log" ]] && continue
        [[ "$base" == "error_log" ]] && continue
        [[ "$base" == "nginx_error.log" ]] && continue

        domain="${base%.log}"
        total=$(wc -l < "$f")
        prev=${last_count[$domain]:-0}
        diff=$(( total - prev ))
        rps=$(( diff / INTERVAL ))
        last_count[$domain]=$total

        results+=("$rps $domain")
    done

    # sort theo RPS giảm dần
    for line in $(printf "%s\n" "${results[@]}" | sort -nrk1); do
        rps=$(echo "$line" | awk '{print $1}')
        domain=$(echo "$line" | cut -d' ' -f2-)
        printf "%-28s %10d\n" "$domain" "$rps"
    done

    sleep $INTERVAL
done
