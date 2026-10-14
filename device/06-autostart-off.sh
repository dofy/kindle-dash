#!/bin/sh
# Name: 看板 · 关闭开机自启
# Author: seven
# 建 /mnt/us/dash-off
# Disable the dashboard autostart. Takes effect on the next boot, and also
# cancels a start that is still inside its grace window.
touch /mnt/us/dash-off
sync
eips 0 12 "autostart OFF - normal Kindle" 2>/dev/null
exit 0
