---
title: Monitor-UI build workflow — mockup → HTML preview → Lua → deploy (the golden standard)
area: monitor-ui
verified: in-game 2026-07-16 (slot v3 built this way end-to-end)
tags: [workflow, ui, mockup, preview, html, artifact, subpixel, pixelfont, encodeCell, iterate, deploy, font, text, verify, offline, png]
---

# Building a monitor UI here — the golden-standard loop

Set as the standard for **all** monitor-UI work in this project (owner's call, 2026-07-16). It exists
because the deploy loop is slow (raw-CDN ~5 min cache, see [[deploy-and-identity]]), so *seeing* the
screen before it ships is worth a lot. Slot v3 was built this way and it worked far better than
editing Lua and screenshotting in-world each round.

## The loop

1. **Owner draws the screen** in `tools/monitor-mockup.html` (browser subpixel pixel-art editor:
   paint at 15×24 cells / 30×72 subpixels, tag cell-grid **text regions**, RGB-edit the palette).
   Exports **JSON** (source of truth) + PNG to `~/Downloads/mockup*.json` — **newest suffix = latest**
   (`mockup(2).json` beats `mockup(1).json`). Copy the chosen one into `docs/mockups/`.
2. **Claude decodes it** — don't eyeball, decode:
   - per-cell **dominant colour** grid (Python: for each cell, most-common of its 2×3 subpixels) → the
     band layout (bars, windows, fills).
   - the **`textRegions`** list → each is a *narrated* element (`<win_amount>`, `bulb animation`,
     `WIN CELEBRATION`, stake buttons…). These are annotations, not literal text.
   - **⚠ dominant-colour misses sparse art.** White font pixels on a blue cell are a minority → the
     cell reads "blue", so a hand-drawn **custom font** won't show in the dominant grid. To copy a
     glyph, dump the **raw subpixels** of its rows (`'#' if px==white else '.'`) and read the bitmap
     directly. That's how the exact `WIN:` (W 5×4, I 3×4, N 4×4) + slashed digits were lifted.
3. **Build/refresh the live preview** `tools/slot-preview.html` — a self-contained page that renders
   the **actual Lua layout**: the same band math, the real symbol sprites, the `pixelfont` glyphs, and
   a right-hand **`encodeCell` panel** showing the 2-colour-per-cell monitor truth (port of
   `subpixel.lua`'s `encodeCell`). Native cell-text (header, stake labels) is drawn as a browser
   overlay on top — because native `write` is **not** subpixel and not subject to `encodeCell`
   (mirrors real CC: the subpixel canvas renders, then `topWin.write` layers on top). Publish it as an
   **Artifact** and/or open the file; iterate with the owner right there (tweak → see → tweak), no deploy.
4. **Port the finished design to Lua** — layout constants become a `topLayout` band table
   (`Rl(row)=(row-1)*3+1`, **1-indexed** in Lua vs 0-indexed in the JS preview — the classic port bug),
   fonts become a `lib/pixelfont`-style module, animations become the play-loop.
5. **Verify offline before deploying** — render the real Lua subpixel layer to a PNG **without the
   game**: a tiny luajit harness that `require`s the actual `subpixel.lua` + `pixelfont.lua` +
   `slot_symbols.lua`, calls the draw code into a canvas backed by a stub target
   (`{getSize=…, setCursorPos=…, blit=…}`), dumps `cv.buf`, and a Python/PIL script colours it up.
   This caught real bugs (amount overlapping the red bar, a stray corner bulb, off-by-ones) with **zero**
   deploy cycles. (Gotchas: luajit `io.open` wants a Windows path, not `/c/…`; write to the cwd. Native
   overlays aren't in `cv.buf`, so the PNG shows the subpixel layer only — reason about native text
   separately.)
6. **Deploy** (`git push` → in-world `update <pkg>`, mind the CDN lag), screenshot, fix any last pixel.

## Text: native vs subpixel font (decide per element)

A cell renders **either** a native CC glyph **or** subpixel art — not both, and a cell is 2 colours
either way (see [[monitor-resolution]]).

- **Native `topWin.write`** — 1 char = 1 cell = 2 subpixels wide but a legible 6-px glyph. **Densest**
  option; use it for **long strings** (a `<id>: <bal> MB` header, `$100` in a 4-cell button). But it's
  **cell-locked**: text starts on a cell boundary, so you **cannot** centre to the sub-cell or straddle
  two cells. Set its `background` to whatever fill sits under it so it looks seamless.
- **Subpixel bitmap font** (`lib/pixelfont`) — you draw glyphs pixel-by-pixel into the canvas. Gives
  **pixel-precise centring, sub-cell placement, any size, and text that rides the gradient**. Costs
  **density** (a legible glyph is ~3–5 subpixels wide → fewer chars across) and a glyph set to author.
  Use it for **short, precise, or large** text (`WIN:`, the big count-up amount, centred labels).
- A **`"$"` needs no extra colours** — as a subpixel glyph it's just white `fg` over the fill, same 2
  colours as any digit. The real constraint is glyph **width** (fitting `$100` in a 4-cell button), not
  colour. Don't reach for "another colour" when the problem is pixels-per-character.

## Reusable pieces

- `tools/monitor-mockup.html` — the editor (owner draws here). `tools/slot-preview.html` — the live
  preview/renderer (Claude maintains; the design surface). Neither is in the `src/` deploy loop.
- `src/lib/subpixel.lua` — the teletext canvas (`encodeCell`, `setPixel` floors + bounds-checks).
- `src/lib/pixelfont.lua` — pure bitmap fonts (WIN: label + slashed big-number digits) + draw helpers
  (`drawText`/`drawCentered`/`textWidth`); unit-tested (`test/test_pixelfont.lua`). Extend its glyph
  tables for new labels/sizes.
- A symbol sprite is **8×9 subpixels = 4×3 cells** (3 cells tall — can't shrink to 2 without redrawing).

## Related

- [[monitor-resolution]] — the cell/subpixel/px model + exact size formula (read first).
- [[monitor-ui]] — the graphics pitfalls (watchdog, fractional coords, palette animation, clipping, flicker).
- `docs/slot-v3-mockup-handoff.md`, `docs/superpowers/specs/2026-07-16-slot-v3-design.md` — the worked example.
