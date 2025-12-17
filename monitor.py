#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Universal HTTP access-log RPS monitor
Hỗ trợ: aaPanel, Nginx, Apache, LiteSpeed, OpenLiteSpeed, CyberPanel, DirectAdmin, cPanel

Mặc định:
  - In tổng quan kết nối hệ thống (đọc trực tiếp /proc/net hoặc ss)
  - In bảng miền (RPS theo domain) -> có thể tắt bằng --no-domains
Tùy chọn:
  - --topip [THRESHOLD] : hiện Top IP (dưới bảng miền). Mặc định ngưỡng 5.
  - --logfile           : in danh sách file log đang theo dõi
  - --dir PATH          : bổ sung thư mục log (có thể dùng nhiều lần)
  - --interval SEC      : khoảng đo RPS (mặc định 2s)
  - --rediscover SEC    : chu kỳ tái khám phá log (mặc định 10s)
  - --start-at-begin    : đọc log từ đầu (mặc định từ cuối)
  - --show-zero         : hiển thị domain RPS=0
  - --no-domains        : tắt bảng miền

Tối ưu:
  - Đọc trực tiếp /proc/net/* (không cần netstat/ss)
  - Pre-compiled regex patterns
  - Thread pool cho I/O operations
  - Tương thích mọi Linux distro

Hỗ trợ Control Panel:
  - aaPanel (BT Panel)
  - cPanel/WHM
  - DirectAdmin
  - CyberPanel
  - Plesk
  - VestaCP/HestiaCP

Hỗ trợ Web Server:
  - Nginx
  - Apache (httpd)
  - LiteSpeed Enterprise
  - OpenLiteSpeed
  - Caddy
"""

from __future__ import annotations
import os
import sys
import time
import glob
import re
import argparse
from collections import defaultdict
from typing import Dict, List, Optional, Tuple, Set
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass

# ======= Defaults =======
# Danh sách thư mục log theo Control Panel và Web Server
CANDIDATE_DIRS: List[str] = [
    # ========== aaPanel (BT Panel) ==========
    "/www/wwwlogs",                          # aaPanel main logs
    "/www/server/nginx/logs",                # aaPanel Nginx logs
    "/www/server/apache/logs",               # aaPanel Apache logs
    "/www/server/panel/logs",                # aaPanel panel logs

    # ========== Nginx ==========
    "/var/log/nginx",                        # Default Nginx (Ubuntu/Debian/CentOS)
    "/usr/local/nginx/logs",                 # Compiled Nginx
    "/opt/nginx/logs",                       # Custom Nginx

    # ========== Apache/httpd ==========
    "/var/log/apache2",                      # Apache Ubuntu/Debian
    "/var/log/httpd",                        # Apache CentOS/RHEL/Fedora
    "/usr/local/apache/logs",                # cPanel Apache
    "/usr/local/apache2/logs",               # Compiled Apache
    "/var/log/apache",                       # Some distros
    "/opt/apache/logs",                      # Custom Apache

    # ========== LiteSpeed Enterprise ==========
    "/usr/local/lsws/logs",                  # LiteSpeed main logs
    "/usr/local/lsws/admin/logs",            # LiteSpeed admin logs

    # ========== OpenLiteSpeed ==========
    "/usr/local/lsws/logs",                  # OpenLiteSpeed logs (same as LS)
    "/var/log/openlitespeed",                # OpenLiteSpeed alternative

    # ========== CyberPanel ==========
    "/home/*/logs",                          # CyberPanel per-user logs
    "/usr/local/CyberCP/logs",               # CyberPanel main logs
    "/home/cyberpanel/logs",                 # CyberPanel system logs

    # ========== cPanel/WHM ==========
    "/usr/local/cpanel/logs",                # cPanel main logs
    "/var/log/apache2/domlogs",              # cPanel domain logs (Debian)
    "/usr/local/apache/domlogs",             # cPanel domain logs
    "/home/*/access-logs",                   # cPanel per-user access logs
    "/home/*/logs",                          # cPanel per-user logs
    "/var/cpanel/logs",                      # cPanel system logs

    # ========== DirectAdmin ==========
    "/var/log/directadmin",                  # DirectAdmin main logs
    "/var/log/httpd/domains",                # DirectAdmin domain logs
    "/home/*/domains/*/logs",                # DirectAdmin per-domain logs
    "/var/www/html/*/logs",                  # DirectAdmin alternative

    # ========== Plesk ==========
    "/var/www/vhosts/*/logs",                # Plesk domain logs
    "/var/log/plesk",                        # Plesk main logs
    "/var/log/sw-cp-server",                 # Plesk panel logs
    "/var/www/vhosts/system/*/logs",         # Plesk system domain logs

    # ========== VestaCP / HestiaCP ==========
    "/var/log/vesta",                        # VestaCP logs
    "/var/log/hestia",                       # HestiaCP logs
    "/home/*/web/*/logs",                    # VestaCP/HestiaCP per-domain logs

    # ========== Caddy ==========
    "/var/log/caddy",                        # Caddy logs

    # ========== CloudPanel ==========
    "/home/*/htdocs/*/logs",                 # CloudPanel logs
    "/var/log/cloudpanel",                   # CloudPanel system logs

    # ========== General/Fallback ==========
    "/var/log",                              # General system logs (filtered)
    "/home/*/public_html/logs",              # Generic per-user logs
]

