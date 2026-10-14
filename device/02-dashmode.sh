#!/bin/sh
# Name: 看板 · 只停界面
# Author: seven
# 停掉界面画一张，不进循环
# Launch the display-mode worker detached, then get out of the way so the
# framework can be stopped without taking the worker down with it.
nohup /bin/sh /mnt/us/dashmode-worker.sh >/dev/null 2>&1 &
exit 0
