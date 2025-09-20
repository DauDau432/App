#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Universal HTTP access-log RPS monitor (nginx / Apache / OpenLiteSpeed)

Mặc định:
  - In tổng quan kết nối hệ thống (netstat/ss)
  - In bảng miền (RPS theo domain) -> có thể tắt bằng --no-domains
Tùy chọn:
  - --topip [THRESHOLD] : hiện Top IP (dưới bảng miền). Nếu không truyền số: mặc định ngưỡng 5.
                          Luôn chỉ in tối đa 5 IP và chỉ những IP có kết nối > ngưỡng.
  - --logfile           : in danh sách file log đang theo dõi (cuối màn hình), loại trùng đường dẫn.
  - --dir PATH          : bổ sung thư mục log (có thể dùng nhiều lần)
  - --interval SEC      : khoảng đo RPS (mặc định 2s)
  - --rediscover SEC    : chu kỳ tái khám phá log (mặc định 10s)
  - --start-at-begin    : đọc log từ đầu (mặc định từ cuối)
  - --show-zero         : trong bảng miền, vẫn hiển thị domain RPS=0
  - --no-domains        : tắt hẳn bảng miền

Ghi chú:
  - Netstat không có: KHÔNG tự cài. Sẽ cảnh báo và dùng 'ss' thay thế.
