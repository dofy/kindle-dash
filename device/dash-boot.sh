#!/bin/sh
# Waits out the grace window, re-checking the off switch the whole time, then
# hands over to the refresh loop. Detached by emergency.sh.
GRACE=${GRACE:-75}
LOG=/mnt/us/dash-loop.log

i=0
while [ "$i" -lt "$GRACE" ]; do
    if [ -f /mnt/us/dash-off ]; then
        echo "$(date '+%m-%d %H:%M:%S') autostart cancelled during grace window" >> "$LOG"
        exit 0
    fi
    sleep 5
    i=$((i + 5))
done

[ -f /mnt/us/dash-off ] && exit 0
echo "$(date '+%m-%d %H:%M:%S') autostart: grace window elapsed, starting loop" >> "$LOG"
ALIGN=1 exec /bin/sh /mnt/us/dash-loop-worker.sh
