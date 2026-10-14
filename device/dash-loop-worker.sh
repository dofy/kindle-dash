#!/bin/sh
# Refresh loop for the Kindle dashboard.
#
# Runs detached, because stopping the UI framework kills whatever framework app
# launched it. Between refreshes the device suspends to RAM on an RTC alarm,
# which is what makes the battery last weeks rather than a day.
#
# Almost nothing is configured here. Each cycle the loop fetches a normalised
# config from the server, so the page order, the weighting and the wake times
# can all be changed from LuCI without touching the device.
#
# Local overrides, for testing:
#   MAX_ITER    stop after this many cycles and restore the UI; empty = forever
#   MIN_CYCLE   hard floor on the cycle period, as a backstop against spinning
#
# Design notes earned the hard way:
#   * The panel is only redrawn when the image actually changed. E-Ink holds a
#     picture without power, so redrawing identical content buys nothing and
#     each redraw is a visible black flash.
#   * A failed suspend never triggers a redraw. It used to, which turned one
#     broken delay calculation into hundreds of flashes a minute.
#   * Nothing fetched or computed is trusted as a number without a check. An
#     empty value once made both the wakealarm write and the sleep no-ops.
#   * The config is parsed, never sourced: it arrives over the network.
#   * A Kindle will not stay suspended while USB is attached, and /mnt/us is
#     detached on the device side in USB drive mode, so the loop can neither
#     fetch nor log while plugged in. Testing requires the cable out.
LOG=/mnt/us/dash-loop.log
IMG=/mnt/us/dash.png
SIG=/mnt/us/dash.sig
IDX=/mnt/us/dash.idx
CACHE=/mnt/us/cache
LOCK=/mnt/us/dash-loop.pid
# /proc/bus/input/devices reports event0 as "max77696-onkey", the PMIC's power
# button. The touchscreen is event1 ("zforce2") and is not a wakeup source, so
# it is no use here.
POWER_DEV=${POWER_DEV:-/dev/input/event0}
CFG=/mnt/us/dash.conf
URL_BASE=http://192.168.2.1/kindle/802deafa09e8
FBINK=/var/local/kmc/bin/fbink
RTC=/sys/class/rtc/rtc1/wakealarm

MAX_ITER=${MAX_ITER:-}
MIN_CYCLE=${MIN_CYCLE:-60}

# Defaults, used until the first successful config fetch and whenever a value
# does not survive validation.
SEQ="1"
WAKE_MINUTES="9 24 39 54"
ALIGN=1
INTERVAL=900

log() {
    echo "$(date '+%m-%d %H:%M:%S') $*" >> "$LOG"
}

is_uint() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

cfg_get() {
    [ -f "$CFG" ] || return 0
    grep "^$1=" "$CFG" 2>/dev/null | tail -1 | cut -d= -f2-
}

load_config() {
    curl -fsS --max-time 10 -o "$CFG.new" "$URL_BASE/config" 2>/dev/null || return 1
    mv -f "$CFG.new" "$CFG"

    v=$(cfg_get SEQ)
    clean=""
    for t in $v; do
        is_uint "$t" && [ "$t" -ge 1 ] && clean="$clean $t"
    done
    [ -n "$clean" ] && SEQ=$(echo "$clean" | sed 's/^ *//')

    v=$(cfg_get WAKE_MINUTES)
    clean=""
    for t in $v; do
        is_uint "$t" && [ "$t" -le 59 ] && clean="$clean $t"
    done
    [ -n "$clean" ] && WAKE_MINUTES=$(echo "$clean" | sed 's/^ *//')

    v=$(cfg_get ALIGN)
    [ "$v" = "0" ] && ALIGN=0
    [ "$v" = "1" ] && ALIGN=1

    v=$(cfg_get INTERVAL)
    if is_uint "$v" && [ "$v" -ge 60 ] && [ "$v" -le 3600 ]; then
        INTERVAL=$v
    fi
    return 0
}

# Seconds to the next wake. Derived from the epoch rather than parsed out of
# date +%M, because busybox ash does not understand the 10#NN base syntax that
# stripping leading zeros would otherwise need. WAKE_MINUTES arrives sorted.
next_delay() {
    into=$(($(date +%s) % 3600))
    d=0
    # Skip a point that is less than a minute away, rather than clamping to a
    # flat 900s later and losing the alignment entirely.
    for m in $WAKE_MINUTES; do
        tt=$((m * 60))
        if [ $((tt - into)) -ge 60 ]; then
            d=$((tt - into))
            break
        fi
    done
    if [ "$d" -eq 0 ]; then
        first=""
        for m in $WAKE_MINUTES; do
            first=$m
            break
        done
        is_uint "$first" || first=9
        d=$((3600 + first * 60 - into))
    fi
    # Clamp hard. A wrong delay here used to mean the loop span and flashed the
    # panel hundreds of times, so an out-of-range value falls back to 15 minutes.
    if [ "$d" -lt 60 ] || [ "$d" -gt 3600 ]; then
        d=900
    fi
    echo "$d"
}