"""

import os, sys, time, glob, re, subprocess, shutil
from collections import defaultdict

# ======= Defaults =======
CANDIDATE_DIRS = [
    "/www/wwwlogs",
    "/var/log/nginx",
    "/var/log/apache2",
    "/var/log/httpd",
    "/usr/local/lsws/logs",
]
INTERVAL_SEC = 2.0
REDISCOVER_SEC = 10
START_AT_END = True
MAX_ROWS = 60
POLL_SLEEP = 0.1

# ======= Patterns =======
INCLUDE_GLOBS = [
    "*access.log*",
    "*access_log*",
    "*_ols.access_log*",
    "other_vhosts_access.log*",
]
EXCLUDE_REGEXES = [
    r"(?:^|/)(?:error|nginx_error)\.log",
    r"(?:^|/)modsec.*\.log",
    r"(?:^|/)waf/",
    r"(?:^|/)tcp-(?:access|error)\.log",
    r"(?:^|/)access\.log$",
]

FILENAME_DOMAIN_RE = re.compile(
    r"""
    ^(?P<name>.+?)
    (?:
        (?:[_-]ols\.access_log(?:\.\d{4}_\d{2}_\d{2}(?:\.\d{2})?)?) |
        (?:[-_]access_log(?:\.\d{4}_\d{2}_\d{2}(?:\.\d{2})?)?) |
        (?:\.access\.log(?:\.\d+)?)
    )$
    """,
    re.VERBOSE
)
APACHE_VHOST_LINE_DOMAIN_RE = re.compile(r"^\s*([A-Za-z0-9\.\-]+\.[A-Za-z]{2,})(?:\s|:)")

def parse_args():
    import argparse
    p = argparse.ArgumentParser(description="Universal RPS monitor (nginx/apache/OLS)")
    p.add_argument("--dir", action="append", help="Thêm thư mục log (có thể lặp)")
    p.add_argument("--interval", type=float, default=INTERVAL_SEC, help="Khoảng đo RPS (giây)")
    p.add_argument("--rediscover", type=float, default=REDISCOVER_SEC, help="Chu kỳ tái khám phá log (giây)")
    p.add_argument("--start-at-begin", action="store_true", help="Đọc từ đầu file thay vì từ cuối")
    p.add_argument("--show-zero", action="store_true", help="Trong bảng miền, hiển thị cả domain RPS=0")
    # Domains: bật mặc định; có cờ tắt
    p.add_argument("--no-domains", action="store_true", help="Tắt bảng RPS theo miền (mặc định bật)")
    # Top IP: tùy chọn với ngưỡng (threshold) tùy ý; nếu không truyền -> ngưỡng 5
    p.add_argument("--topip", nargs="?", const="__DEFAULT__", help="Hiện Top IP; tùy chọn truyền ngưỡng (vd: --topip 20)")
    # Log file list
    p.add_argument("--logfile", action="store_true", help="In danh sách file log đang theo dõi (cuối màn hình)")
    return p.parse_args()

def is_excluded(path: str) -> bool:
    p = path.replace("\\", "/")
    for rx in EXCLUDE_REGEXES:
        if re.search(rx, p, flags=re.IGNORECASE):
            return True
    return False

def discover_logs(dir_list):
    found = {}
    for d in dir_list:
        if not os.path.isdir(d):
            continue
        for pat in INCLUDE_GLOBS:
            for path in glob.glob(os.path.join(d, pat)):
                if not os.path.isfile(path) or is_excluded(path):
                    continue
                base = os.path.basename(path)
                if base.startswith("other_vhosts_access.log"):
                    key = "__apache_vhosts__:" + os.path.abspath(path)
                else:
                    m = FILENAME_DOMAIN_RE.match(base)
                    key = (m.group("name") if m else base) + ":" + os.path.abspath(path)
                old = found.get(key)
                if not old or os.path.getmtime(path) > os.path.getmtime(old):
                    found[key] = path
    return found

class TailFile:
    def __init__(self, path, start_at_end=True):
        self.path = path
        self.f = open(path, "r", encoding="utf-8", errors="replace")
        self.inode = os.fstat(self.f.fileno()).st_ino
        if start_at_end:
            self.f.seek(0, os.SEEK_END)

    def _reopen_if_rotated(self):
        try:
            st = os.stat(self.path)
        except FileNotFoundError:
            return
        if getattr(st, "st_ino", None) and st.st_ino != self.inode:
            try:
                self.f.close()
            except Exception:
                pass
            self.f = open(self.path, "r", encoding="utf-8", errors="replace")
            self.inode = os.fstat(self.f.fileno()).st_ino
        else:
            cur = self.f.tell()
            if st.st_size < cur:
                self.f.seek(0)

    def readlines(self):
        self._reopen_if_rotated()
        return self.f.readlines()

def clear_screen():
    os.system("clear" if os.name != "nt" else "cls")

def sh(cmd):
    try:
        out = subprocess.check_output(cmd, shell=True, text=True, stderr=subprocess.DEVNULL)
        return out.strip("\n")
    except Exception:
        return ""

def have_netstat():
    return shutil.which("netstat") is not None

def get_net_overview():
    """Trả về dict + flag nguồn ('netstat' hoặc 'ss')."""
    src = "netstat" if have_netstat() else "ss"
    if src == "netstat":
        cmds = {
            "Kết nối :80":  "netstat -alntp 2>/dev/null | grep :80 | wc -l",
            "Kết nối :443": "netstat -alntp 2>/dev/null | grep :443 | wc -l",
            "ESTABLISHED":  "netstat -tun 2>/dev/null | grep ESTABLISHED | wc -l",
            "SYN_RECV":     "netstat -tunap 2>/dev/null | grep SYN_RECV | wc -l",
        }
    else:
        cmds = {
            "Kết nối :80":  "ss -lntp 2>/dev/null | grep :80 | wc -l",
            "Kết nối :443": "ss -lntp 2>/dev/null | grep :443 | wc -l",
            "ESTABLISHED":  "ss -ant 2>/dev/null | grep ESTAB | wc -l",
            "SYN_RECV":     "ss -ant 2>/dev/null | grep SYN-RECV | wc -l",
        }
    res = {}
    for k, cmd in cmds.items():
        val = sh(cmd)
        try:
            res[k] = int(val.strip())
        except:
            res[k] = val.strip() or "0"
    return res, src

def get_top_ips(threshold=5, limit=5):
    """Trả về dict[label] -> list dòng 'count ip', chỉ count > threshold, tối đa limit."""
    use_netstat = have_netstat()
    if use_netstat:
        groups = {
            "Top IP :80":  "netstat -anp 2>/dev/null | grep :80  | awk '{print $5}' | cut -d':' -f1 | sort | uniq -c | sort -nr",
            "Top IP :443": "netstat -anp 2>/dev/null | grep :443 | awk '{print $5}' | cut -d':' -f1 | sort | uniq -c | sort -nr",
            "Top IP ESTABLISHED": "netstat -tun 2>/dev/null | grep ESTABLISHED | awk '{print $5}' | cut -d: -f1 | sort | uniq -c | sort -nr",
        }
    else:
        groups = {
            "Top IP :80":  "ss -antp 2>/dev/null | grep ':80 '  | awk '{print $6}' | cut -d':' -f1 | sort | uniq -c | sort -nr",
            "Top IP :443": "ss -antp 2>/dev/null | grep ':443 ' | awk '{print $6}' | cut -d':' -f1 | sort | uniq -c | sort -nr",
            "Top IP ESTABLISHED": "ss -ant 2>/dev/null | grep ESTAB | awk '{print $6}' | cut -d':' -f1 | sort | uniq -c | sort -nr",
        }
    out = {}
    for label, cmd in groups.items():
        lines = [ln for ln in sh(cmd).splitlines() if ln.strip()]
        filtered = []
        for ln in lines:
            parts = ln.split()
            if len(parts) >= 2 and parts[0].isdigit():
                cnt = int(parts[0])
                if cnt > threshold:  # chỉ > ngưỡng như anh yêu cầu
                    filtered.append(ln)
            if len(filtered) >= limit:
                break
        out[label] = filtered
    return out

def extract_domain(line, key, is_apache_vhosts):
    if is_apache_vhosts:
        m = APACHE_VHOST_LINE_DOMAIN_RE.match(line)
        if m:
            return m.group(1).lower()
    file_domain = key.split(":", 1)[0]
    return file_domain.lower()

def main():
    args = parse_args()
    dir_list = list(dict.fromkeys((args.dir or []) + CANDIDATE_DIRS))
    interval = args.interval
    rediscover = args.rediscover
    start_at_end = not args.start_at_begin

    show_domains = not args.no_domains

    tails = {}
    if show_domains:
        logs = discover_logs(dir_list)
        for k, p in logs.items():
            try:
                tails[k] = TailFile(p, start_at_end)
            except Exception:
                pass
        last_rediscover = 0.0
    else:
        last_rediscover = None

    # Xử lý tham số --topip
    topip_enabled = args.topip is not None
    if args.topip == "__DEFAULT__":
        topip_threshold = 5
    elif args.topip is None:
        topip_threshold = None
    else:
        try:
            topip_threshold = int(args.topip)
        except Exception:
            topip_threshold = 5
    TOPIP_LIMIT = 5  # luôn in tối đa 5 IP

    while True:
        t0 = time.time()
        counts = defaultdict(int)

        if show_domains:
            while time.time() - t0 < interval:
                for key, tf in list(tails.items()):
                    try:
                        lines = tf.readlines()
                    except Exception:
                        continue
                    is_apache_vhosts = key.startswith("__apache_vhosts__:")
                    for ln in lines:
                        dom = extract_domain(ln, key, is_apache_vhosts)
                        counts[dom] += 1
                time.sleep(POLL_SLEEP)
        else:
            # không cần tail nhưng vẫn refresh theo nhịp
            remaining = interval - (time.time() - t0)
            if remaining > 0:
                time.sleep(remaining)

        if show_domains and last_rediscover is not None:
            now = time.time()
            if now - last_rediscover >= rediscover:
                last_rediscover = now
                latest = discover_logs(dir_list)
                for k, p in latest.items():
                    if k not in tails or p != tails[k].path:
                        try:
                            tails[k] = TailFile(p, start_at_end)
                        except Exception:
                            pass

        # ===== Render =====
        clear_screen()

        # 1) Tổng quan kết nối
        overview, src = get_net_overview()
        print("Tình trạng kết nối ({}):".format(src))
        for k, v in overview.items():
            print(f"  {k:<17}: {v}")
        if src == "ss":
            print("\n[Cảnh báo] Không tìm thấy 'netstat'. Đang dùng 'ss' thay thế.")
            print("  Gợi ý cài netstat (net-tools):")
            print("    Debian/Ubuntu:  sudo apt-get update -y && sudo apt-get install -y net-tools")
            print("    CentOS/RHEL:    sudo yum install -y net-tools  (hoặc dnf)")
            print("    openSUSE:       sudo zypper install -y net-tools")
            print("    Arch:           sudo pacman -Sy --noconfirm net-tools")
            print("    Alpine:         sudo apk add --no-cache net-tools")

        # 2) Bảng miền (mặc định bật)
        if show_domains:
            print("\nThống kê kết nối theo miền (real-time)\n")
            print(f"{'Domain':<32}{'RPS':>6}")
            print("-" * 40)
            rows = [(d, int(round(counts.get(d, 0) / interval))) for d in counts.keys()]
            if not args.show_zero:
                rows = [(d, r) for d, r in rows if r > 0]
            rows.sort(key=lambda x: x[1], reverse=True)
            shown = 0
            for d, r in rows:
                name = (d[:30] + "…") if len(d) > 30 else d
                print(f"{name:<32}{r:>6d}")
                shown += 1
                if shown >= MAX_ROWS:
                    break
            if shown == 0:
                print("(chưa ghi nhận request mới trong khoảng đo)")

        # 3) Top IP (chỉ khi gọi --topip) — hiển thị dưới bảng miền
        if topip_enabled:
            thr = topip_threshold if topip_threshold is not None else 5
            print(f"\nTop IP kết nối (ngưỡng > {thr}, tối đa {TOPIP_LIMIT} IP)")
            top = get_top_ips(threshold=thr, limit=TOPIP_LIMIT)
            def _print_top(label):
                print(f"\n{label}")
                print("-" * 40)
                lines = top.get(label, [])
                if not lines:
                    print("(không có dữ liệu đạt ngưỡng)")
                else:
                    for ln in lines:
                        print("  " + ln)
            _print_top("Top IP :80")
            _print_top("Top IP :443")
            _print_top("Top IP ESTABLISHED")

        # 4) Danh sách file log đang theo dõi (chỉ khi --logfile), cuối màn hình
        if show_domains and args.logfile:
            print("\nĐang theo dõi các file log (rút gọn):")
            seen = set()
            cnt = 0
            for _, tf in tails.items():
                p = os.path.abspath(tf.path)
                if p in seen:
                    continue
                seen.add(p)
                print("  -", p)
                cnt += 1
                if cnt >= 20:
                    break
            if len(seen) > cnt:
                print(f"  ... và {len(seen) - cnt} file khác")

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
