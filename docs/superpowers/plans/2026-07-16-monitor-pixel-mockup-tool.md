# Monitor Pixel Mockup Tool — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (inline) to implement
> this plan task-by-task. Single self-contained HTML file with shared canvas state → build cohesively
> inline, then a whole-file code-review pass. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A browser-only pixel-art editor that speaks CC:Tweaked's exact subpixel model, so the user
can draw a whole-monitor game mockup and Claude can read the export back to regenerate faithful Lua.

**Architecture:** One self-contained `.html` file (inline CSS+JS, no external requests). Vanilla JS +
`<canvas>`. A subpixel buffer (`subW=cols·2 × subH=rows·3`) is painted freeform in 16 colours +
transparent; a live preview renders each 2×3 cell through a faithful `encodeCell` port. Reuses the
resolution-lesson's rendering/coordinate approach.

**Tech Stack:** HTML5 Canvas, vanilla ES5-ish JS (no build step, no deps), CSS custom-property theming.

## Global Constraints

- **No external requests** — inline everything (Artifact/CSP-safe). No CDN fonts/scripts.
- **Coordinates are 1-based** (top-left = (1,1)) to match Lua / `subpixel.lua`; subpixel buffer value
  `-1` = transparent, `0..15` = palette index.
- **`encodeCell` must match `src/lib/subpixel.lua` exactly**: bg = most-frequent colour; fg = first
  colour ≠ bg (scan order 1..6 = topL,topR,midL,midR,botL,botR); a subpixel emits fg iff it equals fg,
  else bg; bottom-right (position 6) uses the invert trick (`char = 128 + (31-low5)`, swap F/B) when it
  equals fg, else `char = 128 + low5`. Transparent (`-1`) counts as its own "colour" for this purpose
  (a cell of art-over-nothing); the preview shows transparent as the checkerboard, not a palette hue.
- **Both colour themes** (prefers-color-scheme + `data-theme` override), visible focus states,
  `prefers-reduced-motion` respected.
- **No fabricated exactness** — block seams + any scale-derived hints labelled "approximate, verify in-world".
- File lives at `tools/monitor-mockup.html` (new `tools/` dir — dev tooling, outside `src/` deploy loop).

---

### Task 1: Skeleton, state model, palette defaults, and the `encodeCell` self-test

**Files:**
- Create: `tools/monitor-mockup.html`

**Interfaces:**
- Produces: `state = { cols, rows, subW, subH, buf, palette, textRegions, blocks, brushSize, curColor, tool }`
  where `buf` is a flat `Int8Array(subW*subH)` (row-major, 1-based logically), `-1` transparent.
- Produces: `encodeCell(c6) -> { char:int, F:int, B:int }` where `c6` is a length-6 array of palette
  indices (or `-1`), positions ordered topL,topR,midL,midR,botL,botR. `F`/`B` are palette indices.
- Produces: `CC` = 16-entry `[name, hex]` default palette; `BLIT="0123456789abcdef"`.

- [ ] **Step 1: Write the failing self-test** — an in-page `#selftest` panel that runs `encodeCell`
  on hand-verified cases and prints PASS/FAIL. Cases (derived by hand from `subpixel.lua`):

```js
// c6 order: topL,topR,midL,midR,botL,botR ; palette indices (0=white..15=black)
// A) all bg (all black=15): low5=0, br=bg -> char 128, F=first!=bg? none -> F=B=15
T([15,15,15,15,15,15], {char:128, F:15, B:15});
// B) top-left white(0), rest black(15): bg=15,fg=0,low5=bit1=1,br=15!=fg -> char 129, F=0,B=15
T([0,15,15,15,15,15], {char:129, F:0, B:15});
// C) bottom-right white, rest black: bg=15,fg=0(first!=bg is pos6? no—scan finds pos6),
//    fg=0, low5 over pos1..5 =0, br==fg -> char 128+(31-0)=159, F=bg=15,B=fg=0
T([15,15,15,15,15,0], {char:159, F:15, B:0});
// D) third colour falls to bg: tl=orange(1), tr=red(14), rest black(15):
//    counts black=4 -> bg=15; fg=first!=15 = orange(1); red(14)!=fg -> treated as bg.
//    low5: pos1==fg ->bit1=1; pos2(red)!=fg ->0. char=129, F=1,B=15
T([1,14,15,15,15,15], {char:129, F:1, B:15});
```

