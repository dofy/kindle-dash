#!/bin/sh
# Render every dashboard page and publish them, together with the config the
# device reads each cycle.
#
# Rendering happens inside SERVE_DIR so the final rename is a same-filesystem
# move, which the Kindle can never catch half-written. Permissions are set
# explicitly because uhttpd has to read these and the caller's umask is not
# ours to trust.
#
# dash.conf is parsed, never sourced: it is editable from LuCI, and a config
# file should not be able to run commands here.
set -e
cd /root/kindle-dash
set -a
. ./env
set +a
mkdir -p "$SERVE_DIR"

CONF=/root/kindle-dash/dash.conf
conf_get() {
    [ -f "$CONF" ] || return 0
    grep "^$1=" "$CONF" 2>/dev/null | tail -1 | cut -d= -f2-
}

PAGE_SPECS=$(conf_get PAGE_SPECS)
[ -n "$PAGE_SPECS" ] || PAGE_SPECS="1:fetch.py 2:status.py 3:notes.py"

# PAGE_SPECS is editable from LuCI and its generator names are handed to
# python3 as root, so only a bare *.py file inside this directory is accepted.
#
# The accepted page numbers also have to start at 1 with no gap: TOTAL is
# published to the device and stamped into every footer, and a gap would make
# it count pages that were never rendered.
PAGES=$(python3 - "$PAGE_SPECS" <<'PY'
import os
import re
import sys

NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*\.py$")

claimed = set()
accepted = {}
for spec in sys.argv[1].split():
    num, sep, gen = spec.partition(":")
    if not sep or not num.isdigit() or int(num) < 1:
        print(f"spec {spec!r}: expected 页号:生成器 with a page number from 1, skipped",
              file=sys.stderr)
        continue
    n = int(num)
    if n in claimed:
        print(f"page {n}: declared more than once, {gen!r} ignored", file=sys.stderr)
        continue
    claimed.add(n)
    if not NAME.match(gen):
        print(f"page {n}: {gen!r} is not a plain .py file name, skipped", file=sys.stderr)
        continue
    if not os.path.isfile(gen):
        print(f"page {n}: {gen} missing, skipped", file=sys.stderr)
        continue
    accepted[n] = gen

for n in range(1, max(accepted, default=0) + 1):
    if n not in accepted:
        dropped = sorted(x for x in accepted if x > n)
        if dropped:
            print(f"page {n} is unusable, so {dropped} are dropped as well: "
                  f"pages have to be contiguous from 1", file=sys.stderr)
        break
    print(f"{n}:{accepted[n]}")
PY
)
# grep exits 1 on no match, and set -e would take the script down before
# the check below gets to say why.
TOTAL=$(echo "$PAGES" | grep -c . || true)
if [ "$TOTAL" -eq 0 ]; then
    echo "PAGE_SPECS has no usable page; the published dashboard is left alone" >&2
    exit 1
fi

for spec in $PAGES; do
    n=${spec%%:*}
    gen=${spec#*:}
    tmp_json="$SERVE_DIR/.page-$n.json.tmp"
    tmp_png="$SERVE_DIR/.page-$n.png.tmp"

    if ! python3 "./$gen" "$tmp_json"; then
        echo "page $n: $gen failed, keeping the previous image" >&2
        rm -f "$tmp_json"
        continue
    fi

    # Stamp "page N of M" into the footer so the device never has to know.
    python3 - "$tmp_json" "$n" "$TOTAL" <<'PY'
import json, sys
path, n, total = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, encoding="utf-8") as f:
    d = json.load(f)
d["status"] = [f"第 {n} / {total} 页"] + list(d.get("status") or [])
with open(path, "w", encoding="utf-8") as f:
    json.dump(d, f, ensure_ascii=False, indent=1)
PY

    python3 gen.py -d "$tmp_json" -o "$tmp_png" >/dev/null
    mv -f "$tmp_png" "$SERVE_DIR/page-$n.png"
    mv -f "$tmp_json" "$SERVE_DIR/page-$n.json"
    chmod 644 "$SERVE_DIR/page-$n.png" "$SERVE_DIR/page-$n.json"

    # A copy at a fixed path, for the LuCI preview to read. SERVE_DIR sits
    # outside any document root so the browser cannot fetch it, and the ACL has
    # to name paths it can glob within one directory.
    cp -f "$SERVE_DIR/page-$n.png" "/root/kindle-dash/preview-$n.png"
    chmod 644 "/root/kindle-dash/preview-$n.png"
done

