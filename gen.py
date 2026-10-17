#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow>=10"]
# ///
"""Render the dashboard image for a Kindle 7 (KT2, firmware 5.12.2.2).

fbink reports the panel as 600x800, 8bpp, Y8 at 167 dpi, so the native layout is
portrait. --rotate exists for mounting the device on its side: the portrait
layout is rotated as a whole, which keeps the text upright for the viewer.

Sections flow top to bottom and are skipped when their data is absent, so the
same layout code handles "weather only" and "weather plus everything else".

Output is 8-bit greyscale with no alpha, which is what `fbink -g file=` wants.
"""

from __future__ import annotations

import argparse
import json
import math
import os
from datetime import datetime
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

W, H = 600, 800
MARGIN = 26
HEADER_H = 64
FOOTER_H = 52

BLACK, WHITE = 0, 255
DIM = 90   # secondary text; E-Ink Pearl contrast is poor, so stay dark
RULE = 160
HAIRLINE = 215

WEEKDAYS = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]

# Each candidate is a (regular, bold) pair of (path, face index). Noto Sans SC
# ships as separate files; the macOS collections need a face index.
FONT_CANDIDATES = [
    (("/root/kindle-dash/fonts/NotoSansSC-Regular.otf", 0),
     ("/root/kindle-dash/fonts/NotoSansSC-Bold.otf", 0)),
    (("/System/Library/Fonts/Hiragino Sans GB.ttc", 0),
     ("/System/Library/Fonts/Hiragino Sans GB.ttc", 1)),
    (("/System/Library/Fonts/PingFang.ttc", 2),
     ("/System/Library/Fonts/PingFang.ttc", 4)),
    (("/System/Library/Fonts/Supplemental/Songti.ttc", 0),
     ("/System/Library/Fonts/Supplemental/Songti.ttc", 1)),
]

_font_cache: dict[tuple[int, bool], ImageFont.FreeTypeFont] = {}
_font_pair: tuple[tuple[str, int], tuple[str, int]] | None = None


def _resolve_fonts():
    global _font_pair
    if _font_pair is not None:
        return _font_pair

    reg_env = os.environ.get("KINDLE_DASH_FONT_REGULAR")
    bold_env = os.environ.get("KINDLE_DASH_FONT_BOLD")
    candidates = list(FONT_CANDIDATES)
    if reg_env:
        candidates.insert(0, ((reg_env, 0), (bold_env or reg_env, 0)))

    for reg, bold in candidates:
        try:
            ImageFont.truetype(reg[0], 20, index=reg[1])
            ImageFont.truetype(bold[0], 20, index=bold[1])
        except OSError:
            continue
        _font_pair = (reg, bold)
        return _font_pair
    raise SystemExit("no usable CJK font found; set KINDLE_DASH_FONT_REGULAR/_BOLD")


def font(size: int, bold: bool = False) -> ImageFont.FreeTypeFont:
    key = (size, bold)
    if key not in _font_cache:
        path, index = _resolve_fonts()[1 if bold else 0]
        _font_cache[key] = ImageFont.truetype(path, size, index=index)
    return _font_cache[key]


def fit(d: ImageDraw.ImageDraw, text: str, f: ImageFont.FreeTypeFont, max_w: float) -> str:
    """Truncate text with an ellipsis so it fits within max_w pixels."""
    if d.textlength(text, font=f) <= max_w:
        return text
    while text and d.textlength(text + "…", font=f) > max_w:
        text = text[:-1]
    return text + "…"


# --- weather glyphs -------------------------------------------------------
# Drawn from primitives. Strokes scale with the glyph and never go below 2px,
# because hairlines wash out on this panel.

def _sun(d, x, y, s, stroke):
    r = s * 0.26
    cx, cy = x + s / 2, y + s / 2
    d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=BLACK, width=stroke)
    for i in range(8):
        a = i * math.pi / 4
        d.line([cx + math.cos(a) * r * 1.5, cy + math.sin(a) * r * 1.5,
                cx + math.cos(a) * r * 2.0, cy + math.sin(a) * r * 2.0],
               fill=BLACK, width=stroke)


def _cloud(d, x, y, s, stroke, fill=None):
    w, h = s, s * 0.6
    d.ellipse([x + w * .04, y + h * .34, x + w * .46, y + h * 1.0], fill=fill, outline=BLACK, width=stroke)
    d.ellipse([x + w * .26, y + h * .04, x + w * .78, y + h * .86], fill=fill, outline=BLACK, width=stroke)
    d.ellipse([x + w * .56, y + h * .38, x + w * .98, y + h * 1.0], fill=fill, outline=BLACK, width=stroke)
    d.rectangle([x + w * .16, y + h * .66, x + w * .86, y + h * .98], fill=fill or WHITE)
    d.line([x + w * .14, y + h * .98, x + w * .88, y + h * .98], fill=BLACK, width=stroke)