- [ ] **Step 2: Open the file in a browser; confirm the self-test panel shows all FAIL** (function not
  yet implemented / returns undefined).

- [ ] **Step 3: Implement `encodeCell` faithfully** (port of `subpixel.lua`):

```js
var BLIT = "0123456789abcdef";
function encodeCell(c){                 // c: length-6 palette indices (or -1)
  var counts={}, order=[];
  for (var i=0;i<6;i++){ var v=c[i]; if(counts[v]===undefined){counts[v]=0;order.push(v);} counts[v]++; }
  var bg=c[0], best=-1;
  order.forEach(function(v){ if(counts[v]>best){best=counts[v];bg=v;} });   // ties: first-appearance
  var fg=bg; for (var j=0;j<6;j++){ if(c[j]!==bg){ fg=c[j]; break; } }
  var bits=[1,2,4,8,16], low5=0;
  for (var k=0;k<5;k++){ if(c[k]===fg) low5+=bits[k]; }
  if (c[5]===fg) return { char:128+(31-low5), F:bg, B:fg };
  return { char:128+low5, F:fg, B:bg };
}
```

- [ ] **Step 4: Reload; confirm the self-test panel shows all PASS.**

- [ ] **Step 5: Add state init + palette defaults** (CC default 16 + `applyPreset(cols,rows)` setting
  `subW=cols*2, subH=rows*3` and allocating `buf` filled with `-1`). Default preset 15×21 (slot estimate).

- [ ] **Step 6: Commit** — `git add tools/monitor-mockup.html && git commit -m "feat(tool): mockup skeleton + encodeCell self-test"`

---

### Task 2: Rendering — paint view, live encoded preview, overlays

**Files:** Modify `tools/monitor-mockup.html`

**Interfaces:**
- Consumes: `state`, `encodeCell`, `CC`.
- Produces: `renderPaint(ctx, geom)`, `renderPreview(ctx, geom)`, `drawOverlays(ctx, geom, flags)`,
  `geomFor(canvas) -> { gx, gy, u }` (u = device px per subpixel), and `subAt(px,py,geom) -> {sx,sy}|null`.

- [ ] **Step 1: Behavioural check (manual, documented in a `#checks` comment block):** with a known
  buffer (paint one subpixel per corner via console), `renderPaint` shows 4 dots; `renderPreview`
  shows the same via `encodeCell` (identical for ≤2 colours/cell).