# Normalise the config before publishing it: the device only validates, it does
# not sort or clean up. Anything unusable is replaced by a safe default here.
python3 - "$CONF" "$SERVE_DIR/.config.tmp" "$TOTAL" <<'PY'
import sys

conf_path, out_path, total = sys.argv[1], sys.argv[2], int(sys.argv[3])
raw = {}
try:
    with open(conf_path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, _, v = line.partition("=")
            raw[k.strip()] = v.strip()
except OSError:
    pass

def ints(key, default, lo, hi):
    out = []
    for tok in raw.get(key, "").split():
        try:
            n = int(tok)
        except ValueError:
            continue
        if lo <= n <= hi:
            out.append(n)
    return out or default

seq = [n for n in ints("SEQ", [], 1, max(total, 1)) if n <= total] or list(range(1, total + 1))
wake = sorted(set(ints("WAKE_MINUTES", [9, 24, 39, 54], 0, 59))) or [9, 24, 39, 54]
align = "1" if raw.get("ALIGN", "1").strip() != "0" else "0"
try:
    interval = int(raw.get("INTERVAL", "900"))
except ValueError:
    interval = 900
interval = min(3600, max(60, interval))

with open(out_path, "w", encoding="utf-8") as f:
    f.write(f"SEQ={' '.join(str(n) for n in seq)}\n")
    f.write(f"WAKE_MINUTES={' '.join(str(n) for n in wake)}\n")
    f.write(f"ALIGN={align}\n")
    f.write(f"INTERVAL={interval}\n")
    f.write(f"TOTAL={total}\n")
PY
mv -f "$SERVE_DIR/.config.tmp" "$SERVE_DIR/config"

# A shrunk PAGE_SPECS leaves behind the images of the pages it dropped, and
# both the device and the LuCI preview would go on showing them.
for stale in "$SERVE_DIR"/page-*.png "$SERVE_DIR"/page-*.json; do
    [ -e "$stale" ] || continue
    base=${stale##*/}
    num=${base#page-}
    num=${num%.*}
    case "$num" in
        ''|*[!0-9]*) continue ;;
    esac
    [ "$num" -le "$TOTAL" ] || rm -f "$stale"
done

echo "$TOTAL" > "$SERVE_DIR/pages"
date '+%Y-%m-%d %H:%M:%S %z' > "$SERVE_DIR/built-at"

# Fixed-path copies, so the LuCI view can be granted exactly these files
# instead of a glob that would also cover the credentials in ./env.
echo "$SERVE_DIR" > /root/kindle-dash/serve-dir
cp -f "$SERVE_DIR/built-at" /root/kindle-dash/last-build
cp -f "$SERVE_DIR/pages" /root/kindle-dash/pages

# Page 1 stays available under the old name, so an un-updated device keeps working.
cp -f "$SERVE_DIR/page-1.png" "$SERVE_DIR/dash.png"

# Keep the build schedule two minutes ahead of every wake, derived from
# WAKE_MINUTES rather than set by hand: when the two drifted apart the panel
# quietly showed data up to 13 minutes old even though both sides looked fine.
#
# busybox crond rescans the crontab on its own, so the file is simply rewritten.
# Restarting cron from inside a cron job risks killing this very script.
BUILD_MINUTES=$(python3 - "$SERVE_DIR/config" <<'PY'
import sys
wake = []
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        for line in f:
            if line.startswith("WAKE_MINUTES="):
                wake = [int(t) for t in line.split("=", 1)[1].split() if t.isdigit()]
except OSError:
    pass
if not wake:
    wake = [9, 24, 39, 54]
print(",".join(str(m) for m in sorted({(w - 2) % 60 for w in wake})))
PY
)
CRONTAB=/etc/crontabs/root
CRON_LINE="$BUILD_MINUTES * * * * /root/kindle-dash/build.sh >/tmp/kindle-dash.log 2>&1"
current=$(grep 'kindle-dash/build.sh' "$CRONTAB" 2>/dev/null | head -1 || true)
if [ "$current" != "$CRON_LINE" ]; then
    { grep -v 'kindle-dash/build.sh' "$CRONTAB" 2>/dev/null || true; } > "$CRONTAB.kd"
    echo "$CRON_LINE" >> "$CRONTAB.kd"
    mv -f "$CRONTAB.kd" "$CRONTAB"
    echo "cron schedule set to minutes: $BUILD_MINUTES" >&2
fi

chmod 755 "$SERVE_DIR"
chmod 644 "$SERVE_DIR/pages" "$SERVE_DIR/built-at" "$SERVE_DIR/config" "$SERVE_DIR/dash.png"
