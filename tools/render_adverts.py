#!/usr/bin/env python3
"""Turn test/render_adverts.lua's dumps into PNGs. Run from the repo root, after the lua harness:
      luajit test/render_adverts.lua && python tools/render_adverts.py
   Each subpixel becomes an 8x8 block so the result is legible at a glance."""
from PIL import Image

# CC:Tweaked's DEFAULT palette, colour number -> RGB (the stock 16). Any slot an advert redefined
# via setPaletteColour is overridden per-screen from the dump's "P" section, because the two adverts
# reuse the same slot NUMBERS for different gradients (the slot's blue->teal vs the cage's green->gold).
DEFAULT = {
    1: (240, 240, 240), 2: (242, 178, 51), 4: (229, 127, 216), 8: (153, 178, 242),
    16: (222, 222, 108), 32: (127, 204, 25), 64: (242, 178, 204), 128: (76, 76, 76),
    256: (153, 153, 153), 512: (76, 153, 178), 1024: (178, 102, 229), 2048: (51, 102, 178),
    4096: (127, 102, 76), 8192: (57, 123, 68), 16384: (204, 76, 76), 32768: (17, 17, 17),
}
SCALE = 8

for name in ("slot-advert", "cage-advert"):
    with open(name + ".txt") as f:
        w, h = (int(n) for n in f.readline().split())
        # palette section: "P <count>", then <count> lines of "<slot> <r> <g> <b>"
        pal = dict(DEFAULT)
        header = f.readline().split()
        assert header[0] == "P", f"{name}: expected a 'P' palette header, got {header!r}"
        for _ in range(int(header[1])):
            slot, r, g, b = (int(v) for v in f.readline().split())
            pal[slot] = (r, g, b)
        rows = [[int(v) for v in line.strip().split(",")] for line in f if line.strip()]
    assert len(rows) == h, f"{name}: expected {h} rows, got {len(rows)}"
    img = Image.new("RGB", (w * SCALE, h * SCALE))
    px = img.load()
    for y in range(h):
        for x in range(w):
            r, g, b = pal.get(rows[y][x], (255, 0, 255))   # magenta = an unmapped colour: a bug
            for dy in range(SCALE):
                for dx in range(SCALE):
                    px[x * SCALE + dx, y * SCALE + dy] = (r, g, b)
    out = f"docs/mockups/{name}.png"
    img.save(out)
    print("wrote", out)
