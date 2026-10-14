#!/bin/sh
# Name: 看板 · 开启开机自启
# Author: seven
# 删 /mnt/us/dash-off
# Re-enable the dashboard autostart. Takes effect on the next boot.
rm -f /mnt/us/dash-off
sync
eips 0 12 "autostart ON - reboot to use" 2>/dev/null
exit 0
