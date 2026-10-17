#!/usr/bin/env python3
"""Build the JSON for the notes page from a plain text file.

The file is meant to be edited directly, so the format is deliberately loose:

    # 备忘              <- the first '#' line becomes the page title
    - [ ] 买咖啡豆       <- an unticked checkbox
    - [x] 续签域名       <- ticked: the row is struck through and dimmed
    - 买咖啡豆           <- plain bullet, no checkbox
    续签域名 | 11-20     <- '|' splits a row into left and right
    ## 本周              <- any later '#' line becomes a heading inside the page
    空行被忽略

Everything else is taken verbatim as a left-aligned row.
"""

from __future__ import annotations

import json
import os
import re
import sys
from datetime import datetime
from pathlib import Path

WEEKDAYS = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
SRC = Path(os.environ.get("DASH_NOTES", "/root/kindle-dash/notes.txt"))


def _status(rows) -> list:
    items = [r for r in rows if "h" not in r]
    tasks = [r for r in items if r.get("box")]
    if not tasks:
        return [f"{len(items)} 条"]
    done = sum(1 for r in tasks if r.get("done"))
    return [f"{done} / {len(tasks)} 完成"]


def build() -> dict:
    now = datetime.now()
    title = "备忘"
    seen_title = False
    rows = []

    if SRC.exists():
        for raw in SRC.read_text(encoding="utf-8").splitlines():
            line = raw.strip()
            if not line:
                continue
            if line.startswith("#"):
                heading = line.lstrip("#").strip()
                if not seen_title:
                    # The first '#' names the page; later ones split it into
                    # sections, which is what people actually write.
                    title = heading or title
                    seen_title = True
                elif heading:
                    rows.append({"h": heading})
                continue
            line = line.lstrip("-*").strip()

            # Markdown task syntax. Anything else stays a plain row, so the page
            # can mix a checklist with ordinary notes.
            box = None
            m = re.match(r"^\[([ xX])\]\s*(.*)$", line)
            if m:
                box = m.group(1).lower() == "x"
                line = m.group(2).strip()

            left, sep, right = line.partition("|")
            row = {"l": left.strip(), "r": right.strip() if sep else ""}
            if box is not None:
                row["box"] = True
                row["done"] = box
            rows.append(row)
    else:
        rows.append({"l": f"{SRC} 不存在", "r": ""})

    return {
        "date": f"{now.month}月{now.day}日 {WEEKDAYS[now.weekday()]}",
        "updated": now.strftime("%H:%M"),
        "title": title,
        "rows": rows,
        "status": _status(rows),
    }


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "-"
    text = json.dumps(build(), ensure_ascii=False, indent=1)
    if out == "-":
        print(text)
    else:
        Path(out).write_text(text + "\n", encoding="utf-8")
        print(f"wrote {out}", file=sys.stderr)
