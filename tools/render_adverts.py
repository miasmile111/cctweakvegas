#!/usr/bin/env python3
"""Turn test/render_adverts.lua's dumps into PNGs. Run from the repo root, after the lua harness:
      luajit test/render_adverts.lua && python tools/render_adverts.py
   Each subpixel becomes an 8x8 block so the result is legible at a glance."""
import sys
from PIL import Image

# CC:Tweaked's default palette, colour number -> RGB. Only the slots the adverts use are exact;
# the gradient slots (2048/512/8/1024/64) are repalette'd at runtime, so approximate them along the
# deep-blue -> teal ramp the way slot_style.gradientRGB does at phase 0.
PAL = {
    1: (240, 240, 240), 16: (222, 222, 108), 128: (76, 76, 76), 256: (153, 153, 153),
    8192: (57, 123, 68), 16384: (204, 76, 76), 32768: (17, 17, 17),
    2048: (0, 108, 156), 512: (0, 145, 156), 8: (0, 60, 156), 1024: (0, 175, 156), 64: (0, 30, 156),
}
SCALE = 8

for name in ("slot-advert", "cage-advert"):
    with open(name + ".txt") as f:
        w, h = (int(n) for n in f.readline().split())
        rows = [[int(v) for v in line.strip().split(",")] for line in f if line.strip()]
    assert len(rows) == h, f"{name}: expected {h} rows, got {len(rows)}"
    img = Image.new("RGB", (w * SCALE, h * SCALE))
    px = img.load()
    for y in range(h):
        for x in range(w):
            r, g, b = PAL.get(rows[y][x], (255, 0, 255))   # magenta = an unmapped colour: a bug
            for dy in range(SCALE):
                for dx in range(SCALE):
                    px[x * SCALE + dx, y * SCALE + dy] = (r, g, b)
    out = f"docs/mockups/{name}.png"
    img.save(out)
    print("wrote", out)