INTERVAL_SEC: float = 2.0
REDISCOVER_SEC: int = 10
MAX_ROWS: int = 60
POLL_SLEEP: float = 0.1
THREAD_POOL_SIZE: int = 4

# ======= Pre-compiled Patterns =======
# Patterns để tìm file log access
INCLUDE_GLOBS: Tuple[str, ...] = (
    # Nginx patterns
    "*access.log*",
    "*-access.log*",
    "*_access.log*",
    "access.log.*",

    # Apache patterns
    "*access_log*",
    "*-access_log*",
    "access_log.*",
    "other_vhosts_access.log*",
    "*-ssl_access_log*",

    # LiteSpeed/OpenLiteSpeed patterns
    "*_ols.access_log*",
    "*lsws*.log*",

    # cPanel patterns
    "*-bytes_log*",

    # DirectAdmin patterns
    "*.log",

    # General patterns
    "*http*.log*",
    "*https*.log*",
)

# Pre-compile exclude patterns for performance
_EXCLUDE_PATTERNS: Tuple[re.Pattern, ...] = (
    # Error logs
    re.compile(r"(?:^|/)(?:error|nginx_error|apache_error)\.log", re.IGNORECASE),
    re.compile(r"(?:^|/)error[_-]log", re.IGNORECASE),
    re.compile(r"(?:^|/).*error.*\.log$", re.IGNORECASE),

    # Security/WAF logs
    re.compile(r"(?:^|/)modsec.*\.log", re.IGNORECASE),
    re.compile(r"(?:^|/)waf/", re.IGNORECASE),
    re.compile(r"(?:^|/)security.*\.log", re.IGNORECASE),

    # System logs
    re.compile(r"(?:^|/)tcp-(?:access|error)\.log", re.IGNORECASE),
    re.compile(r"(?:^|/)ssl_error", re.IGNORECASE),
    re.compile(r"(?:^|/)suexec\.log", re.IGNORECASE),
    re.compile(r"(?:^|/)php[-_]?fpm.*\.log", re.IGNORECASE),

    # Exclude generic access.log without domain prefix (usually system log)
    re.compile(r"(?:^|/)access\.log$", re.IGNORECASE),

    # Rotated/archived logs (quá cũ)
    re.compile(r"\.gz$", re.IGNORECASE),
    re.compile(r"\.bz2$", re.IGNORECASE),
    re.compile(r"\.xz$", re.IGNORECASE),
    re.compile(r"\.zip$", re.IGNORECASE),
    re.compile(r"\.\d{8}$"),  # date suffix like .20240101
)

