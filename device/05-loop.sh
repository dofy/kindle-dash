#!/bin/sh
# Name: 看板 · 启动（常驻）
# Author: seven
# 和开机自启等价，一直跑到重启
# Production loop: refresh every 15 minutes, forever. Long-press power and pick
# Restart to get the Kindle UI back.
ALIGN=1 nohup /bin/sh /mnt/us/dash-loop-worker.sh >/dev/null 2>&1 &
exit 0
