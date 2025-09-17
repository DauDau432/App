#!/usr/bin/env python3
import os, time, glob, re, subprocess
from collections import defaultdict

LOG_DIR = "/www/wwwlogs"
INTERVAL_SEC = 2.0
POLL_SLEEP = 0.1
START_AT_END = True

def discover_logs():
    result = {}
    for path in glob.glob(os.path.join(LOG_DIR, "*.log")):
        base = os.path.basename(path)
        if "error" in base or base in ["access.log","access_log","error_log","nginx_error.log"]:
            continue
        domain = re.sub(r"\.log$", "", base)
        result[domain] = path
    return result

class TailFile:
    def __init__(self, path, start_at_end=True):
        self.path = path
        self.f = open(path, "r", encoding="utf-8", errors="replace")
        if start_at_end:
            self.f.seek(0, os.SEEK_END)
    def read_new(self):
        lines = self.f.readlines()
        return len(lines)

def clear():
    os.system("clear" if os.name != "nt" else "cls")

def get_netstat_info():
    cmds = {
        "Kết nối :80": "netstat -alntp | grep :80 | wc -l",
        "Kết nối :443": "netstat -alntp | grep :443 | wc -l",
        "ESTABLISHED": "netstat -tun | grep ESTABLISHED | wc -l",
        "SYN_RECV": "netstat -tunap | grep SYN_RECV | wc -l",
    }
    results = {}
    for k, cmd in cmds.items():
        try:
            out = subprocess.check_output(cmd, shell=True, text=True).strip()
            results[k] = int(out) if out.isdigit() else out
        except Exception as e:
            results[k] = f"ERR: {e}"
    return results

def main():
    logs = discover_logs()
    tails = {d: TailFile(p, START_AT_END) for d, p in logs.items()}
    while True:
        start = time.time()
        counts = defaultdict(int)
        while time.time() - start < INTERVAL_SEC:
            for d, t in tails.items():
                counts[d] += t.read_new()
            time.sleep(POLL_SLEEP)

        clear()

        # In netstat info
        netstat_info = get_netstat_info()
        print("Tình trạng kết nối (netstat):")
        for k, v in netstat_info.items():
            print(f"  {k:<15}: {v}")
        print("\nThống kê kết nối theo miền (real-time)\n")
        print(f"{'Domain':<28}{'RPS':>10}")
        print("-" * 40)

        rows = [(d, int(c/INTERVAL_SEC)) for d, c in counts.items()]
        for d, rps in sorted(rows, key=lambda x: x[1], reverse=True):
            print(f"{d:<28}{rps:>10}")

if __name__ == "__main__":
    main()