# Regex để extract domain từ tên file
FILENAME_DOMAIN_RE: re.Pattern = re.compile(
    r"""
    ^(?P<name>.+?)
    (?:
        # OpenLiteSpeed format: domain_ols.access_log.2024_01_01
        (?:[_-]ols\.access_log(?:\.\d{4}_\d{2}_\d{2}(?:\.\d{2})?)?) |
        # Apache/Nginx format: domain-access_log or domain_access_log
        (?:[-_]access_log(?:\.\d{4}_\d{2}_\d{2}(?:\.\d{2})?)?) |
        # Standard format: domain.access.log.1
        (?:\.access\.log(?:\.\d+)?) |
        # cPanel format: domain-ssl_log
        (?:[-_]ssl_log(?:\.\d+)?) |
        # Simple format: domain.log
        (?:\.log(?:\.\d+)?) |
        # DirectAdmin format: domain.access.log
        (?:\.access\.log$) |
        # Hyphenated: domain-access.log
        (?:-access\.log(?:\.\d+)?)
    )$
    """,
    re.VERBOSE
)

# Regex để extract domain từ dòng log Apache vhost
APACHE_VHOST_LINE_DOMAIN_RE: re.Pattern = re.compile(
    r"^\s*([A-Za-z0-9.\-]+\.[A-Za-z]{2,})(?:\s|:)"
)

# Regex để extract domain từ các format log phổ biến
LOG_LINE_DOMAIN_PATTERNS: Tuple[re.Pattern, ...] = (
    # Combined log format với vhost: "domain.com 192.168.1.1 - - [date] ..."
    re.compile(r'^([A-Za-z0-9][-A-Za-z0-9.]*\.[A-Za-z]{2,})\s+\d'),
    # Nginx với $host: domain.com - 192.168.1.1
    re.compile(r'^([A-Za-z0-9][-A-Za-z0-9.]*\.[A-Za-z]{2,})\s*[-–]\s*\d'),
)

# TCP connection states mapping
TCP_STATES: Dict[str, str] = {
    "01": "ESTABLISHED",
    "02": "SYN_SENT",
    "03": "SYN_RECV",
    "04": "FIN_WAIT1",
    "05": "FIN_WAIT2",
    "06": "TIME_WAIT",
    "07": "CLOSE",
    "08": "CLOSE_WAIT",
    "09": "LAST_ACK",
    "0A": "LISTEN",
    "0B": "CLOSING",
}

@dataclass
class ConnectionStats:
    """Data class for connection statistics."""
    port_80: int = 0
    port_443: int = 0
    established: int = 0
    syn_recv: int = 0
    source: str = "/proc"


@dataclass
class IPCount:
    """Data class for IP connection counts."""
    ip: str
    count: int


def parse_args() -> argparse.Namespace:
    """Parse command line arguments."""
    p = argparse.ArgumentParser(
        description="Universal RPS monitor (nginx/apache/OLS) - Optimized",
        formatter_class=argparse.RawDescriptionHelpFormatter
    )
    p.add_argument("--dir", action="append", help="Thêm thư mục log (có thể lặp)")
    p.add_argument("--interval", type=float, default=INTERVAL_SEC, help="Khoảng đo RPS (giây)")
    p.add_argument("--rediscover", type=float, default=REDISCOVER_SEC, help="Chu kỳ tái khám phá log (giây)")
    p.add_argument("--start-at-begin", action="store_true", help="Đọc từ đầu file thay vì từ cuối")
    p.add_argument("--show-zero", action="store_true", help="Hiển thị cả domain RPS=0")
    p.add_argument("--no-domains", action="store_true", help="Tắt bảng RPS theo miền")
    p.add_argument("--topip", nargs="?", const=5, type=int, help="Hiện Top IP; tùy chọn truyền ngưỡng (vd: --topip 20)")
    p.add_argument("--logfile", action="store_true", help="In danh sách file log đang theo dõi")
    return p.parse_args()


