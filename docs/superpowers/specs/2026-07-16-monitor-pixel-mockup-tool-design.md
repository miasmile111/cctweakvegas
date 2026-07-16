# Monitor Pixel Mockup Tool — design

- **Date:** 2026-07-16
- **Status:** spec (self-checked)
- **Kind:** browser-only dev tool (single self-contained HTML file). NOT a CC:Tweaked program;
  it never runs in-game and is not part of the `src/` deploy loop.
- **Related:** `docs/monitor-resolution-lesson.html` (the resolution model this tool operationalises),
  `src/lib/subpixel.lua` (the runtime this tool mirrors), `kb/economy.md`, `cc-lua` skill `kb/monitor-ui.md`.

## Problem

Communicating a monitor UI layout in words is slow and lossy ("move the header down a bit", "make
the reels wider"). The medium is pixel art on a constrained grid. A visual editor that speaks the
**exact** CC:Tweaked pixel model lets the user *draw* an intended screen, and lets Claude *read* that
drawing back and regenerate faithful Lua — closing the design loop without prose round-trips.

## Users & success criteria

- **Primary user:** the project owner, drawing whole-screen game mockups.
- **Primary reader:** Claude, consuming the export to regenerate `subpixel.lua`-based draw code.
- **Success:** the user paints a screen; the exported JSON is enough for Claude to recreate the layout
  (region positions, colours, text intent) with no verbal description; the live preview never lies
  about what the monitor can actually show.

## The model this tool must honour (from the lesson, verified)

- A monitor is a grid of **character cells**; `getSize()` reports it in cells.
- 1 cell = **6×9 real pixels**. Teletext chars 128–159 split a cell into a **2×3** grid of subpixels
  (each subpixel = **3×3 real px**). A cell shows **at most 2 colours** (a fg and a bg).
- The finest addressable unit is the **subpixel**. The tool's paintable canvas is therefore
  `subW = cols·2` by `subH = rows·3` subpixels.
- `encodeCell` (ported from `subpixel.lua`) collapses each 2×3 group of subpixels to 2 colours:
  most-frequent → background; first-different → foreground; **every remaining subpixel renders as
  background** — a third+ colour is simply "not the foreground", so it takes the bg colour. The cell
  only ever emits two colours (verified against `subpixel.lua`: `low5` counts positions equal to `fg`;
  everything else falls to `bg`, with the bottom-right invert trick to reach the 6th position).

## Scope — v1 features

1. **Monitor configuration**
   - Authoritative inputs: `cols` × `rows` (what `getSize()` returns in-world). Canvas derives
     `subW = cols·2`, `subH = rows·3`.
   - Optional: `blocksW` × `blocksH` — drive (a) block-seam guides (even divisions of the canvas —
     the seam/bezel *positions* are approximate, verify in-world) and (b) a **"max res"** button that
     sets cols/rows to the exact terminal size for that block layout at scale 0.5 (the finest). The
     block→cell count formula IS known (verified from CC:Tweaked `ServerMonitor.rebuild()`):
     `cells = max(1, round((blocks − 0.3125) / (scale · font/64)))`, font `6` wide / `9` tall,
     `0.3125 = 2·(RENDER_BORDER 2/16 + RENDER_MARGIN 0.5/16)`, `RENDER_PIXEL_SCALE 1/64`. So the cell
     count is exact; only the physical bezel *position* between blocks stays approximate. E.g. slot
     `1×2 @ 0.5 = 15×24`. Default seams off.
   - Sensible presets (e.g. "slot 1×2 @0.5 ≈ 15×21") as convenience buttons; all editable.
   - Guard: clamp cols/rows to a sane range (e.g. 1..200) to keep the buffer bounded.

2. **Painting**
   - Freeform: any of 16 palette colours OR transparent, at any subpixel. Mirrors `subpixel.lua`
     (which lets any colour sit at any subpixel; the constraint is applied only at encode time).
   - Buffer value per subpixel: `0..15` colour index, or `-1` = transparent.

3. **Live CC preview**
   - A second view renders the buffer through `encodeCell` — exactly what the monitor would show.
   - Toggle between side-by-side and overlay; the preview is the source of truth for "how it looks".

4. **Palette**
   - 16 slots, each an editable RGB (default = CC:Tweaked default palette). Editing a slot recolours
     every subpixel using it live (mirrors `setPaletteColour`). Plus a transparent selector.
   - Palette travels in the export (so Claude gets the exact intended RGB, incl. custom gradients).

5. **Tools**
   - Brush: paints the current colour; **size in subpixels** (1..N), square footprint.
   - Eraser: paints transparent (size like brush).
   - Bucket fill: flood-fill contiguous same-value region.
   - Eyedropper: pick the colour under the cursor as current.
   - Rectangle: filled or outline, current colour.
   - Undo / redo (bounded history stack). Clear canvas (to transparent).

6. **Overlays** (independent toggles)
   - Cell grid (2×3 subpixel blocks) — the primary ruler.
   - Subpixel grid.
   - Real-pixel grid (each subpixel = 3×3), shown when zoomed enough.
   - Block-seam guides (approximate, from blocksW×H).

7. **Text regions** (tagged, no font)
   - Drag a rectangle that **snaps to the cell grid**; tag it with a string plus fg/bg colour picks.
   - Rendered in the editor as a labelled box (the string drawn with the browser font as a stand-in),
     NOT as CC glyphs. It marks "these cells are text saying X in these colours".
   - Travels in the export as structured data so Claude knows text vs art per region.

8. **Export / import**
   - **Export JSON** (the authoritative artifact — schema below): dims, palette, subpixel buffer,
     text regions, block config. A "copy to clipboard" and a "download .json".
   - **Export PNG**: the encoded-preview raster (so Claude can *see* it, and the user can share it).
   - **Import JSON**: load a previously exported file to keep editing (cheap; round-trips the state).

## Export JSON schema (v1)

```json
{
  "tool": "cc-monitor-mockup",
  "version": 1,
  "monitor": { "cols": 15, "rows": 21, "blocksW": 1, "blocksH": 2 },
  "canvas":  { "subW": 30, "subH": 63 },
  "palette": [ { "i": 0, "name": "white", "hex": "#f0f0f0" }, "... 16 entries ..." ],
  "pixels":  "run-length or flat array of subH*subW ints; -1 transparent, 0..15 colour index",
  "textRegions": [
    { "cellX": 1, "cellY": 1, "cellW": 13, "cellH": 2, "text": "Alice  240 MB", "fg": 0, "bg": 15 }
  ]
}
```

- `pixels` encoding: a flat row-major array (`subH` rows × `subW` cols) of ints is simplest for Claude
  to parse; run-length compression is an allowed optimisation if size becomes a problem. Coordinates
  are 1-based to match Lua / `subpixel.lua` conventions (top-left = (1,1)).
- Text region coords are in **cells** (1-based), matching `setCursorPos`.

## Architecture

Single self-contained `.html` file (inline CSS + JS, no external requests — same constraints as an
Artifact). Vanilla JS, `<canvas>` for rendering. No build step. Internal modules (plain closures/objects):

- **state** — `cols, rows, subW, subH, buf (Int8Array or nested), palette[16], textRegions[], blocks, history`.
- **palette** — defaults, slot RGB editing, transparent handling.
- **encode** — faithful `encodeCell` port (unit-checkable against known `subpixel.lua` cases).
- **render** — draws the paint view and the encoded preview + overlays to canvas; hi-dpi aware,
  `image-rendering: pixelated`. Redraw on state change; keep it O(cells) per frame.
- **tools** — brush/eraser/bucket/eyedropper/rect; pointer handling maps device px → subpixel coords.
- **text** — rectangle drag on the cell grid, snap, tag editing.
- **io** — export JSON/PNG, import JSON, clipboard.

Reuse the lesson's rendering approach (coordinate math, cell/subpixel/realpx overlays) — it is already
verified to render the three grids correctly.

## Error handling & robustness

- Clamp monitor dims; refuse degenerate sizes; warn (don't crash) on oversized canvases.
- Import: validate `tool`/`version`; on malformed JSON show a clear inline error, don't wipe current work.
- Undo history bounded (e.g. last 50 ops) to cap memory.
- Respect `prefers-reduced-motion`; keyboard-operable tool buttons with visible focus; both colour themes.
- No fabricated exactness: block seams and any scale-derived numbers are labelled approximate.

## Testing

Browser tool → primarily manual, with a scripted checklist:

- **encodeCell parity:** a small set of hand-verified 2×3 inputs whose expected (char/fg/bg) match
  `subpixel.lua` (incl. the bottom-right invert case). Runnable as an in-page self-test panel that
  prints pass/fail, so parity with the runtime is provable without a separate harness.
- Paint → export → import round-trip reproduces the buffer exactly.
- Palette edit recolours live; transparent exports as `-1`.
- Overlays toggle independently; preview matches `encodeCell` on a known clash case (Fig 04 scenario).

## Non-goals (v1 — parked)

- Real CC-glyph font rendering for text (tagged regions only).
- Layers, animation/palette-drift preview, onion-skinning.
- Exact block-seam math (needs in-world measurement / source formula).
- Direct in-game deploy or Lua-file writing from the tool (Claude regenerates code from the export).
- Sprite-cropping / asset-authoring mode (whole-screen only for v1; could add later).

## Open questions (non-blocking)

- Does Claude prefer flat vs run-length `pixels`? Start flat; revisit if exports get unwieldy.
- Should presets include measured real `getSize()` values once known? Add the slot's after in-world check.
