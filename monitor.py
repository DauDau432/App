#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Universal HTTP access-log RPS monitor for Nginx / Apache / OpenLiteSpeed.
- Multi-dir discovery
- Multi-pattern matching
- Rotation-safe (inode check)
- Domain-aware counting (per-line for Apache other_vhosts_access.log)
- Works on diverse VPS layouts
"""

import os, sys, time, glob, re, subprocess
from collections import defaultdict, deque

# ======= Defaults (override via CLI) =======
CANDIDATE_DIRS = [
    "/www/wwwlogs",            # BaoTa/OLS thường dùng
    "/var/log/nginx",          # Nginx chuẩn
    "/var/log/apache2",        # Debian/Ubuntu Apache
    "/var/log/httpd",          # CentOS/RHEL Apache
    "/usr/local/lsws/logs",    # OpenLiteSpeed mặc định
]
INTERVAL_SEC = 2.0            # cửa sổ tính RPS
REDISCOVER_SEC = 10           # chu kỳ tái khám phá log
START_AT_END = True           # True: chỉ đếm từ sau thời điểm chạy
MAX_ROWS = 60                 # số dòng hiển thị
POLL_SLEEP = 0.1              # sleep ngắn trong vòng đo

# ======= Patterns =======
INCLUDE_GLOBS = [
    "*access.log*",            # nginx/apache
    "*access_log*",            # nginx/OLS/bao-ta
    "*_ols.access_log*",       # OLS chi tiết
    "other_vhosts_access.log*",# Apache gộp vhost
]
# Loại bỏ các log không phải access
EXCLUDE_REGEXES = [
    r"(?:^|/)(?:error|nginx_error)\.log",   # mọi error log
    r"(?:^|/)modsec.*\.log",                # mod_security
    r"(?:^|/)waf/",                         # thư mục waf
    r"(?:^|/)tcp-(?:access|error)\.log",    # tcp logs
    r"(?:^|/)access\.log$",                 # access.log quá generic (không domain), vẫn có thể bật lại
]

# Phát hiện domain từ tên file (Nginx/OLS thường mỗi vhost một file)
FILENAME_DOMAIN_RE = re.compile(
    r"""
    ^(?P<name>.+?)
    (?:
        (?:[_-]ols\.access_log(?:\.\d{4}_\d{2}_\d{2}(?:\.\d{2})?)?) |
        (?:[-_]access_log(?:\.\d{4}_\d{2}_\d{2}(?:\.\d{2})?)?) |
        (?:\.access\.log(?:\.\d+)?)
    )$
    """, re.VERBOSE
)

# Apache other_vhosts_access.log: domain nằm ở token đầu dòng (thường là %v)
APACHE_VHOST_LINE_DOMAIN_RE = re.compile(r"^\s*([A-Za-z0-9\.\-]+\.[A-Za-z]{2,})(?:\s|:)")

def parse_args():
    import argparse
    p = argparse.ArgumentParser(description="Universal RPS monitor (nginx/apache/OLS)")
    p.add_argument("--dir", action="append", help="Thêm thư mục chứa log (có thể dùng nhiều lần)")
    p.add_argument("--interval", type=float, default=INTERVAL_SEC, help="Khoảng đo RPS (giây)")
    p.add_argument("--rediscover", type=float, default=REDISCOVER_SEC, help="Chu kỳ tái khám phá log (giây)")
    p.add_argument("--show-zero", action="store_true", help="Hiện cả domain RPS=0")
    p.add_argument("--start-at-begin", action="store_true", help="Đọc từ đầu file (mặc định đọc từ cuối)")
    return p.parse_args()

def is_excluded(path: str) -> bool:
    p = path.replace("\\", "/")
    for rx in EXCLUDE_REGEXES:
        if re.search(rx, p, flags=re.IGNORECASE):
            return True
    return False

def discover_logs(dir_list):
    found = {}   # key: logical domain/fileKey, val: absolute path
    for d in dir_list:
        if not os.path.isdir(d):
            continue
        for pat in INCLUDE_GLOBS:
            for path in glob.glob(os.path.join(d, pat)):
                if not os.path.isfile(path) or is_excluded(path):
                    continue
                base = os.path.basename(path)
                # Ưu tiên phân loại:
                # 1) Apache other_vhosts_access.log -> key đặc biệt theo file
                if base.startswith("other_vhosts_access.log"):
                    key = "__apache_vhosts__:" + os.path.abspath(path)
                else:
                    # 2) Thử rút domain từ tên file (nginx/OLS)
                    m = FILENAME_DOMAIN_RE.match(base)
                    key = (m.group("name") if m else base) + ":" + os.path.abspath(path)
                # Giữ file mới hơn nếu trùng key logic
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
            # rotation nhất thời -> bỏ qua vòng này
            return
        if getattr(st, "st_ino", None) and st.st_ino != self.inode:
            # inode đổi -> reopen
            try:
                self.f.close()
            except Exception:
                pass
            self.f = open(self.path, "r", encoding="utf-8", errors="replace")
            self.inode = os.fstat(self.f.fileno()).st_ino
        else:
            # nếu truncate
            cur = self.f.tell()
            if st.st_size < cur:
                self.f.seek(0)

    def readlines(self):
        self._reopen_if_rotated()
        return self.f.readlines()

def clear_screen():
    os.system("clear" if os.name != "nt" else "cls")

def get_netstat_info():
    cmds = [
        ("Kết nối :80",   ["bash", "-lc", "netstat -alntp 2>/dev/null | grep :80 | wc -l"]),
        ("Kết nối :443",  ["bash", "-lc", "netstat -alntp 2>/dev/null | grep :443 | wc -l"]),
        ("ESTABLISHED",   ["bash", "-lc", "netstat -tun 2>/dev/null | grep ESTABLISHED | wc -l"]),
        ("SYN_RECV",      ["bash", "-lc", "netstat -tunap 2>/dev/null | grep SYN_RECV | wc -l"]),
    ]
    # Fallback sang ss nếu netstat không có
    fallback_cmds = [
        ("Kết nối :80",   ["bash", "-lc", "ss -lntp 2>/dev/null | grep :80 | wc -l"]),
        ("Kết nối :443",  ["bash", "-lc", "ss -lntp 2>/dev/null | grep :443 | wc -l"]),
        ("ESTABLISHED",   ["bash", "-lc", "ss -ant 2>/dev/null | grep ESTAB | wc -l"]),
        ("SYN_RECV",      ["bash", "-lc", "ss -ant 2>/dev/null | grep SYN-RECV | wc -l"]),
    ]
    res = {}
    try_first = True
    for (label, cmd), (_, fb) in zip(cmds, fallback_cmds):
        try:
            out = subprocess.check_output(cmd, text=True).strip()
            res[label] = int(out) if out.isdigit() else out
        except Exception:
            try_first = False
            try:
                out = subprocess.check_output(fb, text=True).strip()
                res[label] = int(out) if out.isdigit() else out
            except Exception as e2:
                res[label] = f"ERR: {e2}"
    return res

def extract_domain(line, key, is_apache_vhosts):
    """
    Trả về domain dùng để cộng dồn RPS.
    - is_apache_vhosts=True: cố gắng lấy token đầu (vhost).
    - Else: lấy domain theo tên file (key trước dấu ':').
    - Nếu trong dòng có host rõ ràng, có thể mở rộng regex ở đây.
    """
    if is_apache_vhosts:
        m = APACHE_VHOST_LINE_DOMAIN_RE.match(line)
        if m:
            return m.group(1).lower()
    # fallback: domain theo "file-derived"
    file_domain = key.split(":", 1)[0]
    return file_domain.lower()

def main():
    args = parse_args()
    dir_list = list(dict.fromkeys((args.dir or []) + CANDIDATE_DIRS))
    interval = args.interval
    rediscover = args.rediscover
    show_zero = args.show_zero
    start_at_end = not args.start_at_begin

    logs = discover_logs(dir_list)
    tails = {}
    for k, p in logs.items():
        try:
            tails[k] = TailFile(p, start_at_end)
        except Exception:
            pass

    last_rediscover = 0.0

    while True:
        t0 = time.time()
        counts = defaultdict(int)

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

        now = time.time()
        if now - last_rediscover >= rediscover:
            last_rediscover = now
            latest = discover_logs(dir_list)
            # Thêm file mới hoặc thay thế file rotated mới hơn
            for k, p in latest.items():
                if k not in tails or p != tails[k].path:
                    try:
                        tails[k] = TailFile(p, start_at_end)
                    except Exception:
                        pass

        clear_screen()
        # Netstat / ss
        netstat_info = get_netstat_info()
        print("Tình trạng kết nối (netstat/ss):")
        for k, v in netstat_info.items():
            print(f"  {k:<15}: {v}")

        print("\nThống kê kết nối theo miền (real-time)\n")
        print(f"{'Domain':<32}{'RPS':>8}")
        print("-" * 42)

        rows = [(d, counts.get(d, 0) / interval) for d in counts.keys()]
        if not show_zero:
            rows = [(d, r) for d, r in rows if r > 0.0]

        rows.sort(key=lambda x: x[1], reverse=True)
        shown = 0
        for d, r in rows:
            print(f"{(d[:30] + '…' if len(d) > 30 else d):<32}{r:>8.2f}")
            shown += 1
            if shown >= MAX_ROWS:
                break

        if shown == 0:
            print("(chưa ghi nhận request mới trong khoảng đo)")

        # Gợi ý nhanh các đường dẫn log đang theo dõi
        print("\nĐang theo dõi các file log:")
        for k, tf in list(tails.items())[:10]:
            print("  -", tf.path)
        if len(tails) > 10:
            print(f"  ... và {len(tails) - 10} file khác")

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