def is_excluded(path: str) -> bool:
    """Check if path should be excluded using pre-compiled patterns."""
    normalized = path.replace("\\", "/")
    return any(pattern.search(normalized) for pattern in _EXCLUDE_PATTERNS)


def expand_directory_globs(dir_list: List[str]) -> List[str]:
    """
    Expand directory paths containing wildcards.
    Ví dụ: /home/*/logs -> /home/user1/logs, /home/user2/logs, ...
    """
    expanded = []
    for d in dir_list:
        if '*' in d:
            # Expand glob pattern
            matches = glob.glob(d)
            for match in matches:
                if os.path.isdir(match):
                    expanded.append(match)
        else:
            expanded.append(d)
    return list(dict.fromkeys(expanded))  # Remove duplicates while preserving order


def discover_logs(dir_list: List[str]) -> Dict[str, str]:
    """
    Discover log files in given directories.
    Hỗ trợ tất cả control panels và webservers phổ biến.
    """
    found: Dict[str, str] = {}

    # Expand any glob patterns in directory paths
    expanded_dirs = expand_directory_globs(dir_list)

    for d in expanded_dirs:
        if not os.path.isdir(d):
            continue

        for pat in INCLUDE_GLOBS:
            try:
                for path in glob.glob(os.path.join(d, pat)):
                    if not os.path.isfile(path) or is_excluded(path):
                        continue

                    # Skip files that are too old (> 1 day since last modified)
                    try:
                        mtime = os.path.getmtime(path)
                        if time.time() - mtime > 86400:  # 24 hours
                            continue
                    except OSError:
                        continue

                    base = os.path.basename(path)
                    abs_path = os.path.abspath(path)

                    # Determine domain/key from filename
                    if base.startswith("other_vhosts_access.log"):
                        key = f"__apache_vhosts__:{abs_path}"
                    else:
                        # Try to extract domain from filename
                        m = FILENAME_DOMAIN_RE.match(base)
                        if m:
                            name = m.group("name")
                        else:
                            # Fallback: try to get domain from parent directory
                            parent = os.path.basename(os.path.dirname(path))
                            if parent and '.' in parent and len(parent) > 3:
                                name = parent
                            else:
                                name = base.replace('.log', '').replace('_log', '').replace('-log', '')

                        key = f"{name}:{abs_path}"

                    # Keep the most recently modified file for each domain
                    old = found.get(key)
                    if not old:
                        found[key] = path
                    else:
                        try:
                            if os.path.getmtime(path) > os.path.getmtime(old):
                                found[key] = path
                        except OSError:
                            pass
            except (OSError, PermissionError):
                # Skip directories we can't access
                continue

    return found


class TailFile:
    """Efficient file tailer with rotation detection."""

    __slots__ = ('path', '_file', '_inode')

    def __init__(self, path: str, start_at_end: bool = True):
        self.path = path
        self._file = open(path, "r", encoding="utf-8", errors="replace")
        self._inode = self._get_inode()
        if start_at_end:
            self._file.seek(0, os.SEEK_END)

    def _get_inode(self) -> int:
        """Get file inode."""
        return os.fstat(self._file.fileno()).st_ino

    def _reopen_if_rotated(self) -> None:
        """Reopen file if it has been rotated."""
        try:
            st = os.stat(self.path)
        except FileNotFoundError:
            return

        current_inode = getattr(st, "st_ino", None)
        if current_inode and current_inode != self._inode:
            self._close_safe()
            self._file = open(self.path, "r", encoding="utf-8", errors="replace")
            self._inode = self._get_inode()
        elif st.st_size < self._file.tell():
            self._file.seek(0)

    def _close_safe(self) -> None:
        """Safely close file handle."""
        try:
            self._file.close()
        except Exception:
            pass

    def readlines(self) -> List[str]:
        """Read new lines from file."""
        self._reopen_if_rotated()
        return self._file.readlines()

    def close(self) -> None:
        """Close file handle."""
        self._close_safe()

    def __enter__(self) -> 'TailFile':
        return self

    def __exit__(self, *_args) -> None:
        self.close()


