# CLAUDE.md

Working notes for this repository. `README.md` documents the project; this file
records the state of the deployment and the traps that cost time to rediscover.

## Where it runs

- Router (`Nano` / `Nano-tunnel`, OpenWrt): generators and `build.sh` in
  `/root/kindle-dash/`, images published to `/srv/kindle/<device-mac>/`, LuCI
  view at `/www/luci-static/resources/view/kindle-dash/dash.js`, menu and ACL
  under `/usr/share/luci/menu.d/` and `/usr/share/rpcd/acl.d/`.
- `7-mm`: development clone at `~/Works/Seven/kindle-dash`. The pre-git tree is
  parked next to it at `kindle-dash.pre-git` and can be deleted once nothing is
  missing from it.
- Kindle: `device/`, installed under `/mnt/us`, including the one-line
  `dash-site` that tells the loop where to fetch from.

## How the Kindle reaches it

The images are served by a second uhttpd instance on port 8081 with
`home=/srv/kindle`, declared as `uhttpd.kindle`. It carries no `cgi_prefix` and
no `lua_prefix`, so it can only hand out files. The LuCI instance on port 80 is
deliberately left alone: opening that port to anything would publish the whole
admin interface along with the dashboard.

`/srv` rather than `/www` is the whole point. The pages first went to
`/www/kindle/`, which is inside the LuCI instance's document root, so the
Cloudflare tunnel in front of port 80 served them to the public for three days:
the weather page, the status page with the WAN address and the disk and service
readings, and the notes page. `/kindle/` even answered with a directory listing,
so the random directory name hid nothing. Purging the edge cache was part of
closing it — the origin returned 404 while Cloudflare went on serving `HIT`.

The router's own AP is 5 GHz, and the Kindle has no 5 GHz radio, so it sits on
the upstream router instead and arrives on the router's WAN side. The WAN zone
rejects input by default, so two narrow rules allow tcp/8081 from the two
upstream subnets and nothing else. Their packet counters are the quickest way
to tell whether a fetch is even reaching the router:

```bash
ssh Nano-tunnel 'nft -a list chain inet fw4 input_wan | grep kindle-dash'
```

Untracked on purpose: `env` (QWeather credentials, mode 600),
`/root/kindle-dash/fonts/NotoSansSC-{Regular,Bold}.otf` (16 MB), and the
runtime files LuCI writes.

## Traps

- **`build.sh` owns the cron schedule.** It rewrites its own line in
  `/etc/crontabs/root` to two minutes before every `WAKE_MINUTES` entry. Never
  set those minutes by hand; they will be overwritten on the next build.
- **Argon pads only a section's first heading.** The theme sets
  `.cbi-section{padding:0}`, so anything after the `h3` sits flush against the
  card edge and a `width:100%` textarea overflows it. A hand-written view has
  to supply its own gutter — `.kd-body`, at the same `1.25rem`.
- **Editing the LuCI view can be invisible.** `/luci-static/` URLs carry no
  version token, so an edited file keeps its URL. Two Cloudflare rules scoped
  to `wrt.phpz.org` + `/luci-static/*` now force revalidation; before them the
  edge and the browser served the old file for four hours and a hard reload
  could not reach past the edge. Logging out and back in never helps: that only
  refreshes the dynamic `/cgi-bin/luci/` HTML.
- **An ACL change needs `/etc/init.d/rpcd restart`.** A view or menu change
  does not.
- **`uv` is only on the work Mac.** The router and `7-mm` run the system
  `python3` with Pillow installed system-wide, which is why `gen.py` has a
  plain `python3` shebang. `uv run gen.py` still reads the inline PEP 723
  metadata, so both paths work where they are used.
- **The ACL names fixed paths.** Anything the view reads has to be copied to a
  stable path under `/root/kindle-dash/`, the way `build.sh` publishes
  `last-build`, `pages` and `preview-N.png`, rather than reached through
  `serve-dir`. The previews are read with `fs.read_direct(path, 'blob')`, which
  goes through `cgi-io` and so needs `"cgi-io": [ "exec" ]` in the ACL as well.
- **Nothing the dashboard writes may live under a document root.** See above;
  it is the one mistake here that had consequences outside the project.
- **An object URL inherits the blob's MIME type.** `cgi-download` answers with
  `application/octet-stream`, so a preview opened in its own tab downloads
  instead of rendering. Re-wrap: `new Blob([blob], { type: 'image/png' })`.
  The `<img>` itself never cared.
- **Never reload the firewall on this router.** OpenClash inserts its rules
  into `inet fw4` at runtime, and `/etc/init.d/firewall reload` flushes the
  table and takes them with it. Add rules with `nft insert` for immediate
  effect and write the matching `uci` rule for persistence, without reloading.
- **An `nft` comment cannot contain a space.** The command line is re-parsed,
  so a comment of two words dies with a syntax error pointing at the second
  one. Use a single token; the rules here are `kindle-dash-0` and
  `kindle-dash-1`.
- **The worker hot-reloads, the device does not need rebooting.** It compares
  its own checksum each cycle and re-executes when the file changes, so
  deploying a new one is: plug in, copy, unplug, wait one cycle. This matters
  because with the framework stopped the power button shows no restart menu —
  that menu is drawn by the framework — and the only way out is holding power
  for about twenty seconds.
- **USB and the loop are mutually exclusive.** In USB drive mode `/mnt/us` is
  detached on the device side, so the loop can neither fetch nor log, and its
  log appears to stop mid-sentence. Attaching USB also keeps the device from
  suspending. Anything timing-related has to be tested with the cable out.
- **Do not infer a failed suspend from a short sleep.** Pressing the power
  button right after the device suspends produces one too; an early version
  treated that as a failure and silently ate every press made within the first
  ten seconds. The exit status of the write to `/sys/power/state` is the actual
  signal.

## Checks worth running after a change

```bash
sh -n build.sh device/*.sh                 # shell syntax
node --check nano/luci/view/kindle-dash/dash.js
ssh Nano-tunnel '/root/kindle-dash/build.sh'   # exit 0, and read the stderr
git grep -nE '192\.168|<the device mac>'       # nothing host-specific lands here
```
