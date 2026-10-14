#!/bin/sh
# Name: 看板 · 网络与电源自检
# Author: seven
# 写 /mnt/us/netprobe.log
# Check what the refresh loop can rely on: the server fetch, and whether the
# device can suspend to RAM on an RTC alarm instead of just sleeping.
LOG=/mnt/us/netprobe.log
URL=http://192.168.2.1/kindle/802deafa09e8/dash.png
{
    echo "=== netprobe at $(date)"
    echo "--- network"
    ifconfig 2>/dev/null | grep -E '^[a-z]|inet '
    route -n 2>/dev/null | head -5
    echo "--- tools"
    for t in curl wget rtcwake lipc-set-prop lipc-get-prop initctl; do
        printf '%s: ' "$t"; command -v "$t" || echo MISSING
    done
    echo "--- fetch the dashboard"
    curl -fsS --max-time 25 -o /mnt/us/dash-fetched.png "$URL"; echo "curl rc=$?"
    ls -la /mnt/us/dash-fetched.png 2>&1
    echo "--- rtc devices"
    ls -la /sys/class/rtc/ 2>&1
    for r in /sys/class/rtc/rtc*; do
        printf '%s name=' "$r"; cat "$r/name" 2>/dev/null
        printf '  wakealarm='; cat "$r/wakealarm" 2>/dev/null; echo
    done
    echo "--- power states"
    cat /sys/power/state 2>&1
    echo "--- powerd / framework"
    initctl list 2>/dev/null | grep -Ei 'powerd|framework|volumd'
    echo "=== end"
} > "$LOG" 2>&1
sync
eips 0 12 "netprobe done - replug USB " 2>/dev/null
exit 0
