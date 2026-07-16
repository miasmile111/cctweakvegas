---
title: Monitor UI gotchas — CC:Tweaked graphics
area: monitor-ui
verified: in-game 2026-07-16 (building src/slot.lua)
tags: [monitor, subpixel, palette, window, clipping, watchdog, redstone, deploy]
---

# Monitor UI gotchas — CC:Tweaked graphics (hard-won)

Real bugs hit while building `src/slot.lua` (subpixel graphics on a 1×2 advanced monitor).
Each entry: the symptom, the cause, the fix. Keywords for search included on purpose.
This page bundles several findings; split any one out into its own `kb/` entry if it grows.

## "Too long without yielding" crash from a hot per-cell loop

- **Symptom:** `subpixel.lua:NN: Too long without yielding`, often while idle, traceback landing
  on a tiny `while` loop.
- **Cause:** a per-cell loop called hundreds of times per frame (e.g. computing `log2(colour)`
  for `term.blit` with `while color > 1 do color = color/2 ... end`). On a slow/multiplayer
  server the accumulated work trips CC's watchdog.
- **Fix:** precompute a lookup table once; make hot paths **O(1)**, no loop.
  ```lua
  local COLOR_HEX = {}          -- colour number (2^i) -> blit hex digit
  do local p=1 for i=0,15 do COLOR_HEX[p]="0123456789abcdef":sub(i+1,i+1); p=p*2 end end
  local function toBlit(c) return COLOR_HEX[c] or "0" end
  ```
- Render paths run every frame — never put an unbounded loop or heavy allocation per pixel/cell.
  Reuse buffers instead of reallocating them each `clear()`.

## Fractional coordinates crash setPixel (`attempt to index field '?' (a nil value)`)

- **Symptom:** `attempt to index field '?' (a nil value)` at `self.buf[y][x] = color`.
- **Cause:** a **float** coordinate (e.g. `buf[14.7]`) — the buffer only has integer keys, so
  `buf[14.7]` is nil. Eased/decelerating animations produce fractional positions (`pos *= 0.75`).
- **Fix:** floor at the single choke point so any caller is safe:
  ```lua
  function Canvas:setPixel(x, y, color)
    x, y = math.floor(x), math.floor(y)
    if x < 1 or y < 1 or x > self.w or y > self.h then return end
    self.buf[y][x] = color
  end
  ```

## Gradients & custom colours: redefine the palette, animate the palette

- Advanced monitors have **16 colour slots**, but each is **redefinable** to any RGB:
  `monitor.setPaletteColour(colourNumber, r, g, b)` (r,g,b 0..1) or `(colourNumber, 0xRRGGBB)`.
  So "16 colours" means *16 you choose*, not 16 fixed.
- **Cheap animated gradient:** paint background bands using a few unused colour slots, then each
  tick nudge those slots' RGB with `setPaletteColour`. Changing a slot **recolours every pixel
  using it with no redraw** — ~5 calls/tick, essentially free. Animate the *palette*, not pixels.
- **Dark colours read as black on a monitor.** `{0.04,0.06,0.34}` (deep navy) looked identical
  to the black background in-world. If a custom colour "doesn't render," suspect it's just too
  dark before suspecting the palette plumbing. Diagnostic: if a redefined slot shows *black*
  (not its bright default), the palette IS applying — the colour is too dark.
- Set the palette on the **monitor**; if drawing through a `window`, set it on the window too
  (cheap insurance against window-vs-parent palette differences).
- **Restore** slots on exit: capture `{monitor.getPaletteColour(slot)}` at start, restore at cleanup.

## The subpixel canvas has NO native clipping

