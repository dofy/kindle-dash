#!/bin/sh
# Name: 看板 · 运行 RUNME.sh
# Author: seven
# 以 root 执行 /mnt/us/RUNME.sh
# Iteration hook: runs whatever /mnt/us/RUNME.sh currently contains, as root.
# Lets the script be rewritten over USB without touching the exploit chain.
if [ -f /mnt/us/RUNME.sh ]; then
    exec /bin/sh /mnt/us/RUNME.sh
fi
eips 0 12 "no RUNME.sh found        " 2>/dev/null
exit 0
