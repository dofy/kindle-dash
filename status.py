#!/usr/bin/env python3
"""Build the JSON for the system-status page.

Runs on the OpenWrt router, so it sticks to the standard library and to
/proc. Service checks come from watch.txt, one "name<TAB>url" per line, so the
list can be edited without touching this file.
"""

from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime
from pathlib import Path

WEEKDAYS = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
WATCH = Path(os.environ.get("DASH_WATCH", "/root/kindle-dash/watch.txt"))


def split_entry(line: str):
    """Parse one watch.txt line into (name, url).

    A browser textarea cannot produce a tab character, so the separator cannot
    be a tab. '|' is the documented one; whitespace still works, split from the
    right so a name may itself contain spaces. A bare URL gets its host as the
    label.
    """
    if "|" in line:
        name, _, url = line.partition("|")
    else:
        parts = line.rsplit(None, 1)
        if len(parts) == 2:
            name, url = parts
        else:
            name, url = "", parts[0]
    name, url = name.strip(), url.strip()
    if not url:
        return None
    if not name:
        name = url.split("//")[-1].split("/")[0]
    return name, url
TIMEOUT = 8


def sh(cmd: str) -> str:
    try:
        return subprocess.run(cmd, shell=True, capture_output=True, text=True,
                              timeout=10).stdout.strip()
    except (subprocess.SubprocessError, OSError):
        return ""


def uptime_text() -> str:
    try:
        secs = float(Path("/proc/uptime").read_text().split()[0])
    except (OSError, ValueError, IndexError):
        return "--"
    d, rem = divmod(int(secs), 86400)
    h, m = divmod(rem // 60, 60)
    return f"{d}天{h}时" if d else f"{h}时{m}分"


def load_text() -> str:
    try:
        a, b, _ = Path("/proc/loadavg").read_text().split()[:3]
        return f"{a} / {b}"
    except (OSError, ValueError):
        return "--"


def mem_text() -> str:
    info = {}
    try:
        for line in Path("/proc/meminfo").read_text().splitlines():
            k, _, v = line.partition(":")
            info[k] = int(v.split()[0])
    except (OSError, ValueError, IndexError):
        return "--"
    total, avail = info.get("MemTotal", 0), info.get("MemAvailable", 0)
    if not total:
        return "--"
    return f"{avail // 1024} / {total // 1024} MB"


def disk_text(path: str = "/") -> str:
    try:
        st = os.statvfs(path)
    except OSError:
        return "--"
    free = st.f_bavail * st.f_frsize / (1024 ** 2)
    return f"{free:.0f} MB 可用"


def temp_text() -> str:
    for z in sorted(Path("/sys/class/thermal").glob("thermal_zone*/temp")):
        try:
            return f"{int(z.read_text()) / 1000:.0f}°C"
        except (OSError, ValueError):
            continue
    return ""


def conntrack_text() -> str:
    base = Path("/proc/sys/net/netfilter")
    try:
        cur = int((base / "nf_conntrack_count").read_text())
    except (OSError, ValueError):
        return ""
    try:
        mx = int((base / "nf_conntrack_max").read_text())
    except (OSError, ValueError):
        return str(cur)
    return f"{cur} / {mx}"


def clients_text() -> str:
    out = sh("ip neigh show")
    n = sum(1 for line in out.splitlines() if "REACHABLE" in line)
    return str(n) if out else ""


def external_disks() -> list[dict]:
    """Every mounted USB/SATA disk, as its own row.

    Read from /proc/mounts rather than hardcoding mount points, so plugging a
    different disk in needs no change here.
    """
    rows = []
    try:
        lines = Path("/proc/mounts").read_text().splitlines()
    except OSError:
        return rows
    for line in lines:
        parts = line.split()
        if len(parts) < 3:
            continue
        dev, mnt = parts[0], parts[1].replace("\\040", " ")
        if not dev.startswith("/dev/sd"):
            continue
        try:
            st = os.statvfs(mnt)
        except OSError:
            continue
        total = st.f_blocks * st.f_frsize
        free = st.f_bavail * st.f_frsize
        if not total:
            continue
        used_pct = round((total - free) * 100 / total)
        gb = 1024 ** 3
        name = Path(mnt).name or mnt
        rows.append({"l": name, "r": f"{free / gb:.0f} / {total / gb:.0f} GB  {used_pct}%"})
    return rows


def wan_ip() -> str:
    out = sh("ip -4 -o addr show eth0")
    for part in out.split():
        if "/" in part and part.count(".") == 3:
            return part.split("/")[0]
    return "--"


def check(url: str) -> str:
    """One service probe, retried once.

    A dashboard that cries wolf is worse than one that takes a second longer, so
    a single blip does not get reported as an outage. The failure kind is named
    rather than collapsed into one message, because "timed out" and "DNS failed"
    call for different things.
    """
    req = urllib.request.Request(url, method="GET",
                                 headers={"User-Agent": "kindle-dash/1.0"})
    last = "无法连接"
    for attempt in (1, 2):
        t0 = time.monotonic()
        try:
            with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
                return f"{r.status}  {int((time.monotonic() - t0) * 1000)}ms"
        except urllib.error.HTTPError as e:
            # A 4xx/5xx is still a live service answering; report the code.
            return f"{e.code}  {int((time.monotonic() - t0) * 1000)}ms"
        except socket.timeout:
            last = "超时"
        except urllib.error.URLError as e:
            reason = getattr(e, "reason", None)
            if isinstance(reason, socket.timeout):
                last = "超时"
            elif isinstance(reason, socket.gaierror):
                last = "DNS 失败"
            elif isinstance(reason, ConnectionRefusedError):
                last = "拒绝连接"
            else:
                last = "无法连接"
        except OSError:
            last = "无法连接"
        if attempt == 1:
            time.sleep(1)
    return last


def build() -> dict:
    now = datetime.now()
    rows = [
        {"l": "Nano 负载", "r": load_text()},
        {"l": "Nano 内存", "r": mem_text()},
        {"l": "Nano 运行", "r": uptime_text()},
        {"l": "overlay", "r": disk_text("/")},
        {"l": "WAN", "r": wan_ip()},
    ]
    t = temp_text()
    if t:
        rows.append({"l": "SoC 温度", "r": t})

    ct = conntrack_text()
    if ct:
        rows.append({"l": "连接数", "r": ct})
    cl = clients_text()
    if cl:
        rows.append({"l": "在线设备", "r": cl})

    for disk in external_disks():
        rows.append(disk)

    rows.append({"l": "cloudflared", "r": "运行中" if sh("pgrep cloudflared") else "未运行"})

    if WATCH.exists():
        for line in WATCH.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            entry = split_entry(line)
            if entry:
                rows.append({"l": entry[0], "r": check(entry[1])})

    return {
        "date": f"{now.month}月{now.day}日 {WEEKDAYS[now.weekday()]}",
        "updated": now.strftime("%H:%M"),
        "title": "系统状态",
        "rows": rows,
        "status": ["系统状态"],
    }


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "-"
    text = json.dumps(build(), ensure_ascii=False, indent=1)
    if out == "-":
        print(text)
    else:
        Path(out).write_text(text + "\n", encoding="utf-8")
        print(f"wrote {out}", file=sys.stderr)
