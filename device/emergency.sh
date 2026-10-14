#!/bin/sh
# Boot hook. /etc/upstart/kmc.conf runs this as root once the framework is
# ready, so it is what makes the dashboard start on its own.
#
# /mnt/us/dash-off disables it. Three ways to create that file:
#   1. over USB, at the Kindle's root, then reboot
#   2. tap "06-autostart-off" in the library
#   3. during the grace window below, while the normal UI is still up
#
# The grace window matters: without it a bad loop would leave no way back in
# except USB, so the UI stays usable for a while after every boot.
[ -f /mnt/us/dash-off ] && exit 0

WORKER=/mnt/us/dash-boot.sh
[ -f "$WORKER" ] || exit 0

if command -v setsid >/dev/null 2>&1; then
    setsid /bin/sh "$WORKER" >/dev/null 2>&1 &
else
    nohup /bin/sh "$WORKER" >/dev/null 2>&1 &
fi
exit 0