seq_len() {
    n=0
    for t in $SEQ; do n=$((n + 1)); done
    echo "$n"
}

# Nth entry of SEQ, 1-based.
seq_at() {
    want=$1
    n=0
    for t in $SEQ; do
        n=$((n + 1))
        if [ "$n" = "$want" ]; then
            echo "$t"
            return
        fi
    done
    echo 1
}

read_idx() {
    p=$(cat "$IDX" 2>/dev/null)
    is_uint "$p" || p=1
    [ "$p" -lt 1 ] && p=1
    echo "$p"
}

# Drain whatever the waking press left in the queue. A single press emits four
# events (key down, syn, key up, syn), so without this the next read would
# return a stale one and every press would look like a double.
drain_power_events() {
    [ -r "$POWER_DEV" ] || return 0
    command -v timeout >/dev/null 2>&1 || return 0
    timeout 1 dd if="$POWER_DEV" of=/dev/null bs=16 2>/dev/null
    return 0
}

# True when another press arrives within the window. struct input_event is 16
# bytes on 32-bit ARM, so one record is one event.
awaiting_second_press() {
    [ -r "$POWER_DEV" ] || return 1
    command -v timeout >/dev/null 2>&1 || return 1
    timeout "${DOUBLE_CLICK_SECONDS:-1}" dd if="$POWER_DEV" of=/dev/null bs=16 count=1 2>/dev/null
}

battery() {
    lipc-get-prop com.lab126.powerd battLevel 2>/dev/null || echo "?"
}

# Content signature, used to decide whether a redraw is warranted at all.
sig_of() {
    if command -v md5sum >/dev/null 2>&1; then
        md5sum "$1" 2>/dev/null | cut -d' ' -f1
    else
        wc -c < "$1" 2>/dev/null
    fi
}

# Put a file on the panel and record what is now displayed.
draw() {
    cp -f "$1" "$IMG"
    "$FBINK" -q -c -f -W GC16 -g file="$IMG",dither
    sig_of "$IMG" > "$SIG"
    sync
}

[ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 200000 ] && : > "$LOG"

# Hot reload. Updating this script otherwise means a 40 second power-button hold,
# because the UI framework is stopped and there is no restart menu. Instead the
# loop notices its own file changed and re-executes it at a cycle boundary.
SELF=$0
self_sig=$(sig_of "$SELF")

mkdir -p "$CACHE"

# Single instance. Autostart launches one 75s after boot and the library has a
# scriptlet that launches one by hand; two loops would fight over the panel and
# over the rotation index. The cmdline check avoids tripping over a recycled PID
# from before a reboot, and exec-based hot reload keeps the same PID so the lock
# stays valid across it.
other=$(cat "$LOCK" 2>/dev/null)
if [ -n "$other" ] && [ "$other" != "$$" ] && [ -r "/proc/$other/cmdline" ] &&
   grep -q dash-loop-worker "/proc/$other/cmdline" 2>/dev/null; then
    log "another loop is already running (pid $other); this one exits"
    exit 0
fi
echo $$ > "$LOCK"
sync

log "=== loop start pid=$$ min_cycle=${MIN_CYCLE}s max_iter=${MAX_ITER:-inf}"

