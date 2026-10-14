#!/usr/bin/env python3
"""Fetch QWeather data and emit the JSON that gen.py renders.

Only the standard library is used, because this runs on an OpenWrt router.
Credentials come from the environment:

    QWEATHER_API_HOST   e.g. xxxxxxxxxx.re.qweatherapi.com (account specific)
    QWEATHER_API_KEY
    QWEATHER_LOCATION   QWeather location id, e.g. 101280601
    QWEATHER_LAT/_LON   optional; only the air quality endpoint needs coordinates

The free developer plan covers /v7/weather/{now,24h,7d} and
/airquality/v1/current. The older /v7/air/now is not included, so air quality
is read from the coordinate-based endpoint instead.
"""

from __future__ import annotations

import gzip
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime

WEEKDAYS = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
TIMEOUT = 20


def icon_for(code: str | int) -> str:
    """Map a QWeather icon code onto one of gen.py's five glyphs."""
    try:
        c = int(code)
    except (TypeError, ValueError):
        return "cloud"
    if c == 100:
        return "sun"
    if c == 150:            # 晴, night variant
        return "moon"
    if c in (101, 102, 103, 151, 152, 153):
        return "partly"
    if 300 <= c < 400:
        return "rain"
    if 400 <= c < 500:
        return "snow"
    return "cloud"  # overcast, fog, haze, sand, and anything unknown


def api(path: str, **params) -> dict:
    host = os.environ["QWEATHER_API_HOST"]
    params["key"] = os.environ["QWEATHER_API_KEY"]
    url = f"https://{host}{path}?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={
        "Accept-Encoding": "gzip",
        "User-Agent": "kindle-dash/1.0",
    })
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        raw = r.read()
        if r.headers.get("Content-Encoding") == "gzip":
            raw = gzip.decompress(raw)
    return json.loads(raw)


def require_ok(doc: dict, label: str) -> dict:
    code = doc.get("code")
    # The air quality endpoint has no "code" field; it reports errors instead.
    if code not in (None, "200") or "error" in doc:
        raise SystemExit(f"{label}: QWeather returned {code or doc.get('error')}")
    return doc


def day_label(fx_date: str, today: datetime) -> str:
    d = datetime.strptime(fx_date, "%Y-%m-%d")
    delta = (d.date() - today.date()).days
    if delta == 0:
        return "今天"
    if delta == 1:
        return "明天"
    if delta == 2:
        return "后天"
    return WEEKDAYS[d.weekday()]


def build() -> dict:
    loc = os.environ.get("QWEATHER_LOCATION")
    if not loc:
        raise SystemExit("set QWEATHER_LOCATION to a QWeather location id")
    now_doc = require_ok(api("/v7/weather/now", location=loc), "now")
    h24 = require_ok(api("/v7/weather/24h", location=loc), "24h")
    d7 = require_ok(api("/v7/weather/7d", location=loc), "7d")

    cur = now_doc["now"]
    today = datetime.now()
    days = d7["daily"]

    # Four forecast points spread over the next ~12 hours.
    hourly = []
    for h in h24["hourly"][2::3][:4]:
        t = datetime.fromisoformat(h["fxTime"])
        hourly.append({"h": f"{t.hour}时", "t": int(h["temp"]), "icon": icon_for(h["icon"])})

    daily = [
        {
            "d": day_label(x["fxDate"], today),
            "icon": icon_for(x["iconDay"]),
            "hi": int(x["tempMax"]),
            "lo": int(x["tempMin"]),
            "cond": x["textDay"],
        }
        for x in days[1:5]
    ]

    cards = []
    lat, lon = os.environ.get("QWEATHER_LAT"), os.environ.get("QWEATHER_LON")
    if lat and lon:
        try:
            air = api(f"/airquality/v1/current/{lat}/{lon}")
            idx = next((i for i in air.get("indexes", []) if i.get("code") == "cn-mee"), None)
            if idx:
                cards.append({"label": f"空气质量 {idx['name']}",
                              "value": f"{idx['aqiDisplay']} {idx['category']}"})
        except (urllib.error.URLError, OSError, KeyError, ValueError) as e:
            # Air quality is a nice-to-have; never fail the whole render for it.
            print(f"air quality unavailable: {e}", file=sys.stderr)

    cards.append({"label": "湿度", "value": f"{cur['humidity']}%"})
    cards.append({"label": "风", "value": f"{cur['windDir']} {cur['windScale']} 级"})
    cards.append({"label": "日落", "value": days[0].get("sunset", "--")})

    obs = datetime.fromisoformat(cur["obsTime"])
    return {
        "date": f"{today.month}月{today.day}日 {WEEKDAYS[today.weekday()]}",
        "updated": datetime.now().strftime("%H:%M"),
        "weather": {
            "now": {"temp": int(cur["temp"]), "cond": cur["text"], "icon": icon_for(cur["icon"])},
            "high": int(days[0]["tempMax"]),
            "low": int(days[0]["tempMin"]),
            "hourly": hourly,
            "daily": daily,
        },
        "cards": cards,
        "status": [f"体感 {cur['feelsLike']}°", f"观测 {obs.strftime('%H:%M')}", "和风天气"],
    }


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "-"
    data = build()
    text = json.dumps(data, ensure_ascii=False, indent=1)
    if out == "-":
        print(text)
    else:
        with open(out, "w", encoding="utf-8") as f:
            f.write(text + "\n")
        print(f"wrote {out}", file=sys.stderr)