def _fall(d, x, y, s, stroke, kind):
    for i in range(3):
        bx, by = x + s * (0.22 + i * 0.24), y + s * 0.66
        if kind == "rain":
            d.line([bx + s * .06, by, bx - s * .02, by + s * .26], fill=BLACK, width=stroke)
        else:
            r = s * .05
            d.ellipse([bx - r, by + s * .1 - r, bx + r, by + s * .1 + r], fill=BLACK)


def _moon(d, x, y, s, stroke):
    # A solid crescent: a filled disc with a second, offset disc knocked out of
    # it. Solid shapes stay legible at small sizes on this panel; outlines do not.
    r = s * 0.30
    cx, cy = x + s / 2, y + s / 2
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=BLACK)
    o = r * 0.66
    d.ellipse([cx - r + o, cy - r - o * 0.3, cx + r + o, cy + r - o * 0.3], fill=WHITE)


def glyph(d, kind: str, x: float, y: float, s: float) -> None:
    stroke = max(2, round(s / 22))
    if kind == "moon":
        _moon(d, x, y, s, stroke)
    elif kind == "sun":
        _sun(d, x, y, s, stroke)
    elif kind == "partly":
        _sun(d, x + s * .3, y - s * .06, s * .6, stroke)
        _cloud(d, x, y + s * .3, s * .92, stroke, fill=WHITE)
    elif kind in ("rain", "snow"):
        _cloud(d, x, y + s * .06, s * .92, stroke, fill=WHITE)
        _fall(d, x, y, s, stroke, kind)
    else:  # cloud / overcast
        _cloud(d, x + s * .1, y + s * .02, s * .74, stroke, fill=WHITE)
        _cloud(d, x, y + s * .3, s * .92, stroke, fill=WHITE)


# --- sections -------------------------------------------------------------
# Every section takes the current y and returns the y below itself, so absent
# data simply yields the space to whatever comes next.

def section_rule(d, y):
    d.line([MARGIN, y, W - MARGIN, y], fill=RULE, width=2)
    return y + 2


def draw_header(d, data):
    now = datetime.now()
    left = data.get("date") or f"{now.month}月{now.day}日 {WEEKDAYS[now.weekday()]}"
    d.text((MARGIN, HEADER_H / 2), left, font=font(32, bold=True), fill=BLACK, anchor="lm")
    d.text((W - MARGIN, HEADER_H / 2), f"更新 {data.get('updated') or now.strftime('%H:%M')}",
           font=font(24), fill=DIM, anchor="rm")
    return section_rule(d, HEADER_H)


def draw_now(d, wx, y):
    now = wx.get("now") or {}
    if not now:
        return y
    x0, right = MARGIN, W - MARGIN
    top = y + 20
    glyph(d, now.get("icon", "cloud"), x0, top + 6, 104)
    d.text((x0 + 124, top + 4), f"{now.get('temp', '--')}°",
           font=font(112, bold=True), fill=BLACK, anchor="la")
    d.text((right, top + 16), str(now.get("cond", "")), font=font(32), fill=BLACK, anchor="ra")
    d.text((right, top + 66), f"最高 {wx.get('high', '--')}°", font=font(24), fill=DIM, anchor="ra")
    d.text((right, top + 100), f"最低 {wx.get('low', '--')}°", font=font(24), fill=DIM, anchor="ra")
    return section_rule(d, top + 146)


def draw_hourly(d, hourly, y):
    hourly = (hourly or [])[:4]
    if not hourly:
        return y
    x0, right = MARGIN, W - MARGIN
    slot = (right - x0) / len(hourly)
    for i, h in enumerate(hourly):
        cx = x0 + slot * (i + .5)
        d.text((cx, y + 16), str(h.get("h", "")), font=font(23), fill=DIM, anchor="ma")
        glyph(d, h.get("icon", "cloud"), cx - 21, y + 48, 42)
        d.text((cx, y + 102), f"{h.get('t', '--')}°", font=font(29, bold=True), fill=BLACK, anchor="ma")
    return section_rule(d, y + 146)


def draw_daily(d, daily, y, max_rows=4):
    daily = daily or []
    if not daily or max_rows < 1:
        return y
    x0, right = MARGIN, W - MARGIN
    d.text((x0, y + 16), "未来几天", font=font(26, bold=True), fill=BLACK, anchor="la")
    y += 56
    row_h = 48
    for it in daily[:max_rows]:
        cy = y + row_h / 2
        d.text((x0, cy), str(it.get("d", "")), font=font(25), fill=BLACK, anchor="lm")
        glyph(d, it.get("icon", "cloud"), x0 + 96, y + 7, 34)
        d.text((x0 + 150, cy), f"{it.get('hi', '--')}° / {it.get('lo', '--')}°",
               font=font(25, bold=True), fill=BLACK, anchor="lm")
        d.text((right, cy), fit(d, str(it.get("cond", "")), font(24), 150),
               font=font(24), fill=DIM, anchor="rm")
        y += row_h
    return section_rule(d, y + 8)


