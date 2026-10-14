# kindle-dash

Dashboard image generator for a Kindle 7 (Basic, 2014) — serial prefix `90C6`,
firmware 5.12.2.2, 6" 800x600 E-Ink Pearl, no frontlight, 256 MB RAM.

The device side of this setup (once jailbroken) just wakes on a timer, fetches a
PNG, pushes it to the panel with `eips -g`, and sleeps again. All layout work
happens here, on a machine that is always on.

## Render

```bash
uv run gen.py                      # built-in demo data -> out/dash.png
uv run gen.py -d data.sample.json  # render from a JSON file
uv run gen.py --bw                 # also write a dithered 1-bit variant
```

`uv` installs Pillow on demand from the inline PEP 723 metadata; nothing is
installed globally.

## Output format

800x600, 8-bit greyscale, no alpha — what `eips -g` expects. The `--bw` variant
is for comparing a Floyd-Steinberg 1-bit render on the real panel; Pearl does
support 16 grey levels, so the 8-bit file is normally the better choice.

## Design constraints

- No frontlight, so the panel is unreadable in the dark.
- Pearl contrast is poor: light greys disappear. Secondary text stays at `DIM`
  (90) and rules at `RULE` (160); nothing lighter carries meaning.
- 167 ppi is coarse. Body text is 24-27 px, the hero temperature 112 px.
- Hairlines wash out, so glyph strokes scale with glyph size and never go below
  2 px.

## Data contract

See `data.sample.json`. Weather icon names: `sun`, `partly`, `cloud`, `rain`,
`snow`. `date` and `updated` fall back to the current local time when absent.
Agenda rows past the available height collapse into a "还有 N 项" line.

## Fonts

Resolved at runtime from the first usable candidate: Hiragino Sans GB, PingFang,
then Songti. Override with `KINDLE_DASH_FONT=/path/to/font.ttc`.