class NetworkMonitor:
    """
    Network connection monitor using /proc/net for maximum compatibility.
    Falls back to ss/netstat if /proc is not available.
    """

    def __init__(self):
        self._use_proc = os.path.exists("/proc/net/tcp")
        self._executor = ThreadPoolExecutor(max_workers=THREAD_POOL_SIZE)

    @staticmethod
    def _hex_to_ip(hex_ip: str) -> str:
        """Convert hex IP address to dotted decimal."""
        try:
            # Handle IPv4
            if len(hex_ip) == 8:
                return ".".join(str(int(hex_ip[i:i+2], 16)) for i in (6, 4, 2, 0))
            # Handle IPv6 mapped IPv4
            elif len(hex_ip) == 32 and hex_ip[:24] == "0000000000000000FFFF0000":
                ipv4_hex = hex_ip[24:]
                return ".".join(str(int(ipv4_hex[i:i+2], 16)) for i in (6, 4, 2, 0))
            return hex_ip
        except (ValueError, IndexError):
            return hex_ip

    @staticmethod
    def _hex_to_port(hex_port: str) -> int:
        """Convert hex port to integer."""
        try:
            return int(hex_port, 16)
        except ValueError:
            return 0

    def _parse_proc_net(self, filepath: str) -> List[Tuple[str, int, str, int, str]]:
        """
        Parse /proc/net/tcp or /proc/net/tcp6.
        Returns list of (local_ip, local_port, remote_ip, remote_port, state).
        """
        connections = []
        try:
            with open(filepath, "r") as f:
                next(f)  # Skip header
                for line in f:
                    parts = line.split()
                    if len(parts) < 4:
                        continue

                    local_addr = parts[1].split(":")
                    remote_addr = parts[2].split(":")
                    state = parts[3]

                    local_ip = self._hex_to_ip(local_addr[0])
                    local_port = self._hex_to_port(local_addr[1])
                    remote_ip = self._hex_to_ip(remote_addr[0])
                    remote_port = self._hex_to_port(remote_addr[1])
                    state_name = TCP_STATES.get(state, "UNKNOWN")

                    connections.append((local_ip, local_port, remote_ip, remote_port, state_name))
        except (IOError, OSError, PermissionError):
            pass

        return connections

    def get_all_connections(self) -> List[Tuple[str, int, str, int, str]]:
        """Get all TCP connections from /proc/net/tcp and tcp6."""
        connections = []

        if self._use_proc:
            # Read IPv4 and IPv6 connections in parallel
            futures = []
            for filepath in ("/proc/net/tcp", "/proc/net/tcp6"):
                if os.path.exists(filepath):
                    futures.append(self._executor.submit(self._parse_proc_net, filepath))

            for future in as_completed(futures):
                try:
                    connections.extend(future.result())
                except Exception:
                    pass

        return connections

    def get_stats(self) -> ConnectionStats:
        """Get connection statistics."""
        stats = ConnectionStats()

        if self._use_proc:
            connections = self.get_all_connections()
            stats.source = "/proc"

            for _, local_port, _, remote_port, state in connections:
                # Count connections to port 80/443
                if local_port == 80 or remote_port == 80:
                    stats.port_80 += 1
                if local_port == 443 or remote_port == 443:
                    stats.port_443 += 1

                # Count by state
                if state == "ESTABLISHED":
                    stats.established += 1
                elif state == "SYN_RECV":
                    stats.syn_recv += 1
        else:
            # Fallback to ss (available on all modern Linux)
            stats.source = "ss"
            stats.port_80 = self._count_ss_output("ss -ant sport = :80 or dport = :80 2>/dev/null | wc -l")
            stats.port_443 = self._count_ss_output("ss -ant sport = :443 or dport = :443 2>/dev/null | wc -l")
            stats.established = self._count_ss_output("ss -ant state established 2>/dev/null | wc -l")
            stats.syn_recv = self._count_ss_output("ss -ant state syn-recv 2>/dev/null | wc -l")

        return stats

    @staticmethod
    def _count_ss_output(cmd: str) -> int:
        """Execute ss command and return count."""
        try:
            import subprocess
            result = subprocess.run(
                cmd, shell=True, capture_output=True, text=True, timeout=5
            )
            count = int(result.stdout.strip()) - 1  # Subtract header line
            return max(0, count)
        except Exception:
            return 0

    def get_top_ips(self, threshold: int = 5, limit: int = 5) -> Dict[str, List[IPCount]]:
        """Get top IPs by connection count."""
        result: Dict[str, List[IPCount]] = {
            "Top IP :80": [],
            "Top IP :443": [],
            "Top IP ESTABLISHED": [],
        }

        if self._use_proc:
            connections = self.get_all_connections()

            # Count IPs by category
            ip_counts_80: Dict[str, int] = defaultdict(int)
            ip_counts_443: Dict[str, int] = defaultdict(int)
            ip_counts_established: Dict[str, int] = defaultdict(int)

            for _, local_port, remote_ip, remote_port, state in connections:
                # Skip invalid/local IPs
                if remote_ip in ("0.0.0.0", "127.0.0.1", "", "::1"):
                    continue

                if local_port == 80 or remote_port == 80:
                    ip_counts_80[remote_ip] += 1
                if local_port == 443 or remote_port == 443:
                    ip_counts_443[remote_ip] += 1
                if state == "ESTABLISHED":
                    ip_counts_established[remote_ip] += 1

            # Sort and filter
            for label, counts in [
                ("Top IP :80", ip_counts_80),
                ("Top IP :443", ip_counts_443),
                ("Top IP ESTABLISHED", ip_counts_established),
            ]:
                sorted_ips = sorted(counts.items(), key=lambda x: x[1], reverse=True)
                for ip, count in sorted_ips[:limit]:
                    if count > threshold:
                        result[label].append(IPCount(ip=ip, count=count))
        else:
            # Fallback to ss
            result = self._get_top_ips_ss(threshold, limit)

        return result

    def _get_top_ips_ss(self, threshold: int, limit: int) -> Dict[str, List[IPCount]]:
        """Get top IPs using ss command."""
        import subprocess

        result: Dict[str, List[IPCount]] = {
            "Top IP :80": [],
            "Top IP :443": [],
            "Top IP ESTABLISHED": [],
        }

        commands = {
            "Top IP :80": "ss -ant '( sport = :80 or dport = :80 )' 2>/dev/null | awk 'NR>1 {print $5}' | cut -d':' -f1 | sort | uniq -c | sort -rn",
            "Top IP :443": "ss -ant '( sport = :443 or dport = :443 )' 2>/dev/null | awk 'NR>1 {print $5}' | cut -d':' -f1 | sort | uniq -c | sort -rn",
            "Top IP ESTABLISHED": "ss -ant state established 2>/dev/null | awk 'NR>1 {print $4}' | cut -d':' -f1 | sort | uniq -c | sort -rn",
        }

        for label, cmd in commands.items():
            try:
                proc = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=5)
                for line in proc.stdout.strip().split("\n")[:limit]:
                    parts = line.split()
                    if len(parts) >= 2 and parts[0].isdigit():
                        count = int(parts[0])
                        ip = parts[1]
                        if count > threshold and ip not in ("0.0.0.0", "127.0.0.1", "*"):
                            result[label].append(IPCount(ip=ip, count=count))
            except Exception:
                pass

        return result

    def shutdown(self) -> None:
        """Shutdown thread pool."""
        self._executor.shutdown(wait=False)


