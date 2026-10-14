#!/bin/sh
# Turn the Kindle into a plain display: stop the UI framework so it stops
# repainting over the framebuffer, then draw the dashboard.
#
# Runs detached, because stopping the framework also kills whatever framework
# app launched the scriptlet, and that would otherwise kill this script before
# it ever draws.
#
# To undo: long-press power and pick Restart. Nothing here persists.
LOG=/mnt/us/dashmode.log
FBINK=/var/local/kmc/bin/fbink
IMG=/mnt/us/dash.png

{
    echo "=== dashmode at $(date)"
    echo "--- relevant upstart jobs, before"
    initctl list 2>&1 | grep -Ei 'framework|powerd|cvm|pillow|volumd'

    echo "--- stop framework"
    stop framework
    echo "rc=$?"
    sleep 4

    echo "--- relevant upstart jobs, after"
    initctl list 2>&1 | grep -Ei 'framework|powerd|cvm|pillow|volumd'

    echo "--- draw"
    "$FBINK" -q -c -f -W GC16 -g file="$IMG",dither
    echo "rc=$?"

    echo "--- redraw once more after 20s, to see whether anything repainted"
    sleep 20
    "$FBINK" -q -g file="$IMG",dither
    echo "rc=$?"
    echo "=== end"
} > "$LOG" 2>&1
sync
exit 0
