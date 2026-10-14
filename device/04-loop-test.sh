#!/bin/sh
# Name: 看板 · 测试两轮后自动退出
# Author: seven
# 跑 2 轮就把界面还回来，仅用于验证
# One real aligned cycle, then the UI comes back on its own. Unplug USB first:
# the device will not suspend while it is charging.
ALIGN=1 MAX_ITER=2 nohup /bin/sh /mnt/us/dash-loop-worker.sh >/dev/null 2>&1 &
exit 0
