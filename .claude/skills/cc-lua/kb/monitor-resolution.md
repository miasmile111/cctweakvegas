---
title: Monitor resolution — cell/subpixel/real-px model + exact block→cell formula
area: monitor-ui
verified: source (CC:Tweaked ServerMonitor.rebuild) 2026-07-16; glyph 6×9 cross-checked CraftOS-PC + CC font
tags: [monitor, resolution, getSize, setTextScale, subpixel, teletext, blocks, cells, formula, pixels]
---

# Monitor resolution — the three grids, and the exact block→cell formula

The foundational model for any monitor UI. Don't re-derive it — it's verified. A rich interactive
walkthrough lives at `docs/monitor-resolution-lesson.html`; this is the cheat-sheet.

## Three stacked grids

| Unit | Size | Address it via |
|------|------|----------------|
| **character cell** | **6×9 real pixels** (the CC font glyph) | `setCursorPos` + `write`/`blit` |
| **subpixel** (teletext) | **3×3 real px** (6/2 × 9/3, ~square) | chars **128–159**, a 2×3 grid per cell |
| **real pixel** | 1×1 | not directly — finest addressable = subpixel |

- `getSize()` reports the terminal in **cells**, not pixels.
- Teletext splits a cell into **2×3 = 6 subpixels**; a cell shows **at most 2 colours** (fg + bg).
  `src/lib/subpixel.lua` builds a `cols·2 × rows·3` subpixel canvas on this; `encodeCell` collapses each
  2×3 group to 2 colours (most-frequent → bg, first-different → fg, **everything else falls to bg**).
- The subpixel is nearly square (3×3), which is why subpixel art reads cleanly.

## setTextScale

- Range **0.5 – 5.0**, step **0.5** (`monitor.setTextScale`). **Smaller scale ⇒ more, smaller cells ⇒
  higher resolution.** `0.5` is the max. The slot runs at `0.5`.

## Exact terminal size (block layout + scale → cells)

Verified from CC:Tweaked `ServerMonitor.rebuild()` (constants in `MonitorBlockEntity`):

```
cols = max(1, round( (blocksW − 0.3125) / (scale · 6/64) ))
rows = max(1, round( (blocksH − 0.3125) / (scale · 9/64) ))

  0.3125 = 2·(RENDER_BORDER 2/16 + RENDER_MARGIN 0.5/16)
  6 = font width px, 9 = font height px, RENDER_PIXEL_SCALE = 1/64
  scale = the setTextScale value (0.5..5); 0.5 = max resolution
```

The cell count is therefore **exact**, not something you must read from `getSize()` (though `getSize()`
is the ground-truth confirmation). Only the physical **bezel position** between blocks stays a
rendering detail (the terminal itself is one continuous grid).

### Worked values @ scale 0.5 (max res)

| blocks | cells | subpixels (×2,×3) | real px (×6,×9) |
|--------|-------|-------------------|-----------------|
| 1×1 | 15×10 | 30×30 | 90×90 |
| **1×2 (slot)** | **15×24** | 30×72 | 90×216 |
| 2×1 | 36×10 | 72×30 | 216×90 |
| 2×2 | 36×24 | 72×72 | 216×216 |
| 3×2 | 57×24 | 114×72 | 342×216 |

> **Correction:** the slot 1×2 monitor at 0.5 is **15×24**, not the 15×21 first guessed before the
> formula was pulled. Width 15 was right; height is 24.

## Tooling

- `tools/monitor-mockup.html` — browser subpixel pixel-art editor; its "max res" button uses this
  formula; live `encodeCell` preview shows the 2-colour-per-cell truth. Draw → export JSON → regen Lua.
- `docs/monitor-resolution-lesson.html` — the interactive lesson (Fig 05 computes cells with this formula).

## Related

- [[monitor-ui]] — graphics pitfalls (watchdog, fractional-coord crash, palette animation, clipping, flicker).
- [[subpixel-drawing]] — the 2×3 teletext encoding (if/when split out of `subpixel.lua`).