- [ ] **Step 2: Implement `geomFor` + `renderPaint`** — fill transparent as a checkerboard, palette
  indices as their hex; `image-rendering: pixelated`; hi-dpi via devicePixelRatio (reuse lesson's `fit`).
- [ ] **Step 3: Implement `renderPreview`** — for each cell (cx,cy) gather its 6 subpixels, run
  `encodeCell`, fill the 6 subpixel rects using `F`/`B` per the low5 bit pattern (so the preview is the
  literal 2-colour result, not an approximation). Transparent cells stay checkerboard.
- [ ] **Step 4: Implement `drawOverlays`** — independent toggles: cell grid (heavy), subpixel grid,
  real-px grid (only when `u >= threshold`), block-seam guides (even divisions from `blocksW/H`, dashed,
  amber, labelled approximate). Reuse the lesson's grid-drawing.
- [ ] **Step 5: Wire a redraw loop** (`repaint()` called on any state change; O(cells)/frame).
- [ ] **Step 6: Manually verify** paint vs preview differ only where a cell holds >2 colours (build a
  3-colour cell, confirm preview collapses to 2 with the third → bg). Confirm each overlay toggles alone.
- [ ] **Step 7: Commit** — `feat(tool): canvas paint view + encoded preview + overlays`

---

### Task 3: Tools — brush, eraser, bucket, eyedropper, rectangle, undo/redo, clear

**Files:** Modify `tools/monitor-mockup.html`

**Interfaces:**
- Consumes: `state`, `subAt`, `repaint`.
- Produces: `setTool(name)`, `paintAt(sx,sy)`, `bucketFill(sx,sy,target)`, `pushHistory()`,
  `undo()`, `redo()`, `clearCanvas()`.

- [ ] **Step 1: Implement pointer handling** — pointerdown/move/up → `subAt` → dispatch by `state.tool`.
  Brush/eraser paint a `brushSize×brushSize` square (clamped to canvas). Eraser writes `-1`.
- [ ] **Step 2: Implement `bucketFill`** — iterative flood fill (stack, 4-neighbour) over equal buffer
  values; guard against out-of-range and no-op (target===replacement).
- [ ] **Step 3: Implement eyedropper** — set `state.curColor` from buffer under cursor (ignore `-1`).
- [ ] **Step 4: Implement rectangle** — drag from anchor to current; filled or outline per a toggle;
  preview the rect during drag (draw to an overlay, commit on pointerup).
- [ ] **Step 5: Implement history** — `pushHistory()` snapshots `buf` (copy) before each mutating op;
  `undo`/`redo` swap; bound to 50 entries. Keyboard: Ctrl+Z / Ctrl+Shift+Z.
- [ ] **Step 6: Implement `clearCanvas`** (fill `-1`, pushHistory first).
- [ ] **Step 7: Manually verify** each tool mutates the buffer and preview updates; undo/redo restores
  exact state (paint → undo → buffer identical to before).
- [ ] **Step 8: Commit** — `feat(tool): brush/eraser/bucket/eyedropper/rect + undo/redo/clear`

---

### Task 4: Palette editing (RGB per slot, live recolour) + brush size + monitor config UI

**Files:** Modify `tools/monitor-mockup.html`

**Interfaces:**
- Consumes: `state.palette`, `repaint`, `applyPreset`.
- Produces: palette swatch strip + per-slot RGB editor; `brushSize` control; cols/rows/blocks inputs +
  preset buttons.

- [ ] **Step 1: Palette strip** — 16 swatches (current-colour selectable) + a transparent selector.
- [ ] **Step 2: Slot RGB editor** — clicking a swatch's "edit" opens an RGB picker (`<input type=color>`
  + hex field); editing mutates `state.palette[i]` and calls `repaint` (every subpixel using it recolours
  live — mirrors `setPaletteColour`). A "reset slot" restores the CC default.
- [ ] **Step 3: Brush-size control** — number/slider 1..N (subpixels); shows footprint.
- [ ] **Step 4: Monitor config** — cols/rows inputs (clamp 1..200) that reallocate `buf` (preserve
  overlap on resize), blocksW/H inputs (seam guide only), and preset buttons (e.g. "slot ≈15×21").
  Resizing warns before discarding out-of-range pixels.
- [ ] **Step 5: Manually verify** editing a slot recolours live; resizing preserves in-range art;
  transparent selector paints `-1`.
- [ ] **Step 6: Commit** — `feat(tool): editable palette + brush size + monitor config`

---

### Task 5: Text regions (tagged, cell-snapped)

**Files:** Modify `tools/monitor-mockup.html`

**Interfaces:**
- Consumes: `state.textRegions`, cell geometry, `repaint`.
- Produces: `addTextRegion()`, `editTextRegion(id)`, `removeTextRegion(id)`; region shape
  `{ id, cellX, cellY, cellW, cellH, text, fg, bg }` (cell coords, 1-based).

- [ ] **Step 1: Text tool mode** — drag on the canvas snaps the rectangle to the **cell** grid
  (round to cell boundaries); on release create a region and prompt for its string.