def extract_domain(line: str, key: str, is_apache_vhosts: bool) -> str:
    """
    Extract domain from log line.
    Hỗ trợ nhiều định dạng log từ các webserver khác nhau.
    """
    # Apache combined vhost format: domain.com IP - - [date] ...
    if is_apache_vhosts:
        m = APACHE_VHOST_LINE_DOMAIN_RE.match(line)
        if m:
            return m.group(1).lower()

    # Try to extract domain from log line using various patterns
    for pattern in LOG_LINE_DOMAIN_PATTERNS:
        m = pattern.match(line)
        if m:
            return m.group(1).lower()

    # Fallback: extract domain from key (filename-based)
    file_domain = key.split(":", 1)[0]

    # Clean up common suffixes
    file_domain = file_domain.lower()
    for suffix in ('_ssl', '-ssl', '_http', '-http', '_https', '-https'):
        if file_domain.endswith(suffix):
            file_domain = file_domain[:-len(suffix)]
            break

    return file_domain


def clear_screen() -> None:
    """Clear terminal screen."""
    os.system("clear" if os.name != "nt" else "cls")


def print_banner() -> None:
    """Print application banner."""
    print("=" * 60)
    print("  Universal HTTP Access Log Monitor")
    print("  Hỗ trợ: aaPanel, Nginx, Apache, LiteSpeed, OpenLiteSpeed")
    print("          cPanel, DirectAdmin, CyberPanel, Plesk, VestaCP")
    print("=" * 60)