# One-off probe for real click detection. Waking from suspend is currently the
# only press signal, which bounds two presses to however long a cycle takes;
# reading the power button's evdev node directly would allow a sub-second
# double click instead. Logged once per start so the data is there to act on.
probe_input() {
    log "probe: timeout=$(command -v timeout || echo MISSING) dd=$(command -v dd || echo MISSING)"
    if [ -x /var/local/kmc/bin/input_scan ]; then
        log "probe: input_scan -m power -> $(/var/local/kmc/bin/input_scan -m power 2>&1 | tr '\n' ' ' | cut -c1-200)"
        log "probe: input_scan -m touchscreen -> $(/var/local/kmc/bin/input_scan -m touchscreen 2>&1 | tr '\n' ' ' | cut -c1-160)"
    else
        log "probe: input_scan MISSING"
    fi
    log "probe: event nodes -> $(ls /dev/input/ 2>&1 | tr '\n' ' ')"
    if [ -r /proc/bus/input/devices ]; then
        log "probe: $(grep -iE '^N: |^H: ' /proc/bus/input/devices 2>/dev/null | tr '\n' '|' | cut -c1-400)"
    fi

    # Whether touch can turn a page comes down to one fact: is the touch
    # controller a wakeup source during suspend-to-RAM? If it is not, touch only
    # works during the few seconds per cycle that the device is awake, which is
    # under one percent of the time.
    enabled=""
    for w in /sys/bus/i2c/devices/*/power/wakeup /sys/bus/platform/devices/*/power/wakeup; do
        [ -r "$w" ] || continue
        if [ "$(cat "$w" 2>/dev/null)" = "enabled" ]; then
            d=${w%/power/wakeup}
            enabled="$enabled ${d##*/}"
        fi
    done
    log "probe: wakeup-enabled devices ->${enabled:- none}"
    log "probe: touch irq -> $(grep -iE 'cyttsp|touch|tsc' /proc/interrupts 2>/dev/null | tr -s ' ' | cut -c1-160 | tr '\n' '|')"
    log "probe: power states -> $(cat /sys/power/state 2>/dev/null)"
}
probe_input
stop framework >/dev/null 2>&1
sleep 3
log "framework stopped"

