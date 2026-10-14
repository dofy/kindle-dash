# CLAUDE.md

Working notes for this repository. `README.md` documents the project; this file
records the state of the deployment and the traps that cost time to rediscover.

## Pending

**Before the next deploy of `device/dash-loop-worker.sh` to the Kindle, create
`/mnt/us/dash-site` on the device, over USB:**

```bash
echo http://<router>/kindle/<device-mac> > /mnt/us/dash-site
```

The address used to be hardcoded in the script and was removed when the
repository was made public. The Kindle currently runs its own older copy and
keeps working, so nothing is broken right now — but the new script exits
immediately without that file and writes the reason to
`/mnt/us/dash-loop.log`. The MAC is the directory name under `/www/kindle/` on
the router, also in `.serve-token` (untracked).

## Where it runs

- Router (`Nano` / `Nano-tunnel`, OpenWrt): generators and `build.sh` in
  `/root/kindle-dash/`, images published to `/www/kindle/<device-mac>/`, LuCI
  view at `/www/luci-static/resources/view/kindle-dash/dash.js`, menu and ACL
  under `/usr/share/luci/menu.d/` and `/usr/share/rpcd/acl.d/`.
- `7-mm`: development clone at `~/Works/Seven/kindle-dash`. The pre-git tree is
  parked next to it at `kindle-dash.pre-git` and can be deleted once nothing is
  missing from it.
- Kindle: `device/`, installed under `/mnt/us`.

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
  `last-build` and `pages`, rather than reached through `serve-dir`.

## Checks worth running after a change

```bash
sh -n build.sh device/*.sh                 # shell syntax
node --check nano/luci/view/kindle-dash/dash.js
ssh Nano-tunnel '/root/kindle-dash/build.sh'   # exit 0, and read the stderr
git grep -nE '192\.168|<the device mac>'       # nothing host-specific lands here
```