def main() -> None:
    """Main entry point."""
    args = parse_args()
    dir_list = list(dict.fromkeys((args.dir or []) + CANDIDATE_DIRS))
    interval = args.interval
    rediscover = args.rediscover
    start_at_end = not args.start_at_begin
    show_domains = not args.no_domains

    # Initialize network monitor
    net_monitor = NetworkMonitor()

    # Initialize log tails
    tails: Dict[str, TailFile] = {}
    last_rediscover: Optional[float] = None

    if show_domains:
        logs = discover_logs(dir_list)
        for k, p in logs.items():
            try:
                tails[k] = TailFile(p, start_at_end)
            except Exception:
                pass
        last_rediscover = 0.0

    # Process --topip argument
    topip_enabled = args.topip is not None
    topip_threshold = args.topip if args.topip is not None else 5
    TOPIP_LIMIT = 5

    try:
        while True:
            t0 = time.time()
            counts: Dict[str, int] = defaultdict(int)

            if show_domains:
                # Read log files during interval
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
                # Just wait for interval
                remaining = interval - (time.time() - t0)
                if remaining > 0:
                    time.sleep(remaining)

            # Rediscover log files periodically
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

            # 1) Connection overview
            stats = net_monitor.get_stats()
            print(f"Tình trạng kết nối ({stats.source}):")
            print(f"  {'Kết nối :80':<17}: {stats.port_80}")
            print(f"  {'Kết nối :443':<17}: {stats.port_443}")
            print(f"  {'ESTABLISHED':<17}: {stats.established}")
            print(f"  {'SYN_RECV':<17}: {stats.syn_recv}")

            # 2) Domain table
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

            # 3) Top IPs
            if topip_enabled:
                print(f"\nTop IP kết nối (ngưỡng > {topip_threshold}, tối đa {TOPIP_LIMIT} IP)")
                top_ips = net_monitor.get_top_ips(threshold=topip_threshold, limit=TOPIP_LIMIT)

                for label in ("Top IP :80", "Top IP :443", "Top IP ESTABLISHED"):
                    print(f"\n{label}")
                    print("-" * 40)
                    ip_list = top_ips.get(label, [])
                    if not ip_list:
                        print("(không có dữ liệu đạt ngưỡng)")
                    else:
                        for ip_count in ip_list:
                            print(f"  {ip_count.count:>6}  {ip_count.ip}")

            # 4) Log file list
            if show_domains and args.logfile:
                print("\nĐang theo dõi các file log (rút gọn):")
                seen: Set[str] = set()
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

    finally:
        # Cleanup
        net_monitor.shutdown()
        for tf in tails.values():
            tf.close()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\n\nĐã dừng monitor.")
        sys.exit(0)