i=0
first_draw=1
# Set when the previous cycle ended in a user-initiated wake, which relaxes the
# anti-spin floor for the cycle that serves it.
user_wake=0
# Epoch of the last deliberate wake. A second press soon after the first is the
# "give me the Kindle back" gesture, which saves holding power for 40 seconds:
# with the framework stopped there is no restart menu to tap, because that menu
# is drawn by the framework itself.
last_press=0
DOUBLE_PRESS_WINDOW=${DOUBLE_PRESS_WINDOW:-15}
DOUBLE_CLICK_SECONDS=${DOUBLE_CLICK_SECONDS:-1}
# Set when the previous cycle could not suspend at all, which on this device
# means USB is attached. The loop then degrades to a 60s spin, and advancing the
# page on every one of those turns made the panel change on its own once a
# minute - indistinguishable from the power button misbehaving.
suspend_failed=0
while true; do
    i=$((i + 1))
    cycle_start=$(date +%s)

    load_config || log "config fetch failed; keeping the previous settings"

    len=$(seq_len)
    idx=$(read_idx)
    [ "$idx" -gt "$len" ] && idx=1
    page=$(seq_at "$idx")

    cached="$CACHE/page-$page.png"

    # Every page is kept locally, so turning a page never depends on the
    # network. Wi-Fi can take tens of seconds to reassociate after a resume,
    # and waiting for it made the power button look broken: the cycle sat in
    # fetch retries and nothing was ever drawn.
    drew=0
    if [ "$user_wake" = 1 ] && [ -s "$cached" ]; then
        draw "$cached"
        drew=1
        log "cycle $i seq[$idx/$len]=page$page drew cached copy at once (batt=$(battery))"
    fi

    ok=0
    for attempt in 1 2 3 4 5; do
        if curl -fsS --max-time 20 -o "$cached.new" "$URL_BASE/page-$page.png"; then
            mv -f "$cached.new" "$cached"
            sync
            ok=1
            break
        fi
        log "fetch attempt $attempt failed"
        sleep 5
    done
    rm -f "$cached.new"

    if [ "$ok" = 1 ]; then
        newsig=$(sig_of "$cached")
        oldsig=$(cat "$SIG" 2>/dev/null)
        if [ "$first_draw" = 1 ] || [ "$newsig" != "$oldsig" ]; then
            draw "$cached"
            log "cycle $i seq[$idx/$len]=page$page drawn ($(wc -c < "$cached") bytes, batt=$(battery))"
        else
            log "cycle $i seq[$idx/$len]=page$page unchanged, no redraw (batt=$(battery))"
        fi
    elif [ "$drew" = 0 ]; then
        if [ -s "$cached" ]; then
            newsig=$(sig_of "$cached")
            if [ "$newsig" != "$(cat "$SIG" 2>/dev/null)" ]; then
                draw "$cached"
                log "cycle $i seq[$idx/$len]=page$page fetch failed, drew the cached copy (batt=$(battery))"
            else
                log "cycle $i seq[$idx/$len]=page$page fetch failed, cached copy already on screen"
            fi
        else
            log "cycle $i seq[$idx/$len]=page$page fetch failed and nothing cached; screen unchanged"
        fi
    else
        log "cycle $i seq[$idx/$len]=page$page fetch failed after showing the cached copy"
    fi
    first_draw=0

    # Real double-click detection. Listening happens after the page is drawn, so
    # a single press still lands in about three seconds; only the second press
    # costs the extra second. Falls through to the slower re-suspend-based
    # gesture if the event device or timeout is unavailable.
    if [ "$user_wake" = 1 ] && awaiting_second_press; then
        log "second press within ${DOUBLE_CLICK_SECONDS:-1}s: restoring the UI and exiting"
        start framework >/dev/null 2>&1
        rm -f "$LOCK"
        log "=== loop end (double click)"
        exit 0
    fi

    # Advance now and persist, so the next wake shows the next entry whether it
    # came from the RTC or from someone pressing the power button.
    #
    # /mnt/us is a FUSE mount, and an unflushed write is lost when the device
    # suspends: the rotation silently repeated a page because of exactly that.
    # Hence the sync, and the read-back so a lost write shows up in the log.
    if [ "$suspend_failed" = 1 ]; then
        # No suspend means no wake to serve. Advancing anyway turned the loop
        # into a page-flipper that changed the panel once a minute on its own.
        log "previous cycle could not suspend; holding on page$page"
    else
        nextidx=$((idx % len + 1))
        echo "$nextidx" > "$IDX"
        sync
        stored=$(cat "$IDX" 2>/dev/null)
        [ "$stored" = "$nextidx" ] || log "index write did not stick: wanted $nextidx, read '$stored'"
    fi

    now_sig=$(sig_of "$SELF")
    if [ -n "$now_sig" ] && [ -n "$self_sig" ] && [ "$now_sig" != "$self_sig" ]; then
        log "worker script changed on disk, re-executing"
        exec /bin/sh "$SELF"
    fi

    if [ -n "$MAX_ITER" ] && [ "$i" -ge "$MAX_ITER" ]; then
        log "reached max_iter, restarting the UI"
        start framework >/dev/null 2>&1
        rm -f "$LOCK"
        log "=== loop end"
        exit 0
    fi

    if [ "$ALIGN" = 1 ]; then
        delay=$(next_delay)
    else
        delay=$INTERVAL
    fi
    is_uint "$delay" || { log "delay was '$delay', not a number; using 900"; delay=900; }

    t0=$(date +%s)
    echo 0 > "$RTC" 2>/dev/null
    echo $((t0 + delay)) > "$RTC" 2>/dev/null
    armed=$(cat "$RTC" 2>/dev/null)
    if [ -n "$armed" ] && [ "$armed" != "0" ]; then
        log "wakealarm armed at $armed (+${delay}s), suspending"
        # Use the exit status of the write, not how long we were gone. A short
        # sleep is NOT evidence that suspend failed: pressing the power button
        # right after the device suspends produces one too, and treating that as
        # a failure silently ate every press made within the first ten seconds.
        if echo mem > /sys/power/state 2>>"$LOG"; then
            suspended=1
        else
            suspended=0
        fi
        slept=$(($(date +%s) - t0))
        echo 0 > "$RTC" 2>/dev/null
        user_wake=0

        if [ "$suspended" = 0 ]; then
            suspend_failed=1
            log "suspend refused after ${slept}s; is USB attached?"
        else
            suspend_failed=0
            log "resumed after ${slept}s (asked for ${delay}s)"
            if [ "$slept" -lt $((delay / 2)) ]; then
                now=$(date +%s)
                if [ "$last_press" -gt 0 ] && [ $((now - last_press)) -le "$DOUBLE_PRESS_WINDOW" ]; then
                    log "second press within $((now - last_press))s: restoring the UI and exiting"
                    start framework >/dev/null 2>&1
                    rm -f "$LOCK"
                    log "=== loop end (double press)"
                    exit 0
                fi
                last_press=$now
                log "woken early, most likely the power button; showing the next page"
                user_wake=1
                drain_power_events
            fi
        fi
    else
        log "wakealarm not settable on $RTC; sleeping ${delay}s instead"
        sleep "$delay"
    fi

    # Backstop: no cycle may be shorter than the floor, whatever the delay
    # calculation or the suspend call did.
    #
    # The floor is there to stop a runaway loop, not to throttle a person. After
    # a deliberate wake it drops to a few seconds, otherwise pressing the power
    # button appeared to do nothing for the best part of a minute.
    floor=5
    [ "$suspend_failed" = 1 ] && floor=$MIN_CYCLE
    spent=$(($(date +%s) - cycle_start))
    if [ "$spent" -lt "$floor" ]; then
        log "cycle took only ${spent}s; holding $((floor - spent))s (floor ${floor}s)"
        sleep $((floor - spent))
    fi
done
