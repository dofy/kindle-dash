#!/bin/sh
# Name: 看板 · 画一次
# Author: seven
# 画一张，不停界面，画完就回主屏
# Draw the dashboard on the panel.
#
#   -c        clear first, so a shorter image cannot leave old pixels behind
#   -f        flashing refresh, which clears E-Ink ghosting
#   -W GC16   the full 16-level waveform; the quality mode for images
#   dither    software ordered dithering, to match the panel's grey palette
#
# fbink lives on ext3 because /mnt/us is mounted noexec.
FBINK=/var/local/kmc/bin/fbink
IMG=/mnt/us/dash.png
LOG=/mnt/us/dash.log
{
    echo "=== $(date)"
    "$FBINK" -q -c -f -W GC16 -g file="$IMG",dither
    echo "rc=$?"
} > "$LOG" 2>&1
sync
exit 0