- [ ] **Step 2: Render regions** — draw a dashed teal box on the cell grid with the string in the
  browser font (stand-in, NOT CC glyphs), coloured by `fg`/`bg`; show a small handle to edit/delete.
- [ ] **Step 3: Edit/remove** — click a region to edit text + fg/bg or delete it.
- [ ] **Step 4: Manually verify** regions snap to whole cells; overlap art without corrupting the buffer
  (regions are a separate layer, not painted into `buf`).
- [ ] **Step 5: Commit** — `feat(tool): tagged cell-grid text regions`

---

### Task 6: Export JSON + PNG, import JSON (round-trip)

**Files:** Modify `tools/monitor-mockup.html`

**Interfaces:**
- Consumes: entire `state`.
- Produces: `exportJSON() -> string`, `exportPNG()` (download), `importJSON(str)` (validate + load).
- JSON schema exactly as in the spec (`tool`, `version`, `monitor`, `canvas`, `palette`, `pixels`
  flat row-major array, `textRegions`).

- [ ] **Step 1: Round-trip self-test** — add to `#selftest`: build a small state, `importJSON(exportJSON())`,
  assert `buf` and `textRegions` are identical. Confirm FAIL before implementing.
- [ ] **Step 2: Implement `exportJSON`** — serialise per schema; `pixels` = `Array.from(buf)`; palette
  as `{i,name,hex}`; monitor + canvas dims; textRegions verbatim.
- [ ] **Step 3: Implement `importJSON`** — validate `tool==="cc-monitor-mockup"` and `version`; on bad
  input show an inline error and DO NOT wipe current work; on good input rebuild state + `repaint`.
- [ ] **Step 4: Implement `exportPNG`** — render the **encoded preview** (the truth) to an offscreen
  canvas at an integer scale and trigger a download.
- [ ] **Step 5: Confirm the round-trip self-test PASSES; manually export PNG and eyeball it.**
- [ ] **Step 6: Commit** — `feat(tool): JSON+PNG export, JSON import round-trip`

---

### Task 7: Theming, layout polish, help text, whole-file review

**Files:** Modify `tools/monitor-mockup.html`

- [ ] **Step 1: Both themes** via CSS custom properties (reuse the lesson's token system + toggle).
- [ ] **Step 2: Layout** — toolbar (tools + brush size), palette strip, canvas area (paint | preview),
  right panel (monitor config, overlays, text regions, export/import), `#selftest` collapsible.
- [ ] **Step 3: Help/legend** — a short "how Claude reads this" note + the coordinate conventions.
- [ ] **Step 4: A11y** — keyboard-operable buttons, visible focus, `prefers-reduced-motion`,
  `overflow-x:auto` on the canvas holder.
- [ ] **Step 5: Whole-file code review** (superpowers:requesting-code-review or /code-review); fix
  Critical/Important findings.
- [ ] **Step 6: Publish as an Artifact + copy to `tools/` + commit.**

---

## Self-Review

**Spec coverage:** monitor config (T4), painting/buffer (T1–T3), live encoded preview (T2), palette
edit (T4), tools incl. sizable brush (T3), overlays incl. approximate seams (T2), tagged text regions
(T5), JSON+PNG export + JSON import (T6), theming/a11y/testing (T1 self-test, T6 round-trip, T7 review).
Non-goals (font render, layers, animation, exact seam math, in-game deploy, sprite crop) — excluded. ✓

**Placeholder scan:** `encodeCell` given in full with 4 worked cases; flood-fill, history, export/import
described with concrete behaviour. No "add error handling" hand-waves — import validation + resize
warning are specified as steps. ✓

**Type consistency:** `buf` is `Int8Array`, `-1` transparent, `0..15` index, throughout. `encodeCell`
returns `{char,F,B}` (used by T2). `textRegions` shape fixed in T5 and serialised verbatim in T6.
Coordinates 1-based everywhere. ✓
