# kindle-dash

A dashboard for a jailbroken Kindle 7 (Basic, 2014) — serial prefix `90C6`,
firmware 5.12.2.2, 6" 600x800 E-Ink Pearl, no frontlight, 256 MB RAM.

The device does as little as possible: it wakes on a timer, fetches a PNG over
WiFi, pushes it to the panel with `fbink`, and sleeps again. Every decision
about what the page says and how it looks is made on the router, which is
always on, so changing the dashboard never means plugging in the Kindle.

## How a cycle runs

1. `build.sh` runs from cron on the router. For each page it runs that page's
   generator, which writes JSON, then renders the JSON with `gen.py`.
2. Each image is rendered inside the serve directory and moved into place, so
   the device can never fetch a half-written file.
3. `build.sh` also publishes `config` — the page sequence, the wake minutes and
   the page count — and rewrites its own cron schedule to two minutes before
   every wake, so the image is always fresh when the device asks for it.
4. The device reads `config`, picks the next page from the sequence, fetches
   `page-N.png`, displays it, and sets the next wake.

## Layout

```
build.sh          orchestrates a build and publishes config  (router, cron)
gen.py            JSON -> 600x800 8-bit greyscale PNG
fetch.py          page generator: QWeather
status.py         page generator: router metrics and service probes
notes.py          page generator: notes.txt
data.sample.json  the data contract gen.py renders
device/           what runs on the Kindle itself, numbered in install order
nano/luci/        the LuCI app: menu entry, ACL, and the settings page
```

Runtime state is deliberately untracked: `dash.conf` (see `dash.conf.sample`),
`notes.txt` and `watch.txt` are edited through LuCI, `env` holds the QWeather
credentials, and `.serve-token` is the device's MAC.

## Rendering on a development machine

```bash
uv run gen.py                      # built-in demo data -> out/dash.png
uv run gen.py -d data.sample.json  # render from a JSON file
uv run gen.py --bw                 # also write a dithered 1-bit variant
uv run gen.py --rotate 90          # for mounting the device on its side
python3 notes.py -                 # see what a generator emits
```

`uv` reads the inline PEP 723 metadata at the top of `gen.py` and installs
Pillow on demand, so nothing lands in the system Python. The shebang is plain
`python3` because the router and the dev box do not have `uv`; there, Pillow is
installed system-wide and `build.sh` calls `python3 ./gen.py` directly.

## Installing on the router

```bash
scp build.sh gen.py fetch.py status.py notes.py root@router:/root/kindle-dash/
scp -r nano/luci/view/kindle-dash root@router:/www/luci-static/resources/view/
scp nano/luci/menu.d/*.json        root@router:/usr/share/luci/menu.d/
scp nano/luci/acl.d/*.json         root@router:/usr/share/rpcd/acl.d/
ssh root@router '/etc/init.d/rpcd restart'   # only after an ACL change
```

The device needs to be told where to fetch from, once, over USB:

```bash
echo http://<router>/kindle/<device-mac> > /mnt/us/dash-site
```

`dash.conf` on the device is replaced from the server every cycle, so the
address cannot live there, and it is kept out of the repository so the MAC and
the network layout are not published with it. Without the file the refresh loop
exits and says so in `/mnt/us/dash-loop.log`.

The router needs `python3`, `python3-pillow`, and a CJK font pair at
`/root/kindle-dash/fonts/NotoSansSC-{Regular,Bold}.otf`; those files are not in
the repo because they are 16 MB of binary. `env` has to be written by hand at
mode 600 with the QWeather host, key, location id and coordinates.
`build.sh` installs its own cron line on the first run.

## Pages

`PAGE_SPECS` in `dash.conf` maps a page number to a generator, for example
`1:fetch.py 2:status.py 3:notes.py`. Page numbers start at 1 and have to be
contiguous, because the device walks `1..TOTAL`. A generator name must be a
plain `*.py` file in `/root/kindle-dash`: the value is editable from LuCI and
runs as root. A generator that is missing is dropped from the count; one that
fails at runtime keeps its previous image, so one broken page never takes the
others down.

Adding a page means writing a generator that emits the data contract and
appending it to `PAGE_SPECS`.

## Data contract

See `data.sample.json`. Weather icon names: `sun`, `moon`, `partly`, `cloud`,
`rain`, `snow`. `date` and `updated` fall back to the current local time when
absent. Sections are skipped when their data is absent, so the same layout code
handles "weather only" and "weather plus everything else". Rows past the
available height collapse into a "还有 N 项" line.

## Design constraints

- No frontlight, so the panel is unreadable in the dark.
- Pearl contrast is poor: light greys disappear. Secondary text stays at `DIM`
  (90) and rules at `RULE` (160); nothing lighter carries meaning.
- 167 ppi is coarse. Body text is 24-27 px, the hero temperature 112 px.
- Hairlines wash out, so glyph strokes scale with glyph size and never go below
  2 px.
- Every wake costs battery: WiFi, a fetch and a panel refresh. Four wakes an
  hour is the default; the LuCI page warns past that.

## Fonts

Resolved at runtime from the first usable candidate: Noto Sans SC under
`fonts/`, then Hiragino Sans GB, PingFang, Songti. Override with
`KINDLE_DASH_FONT_REGULAR` and `KINDLE_DASH_FONT_BOLD`.