- To make reel symbols roll in/out **behind** frame bars, clip manually — draw only the sprite
  rows inside `[yMin, yMax]`:
  ```lua
  local function drawSpriteClipped(cv, x, y, sprite, yMin, yMax)
    y = math.floor(y)
    for dy = 0, sprite.h-1 do local py = y+dy
      if py>=yMin and py<=yMax then
        for dx = 0, sprite.w-1 do local c = sprite.px[dy*sprite.w+dx+1]
          if c and c~=0 then cv:setPixel(x+dx, py, c) end end end end
  end
  ```
- Draw order = layering: background → highlights → clipped sprites → frame bars → bulbs → banner.

## Flicker-free = window + setVisible bracket

- Wrap the monitor in `window.create(mon,1,1,W,H,true)`, draw the whole frame with the window
  **invisible**, then flush: `win.setVisible(false) … draw … win.setVisible(true)`. Bind the
  subpixel canvas to the *window*, and write any text overlays (labels, banners) to the window
  too so they flush together.

## Deploy: re-import ALL files, and filenames must match `require`

- A multi-file program is a **matched set**. Re-import **every** changed file, not just the one
  you edited. A stale dependency causes confusing crashes far from the edit — e.g. an old
  `slot_logic` with no `pos` field → `attempt to perform arithmetic on field 'pos' (a nil value)`
  in the renderer.
- `require("slot_symbols")` needs the in-game file named **exactly** `slot_symbols` — a typo like
  `slots_symbols` fails to load. Rename in-game (`mv`) or re-`wget` with the right name.
- When in doubt, re-`wget` the whole set. See [[project-goal]] / the deploy loop in SKILL.md.

## Diegetic input nuance & redstone levers

- A **touch on an in-world monitor is diegetic** (physical-world interaction, no terminal GUI) —
  the ban is on keyboard/terminal-UI gameplay, not on `monitor_touch`. See [[diegetic-input-preference]].
- **Analog lever that ramps 0→15:** poll `redstone.getAnalogInput(side)` each tick and fire on a
  threshold with a rising-edge guard so one pull = one action:
  ```lua
  local lvl = redstone.getAnalogInput(SPIN_SIDE)
  if state=="idle" and armed and lvl >= SPIN_LEVEL then start(); armed=false end
  if lvl < SPIN_LEVEL then armed = true end   -- re-arm when it drops
  ```
- Add a `test` submode that prints live per-side analog levels so the user finds the right side.

## A small sprite that straddles cell boundaries gets splintered by `encodeCell`

- **Symptom:** a 2×2-subpixel dot (e.g. a bulb) renders as a **squashed 1-px sliver** instead of a
  square — worst at the **canvas edge**. It looks "half there" / mis-shaped, and it moved when we
  nudged it, but never looked right.
- **Cause:** a cell is **2×3 subpixels and only 2 colours** (`encodeCell`). A 2×2 dot placed at an
  **even x** (e.g. `x=2` → subx 2–3) straddles **two cell columns**, and if its y also crosses a cell
  row it lands in **four cells**, one quarter each. Each cell keeps at most 2 colours, so quarters get
  dropped/merged and the dot disintegrates. At the far-left/right column the surviving quarter reads as
  a lone edge sliver. (This is the real cause of the slot's phantom "top-left corner bulb" — it was the
  **red bar's leftmost bulb**, not the side-column lane.)
- **Fixes:** (a) **don't place small sprites at the extreme edge columns** — start the row a cell or two
  in (the slot's bar-bulb row now starts at `x=6`, not `x=2`); (b) if you need edge dots, **cell-align**
  them — put a 2×2 at an **odd x** (subx `1–2`, `3–4`… = one cell column) and a **cell-row-aligned y**
  (subpx `1–2` of a 3-row cell) so the dot lives inside a single cell and survives `encodeCell` whole.
- **Catch it offline:** render the `encodeCell` (monitor-truth) layer to PNG, not just the raw buffer —
  the raw buffer hides this because it isn't collapsed to 2 colours/cell. See [[monitor-ui-workflow]].

## Related

- [[subpixel-drawing]] — the 2×3 teletext encoding this canvas is built on.