def draw_agenda(d, items, y):
    items = items or []
    if not items:
        return y
    x0, right = MARGIN, W - MARGIN
    d.text((x0, y + 16), "日程", font=font(26, bold=True), fill=BLACK, anchor="la")
    d.text((right, y + 20), f"{len(items)} 项", font=font(22), fill=DIM, anchor="ra")
    y += 56
    row_h = 50
    room = int((H - FOOTER_H - 16 - y) // row_h)
    for it in items[:room]:
        cy = y + row_h / 2
        d.text((x0, cy), str(it.get("time", "")), font=font(25, bold=True), fill=BLACK, anchor="lm")
        tx = x0 + 92
        d.text((tx, cy), fit(d, str(it.get("title", "")), font(25), right - tx),
               font=font(25), fill=BLACK, anchor="lm")
        y += row_h
        d.line([x0, y - 3, right, y - 3], fill=HAIRLINE, width=1)
    if len(items) > room:
        d.text((x0, y + 12), f"还有 {len(items) - room} 项", font=font(22), fill=DIM, anchor="la")
        y += 40
    return section_rule(d, y + 8)


def draw_cards(d, cards, y):
    """Two-column label/value grid for whatever else is worth showing."""
    cards = cards or []
    if not cards:
        return y
    x0, right = MARGIN, W - MARGIN
    col_w = (right - x0) / 2
    row_h = 58
    room = int((H - FOOTER_H - 10 - (y + 14)) // row_h)
    rows = min(2, (len(cards) + 1) // 2, room)
    if rows < 1:
        return y
    for i, c in enumerate(cards[:rows * 2]):
        cx = x0 + col_w * (i % 2)
        cy = y + 14 + row_h * (i // 2)
        d.text((cx, cy), fit(d, str(c.get("label", "")), font(22), col_w - 12),
               font=font(22), fill=DIM, anchor="la")
        d.text((cx, cy + 26), fit(d, str(c.get("value", "")), font(28, bold=True), col_w - 12),
               font=font(28, bold=True), fill=BLACK, anchor="la")
    return y + 14 + row_h * rows


def draw_title(d, text, y):
    if not text:
        return y
    d.text((MARGIN, y + 16), str(text), font=font(28, bold=True), fill=BLACK, anchor="la")
    return y + 58


def checkbox(d, x, cy, size, ticked):
    """A square, with a tick when done. Drawn from primitives because the font
    may not carry box glyphs and because E-Ink needs a heavier stroke than one."""
    half = size / 2
    box = [x, cy - half, x + size, cy + half]
    d.rectangle(box, outline=BLACK, width=3)
    if ticked:
        d.line([x + size * 0.22, cy + size * 0.02,
                x + size * 0.42, cy + size * 0.26], fill=BLACK, width=4)
        d.line([x + size * 0.42, cy + size * 0.26,
                x + size * 0.80, cy - size * 0.28], fill=BLACK, width=4)


def draw_rows(d, rows, y, floor=None):
    """Full-width label/value rows. Used by the status and notes pages."""
    rows = rows or []
    if not rows:
        return y
    x0, right = MARGIN, W - MARGIN
    if floor is None:
        floor = H - FOOTER_H - 12
    row_h = 46
    start_y = y
    room = int((floor - y) // row_h)
    if room < 1:
        return y
    for it in rows[:room]:
        cy = y + row_h / 2
        if it.get("h"):
            # A heading inside the list: bold, no divider, and some air above it
            # so the sections actually read as separate.
            pad = 0 if y == start_y else 14
            d.text((x0, y + pad + row_h / 2), fit(d, str(it["h"]), font(26, bold=True), right - x0),
                   font=font(26, bold=True), fill=BLACK, anchor="lm")
            y += row_h + pad
            continue
        left = str(it.get("l", ""))
        rightside = str(it.get("r", ""))
        done = bool(it.get("done"))
        ink = DIM if done else BLACK

        tx = x0
        if it.get("box"):
            checkbox(d, x0, cy, 24, done)
            tx = x0 + 40

        f = font(25)
        rw = d.textlength(rightside, font=font(25, bold=True)) if rightside else 0
        shown = fit(d, left, f, right - tx - rw - 20)
        d.text((tx, cy), shown, font=f, fill=ink, anchor="lm")
        if done:
            # Strike the text itself, not the whole row: the rule is easier to
            # read against the row divider when it stops where the words do.
            w = d.textlength(shown, font=f)
            d.line([tx, cy + 1, tx + w, cy + 1], fill=ink, width=2)
        if rightside:
            d.text((right, cy), rightside, font=font(25, bold=True), fill=ink, anchor="rm")
            if done:
                d.line([right - rw, cy + 1, right, cy + 1], fill=ink, width=2)
        y += row_h
        d.line([x0, y - 3, right, y - 3], fill=HAIRLINE, width=1)
    if len(rows) > room:
        d.text((x0, y + 12), f"\u8fd8\u6709 {len(rows) - room} \u884c",
               font=font(22), fill=DIM, anchor="la")
        y += 38
    return y + 8


def draw_footer(d, chips):
    y = H - FOOTER_H
    d.line([MARGIN, y, W - MARGIN, y], fill=RULE, width=2)
    if not chips:
        return
    # Drop whole chips that do not fit rather than clipping one mid-glyph.
    f = font(23)
    sep = "   ·   "
    text = ""
    for c in chips:
        candidate = (text + sep if text else "") + str(c)
        if d.textlength(candidate, font=f) > W - 2 * MARGIN:
            break
        text = candidate
    d.text((MARGIN, y + FOOTER_H / 2), text, font=f, fill=BLACK, anchor="lm")


def render(data: dict) -> Image.Image:
    img = Image.new("L", (W, H), WHITE)
    d = ImageDraw.Draw(img)
    wx = data.get("weather") or {}
    y = draw_header(d, data)
    y = draw_now(d, wx, y)
    y = draw_hourly(d, wx.get("hourly"), y)

    # Reserve room for the cards before the daily rows claim it, so the two
    # sections cannot overlap the footer between them.
    cards = data.get("cards") or []
    cards_h = (14 + 58 * min(2, (len(cards) + 1) // 2)) if cards else 0
    floor = H - FOOTER_H - 10 - cards_h
    budget = floor - y - 64   # 64 = the daily heading
    y = draw_daily(d, wx.get("daily"), y, max_rows=max(0, int(budget // 48)))

    y = draw_agenda(d, data.get("agenda"), y)
    y = draw_title(d, data.get("title"), y)
    y = draw_rows(d, data.get("rows"), y, floor=floor)
    draw_cards(d, cards, y if y > floor else floor)
    draw_footer(d, data.get("status"))
    return img


DEMO = {
    "updated": "09:42",
    "weather": {
        "now": {"temp": 18, "cond": "多云转晴", "icon": "partly"},
        "high": 24, "low": 12,
        "hourly": [
            {"h": "12时", "t": 21, "icon": "sun"},
            {"h": "15时", "t": 23, "icon": "sun"},
            {"h": "18时", "t": 19, "icon": "partly"},
            {"h": "21时", "t": 14, "icon": "cloud"},
        ],
        "daily": [
            {"d": "明天", "icon": "partly", "hi": 24, "lo": 12, "cond": "多云"},
            {"d": "周五", "icon": "sun", "hi": 26, "lo": 14, "cond": "晴"},
            {"d": "周六", "icon": "rain", "hi": 19, "lo": 11, "cond": "小雨"},
            {"d": "周日", "icon": "cloud", "hi": 17, "lo": 10, "cond": "阴"},
        ],
    },
    "cards": [
        {"label": "空气质量 PM2.5", "value": "32 优"},
        {"label": "湿度", "value": "61%"},
        {"label": "风", "value": "东北 3 级"},
        {"label": "日落", "value": "17:52"},
    ],
    "status": ["电量 87%", "隧道 OK"],
}


def main() -> None:
    p = argparse.ArgumentParser(description="Render the Kindle dashboard PNG")
    p.add_argument("-o", "--out", default="out/dash.png")
    p.add_argument("-d", "--data", help="JSON file; omit to use the built-in demo data")
    p.add_argument("--bw", action="store_true", help="also write a dithered 1-bit version")
    p.add_argument("--rotate", type=int, default=0, choices=[0, 90, 180, 270],
                   help="rotate the finished image, for mounting the device on its side")
    args = p.parse_args()

    data = json.loads(Path(args.data).read_text(encoding="utf-8")) if args.data else DEMO
    img = render(data)
    if args.rotate:
        img = img.rotate(args.rotate, expand=True)

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    img.save(out, format="PNG", optimize=True)
    print(f"{out}  {img.size[0]}x{img.size[1]}  {img.mode}  {out.stat().st_size}B")

    if args.bw:
        bw = out.with_name(out.stem + "-1bit.png")
        img.convert("1").save(bw, format="PNG", optimize=True)
        print(f"{bw}  1-bit dithered  {bw.stat().st_size}B")


if __name__ == "__main__":
    main()
