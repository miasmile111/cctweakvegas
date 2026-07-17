# Pixelfont Alphabet Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give `src/lib/pixelfont.lua` an alphabet (A–Z + punctuation + space), then rebuild the slot's and the cage's idle advert screens on top of it so they read as designed signage from across the floor instead of native default-palette text.

**Architecture:** The alphabet is added **into the existing `M.BIG` table** (not a new table) so one `drawText` call renders a mixed string and every existing call site is untouched. `pixelfont` is already variable-width and already scale-aware, so this is data, not code. The slot's shared look (gradient palette, bulb, colours) is extracted from `slot.lua` into a new `slot_style.lua` that both the play screen and the advert require. Both adverts are single static frames — `idle_runner` draws them once and blocks.

**Tech Stack:** Lua 5.1 / LuaJIT (unit tests run under `luajit`, offline, no game). CC:Tweaked CraftOS at runtime. `test/runner.lua` is a minimal assert harness. HTML/JS (self-contained, no CDN) for the preview tool. Python + PIL for the offline PNG render.

**Spec:** `docs/superpowers/specs/2026-07-17-pixelfont-alphabet-design.md` — read it first.

> **Post-build correction (2026-07-17):** where this plan (Task 4) says the cage rate-table ceiling
> is **4** denominations because "a 5th lands on the bar", that arithmetic was wrong and was fixed
> during Task 4's review. The true geometry: a **5th fits** (row 22, subpixels 64-66) but sits
> against the bar with no breathing room; a **6th collides** (row 23 = the bar). **Four ships** with a
> blank row above the bar. The shipped `cage_advert.lua`/`cage_rates.lua` comments are correct; only
> this plan's original number is stale.

## Global Constraints

- **Branch is `feat/pixelfont-alphabet`. Nothing goes to `main` until the final merge.** A second session is building multiplayer on this repo concurrently.
- **SDD ledger is `.superpowers/sdd/progress-alphabet.md`** — NOT `progress.md`, which the other session is using.
- **Shared files — `src/packages.lua`, `todo.md`, `README.md` — are touched LAST, in one small commit (Task 7), and the branch is rebased before merging.** No other task may edit them.
- **Do not redraw `M.BIG`'s digits `0`-`9`, and do not touch `M.WIN`.** Both are the owner's drawings, shipped and in-world verified. `slot.lua:138-139` depends on them.
- **Do not delete `M.SIGN_SM`** (zero call sites, unverified comment). File it in Task 7; leave the glyph alone.
- **Do not touch `slot.lua`'s play loop, `topLayout`, `drawReel`, or `drawTopFrame`; do not touch `cage.lua` at all.** Task 2 changes `slot.lua` by deletion + require only.
- **`pixelfont.lua` and `slot_style.lua` must stay pure** — no CC globals (`colors`, `peripheral`, `redstone`, `term`) at module scope or inside any function that tests call. They must load under plain `luajit`.
- **Glyph geometry: every glyph in `M.BIG` is exactly 6 rows tall.** Base width 4; `M` and `W` are 5; punctuation varies; **space is 3**.
- **The gap between glyphs is 1 subpixel and is NOT scaled** (`textWidth` does `w + glyphW*scale + gap`). All width arithmetic in this plan assumes `gap = 1`.
- **Canvas sizes are fixed and exact:** slot = **30 × 72** subpixels (15×24 cells @ scale 0.5). Cage = **72 × 72** subpixels (36×24 cells @ scale 0.5).
- **Adverts are STATIC.** `idle_runner.lua:125` calls `advert.draw(mon)` once and then blocks on `os.pullEvent`. No animation, no timer, no palette drift, no loop. Idle must cost nothing.
- Run all tests with `luajit test/test_<name>.lua` from the repo root. Baseline today: `test_pixelfont.lua` prints `27 passed, 0 failed`.

---

## File Structure

| File | Status | Responsibility |
| --- | --- | --- |
| `src/lib/pixelfont.lua` | Modify | Add A–Z + `! : - . ,` + space to `M.BIG`. Data only; no API change. |
| `test/test_pixelfont.lua` | Modify | Extend. The 27 existing assertions stay green, untouched. |
| `src/slot/slot_style.lua` | **Create** | The slot station's shared look: gradient slots + `gradientRGB` + `bandFill` + `bulb` + colour constants. Pure. |
| `test/test_slot_style.lua` | **Create** | Unit tests for `gradientRGB` / `bandFill` / `bulb`. |
| `src/slot/slot.lua` | Modify | Deletion + require only. Constants and `bulb` move out. |
| `src/slot/slot_advert.lua` | Rewrite | The slot's static idle face: `GET`@2x / `MONEY`@1x / big `$`. |
| `src/cage/cage_advert.lua` | Rewrite | The cage's static idle face: three 2x signage lines + a native rate table. |
| `src/cage/cage_rates.lua` | Modify | **Comment only** — the CEILING note moves from ≤6 to ≤4 denominations. |
| `test/stub_target.lua` | Modify | Additive: add `write`, `setPaletteColour`, and call capture. |
| `test/render_adverts.lua` | **Create** | Offline harness: draws the real adverts to a stub, dumps `cv.buf` through `encodeCell`. |
| `tools/render_adverts.py` | **Create** | Turns the dump into PNGs. |
| `tools/font-preview.html` | **Create** | The owner's review surface: glyph specimen + both screens at `encodeCell` truth. |
| `src/packages.lua` | Modify (**Task 7 only**) | One line: `slot_style` in the `slot` package. |
| `todo.md`, `README.md` | Modify (**Task 7 only**) | Status + the two filed follow-ups. |

---

### Task 1: The alphabet in `pixelfont`

**Files:**
- Modify: `src/lib/pixelfont.lua:17-28` (the `M.BIG` table)
- Test: `test/test_pixelfont.lua` (append only — do not edit lines 1-82)

**Interfaces:**
- Consumes: nothing.
- Produces: `M.BIG` gains keys `"A".."Z"`, `"!"`, `":"`, `"-"`, `"."`, `","`, `" "`. Every value is a list of **6** strings. Widths: base 4; `"M"` and `"W"` are 5; `"!"`/`":"`/`"."` are 1; `","` is 2; `" "` is 3; `"-"` is 4. No function signatures change. Tasks 3, 4, 5, 6 all read `M.BIG`.

- [ ] **Step 1: Confirm the baseline is green before touching anything**

Run: `luajit test/test_pixelfont.lua`
Expected: `27 passed, 0 failed`

- [ ] **Step 2: Write the failing tests**

Append to `test/test_pixelfont.lua`, immediately **before** the final `t.done()` line (line 82). Do not modify anything above it.

```lua
-- ---- the alphabet ---------------------------------------------------------
-- Structural invariants. A glyph with the wrong row count or a ragged row
-- mis-measures forever and the failure shows up as a layout bug three files away,
-- so assert the shape of every glyph rather than spot-checking a few.
do
  local LETTERS = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
  for i = 1, #LETTERS do
    local ch = LETTERS:sub(i, i)
    local g = F.BIG[ch]
    t.ok(g ~= nil, "BIG has letter " .. ch)
    if g then
      t.eq(#g, 6, ch .. " is 6 rows tall")
      local w = #g[1]
      local ragged = false
      for r = 2, #g do if #g[r] ~= w then ragged = true end end
      t.ok(not ragged, ch .. " has rows of equal width")
    end
  end
end

-- Widths: base 4, M and W are 5. This is the whole layout budget's foundation.
t.eq(F.textWidth(F.BIG, "M", 1), 5, "M is 5 wide")
t.eq(F.textWidth(F.BIG, "W", 1), 5, "W is 5 wide")
t.eq(F.textWidth(F.BIG, "A", 1), 4, "A is 4 wide")
t.eq(F.textWidth(F.BIG, "E", 1), 4, "E is 4 wide")
t.eq(F.textWidth(F.BIG, "Q", 1), 4, "Q is 4 wide (tail pokes out the bottom-right)")

-- Punctuation + the space glyph.
t.ok(F.BIG["!"] ~= nil, "BIG has !")
t.ok(F.BIG[":"] ~= nil, "BIG has :")
t.ok(F.BIG["-"] ~= nil, "BIG has -")
t.ok(F.BIG["."] ~= nil, "BIG has .")
t.ok(F.BIG[","] ~= nil, "BIG has ,")

-- THE SPACE IS 3 WIDE, NOT 4, AND THAT IS LOAD-BEARING: at 4, "METAL IN" @2x is
-- 73 of the cage's 72 subpixels. See the spec's width budget.
t.ok(F.BIG[" "] ~= nil, "BIG has a space glyph")
t.eq(F.textWidth(F.BIG, " ", 1), 3, "space is 3 wide")
-- Before this glyph existed, glyphW returned 0 for " " and drawText advanced ONE
-- subpixel for a space -- words collided. This is the regression lock for that.
t.eq(F.textWidth(F.BIG, "A B", 1), 4 + 1 + 3 + 1 + 4, "'A B' = 13; the space actually advances")

-- S must not be the same bitmap as 5. A naive square S is identical to BIG's "5";
-- S is chamfered at top-left and bottom-right so they differ at four corners. Same
-- problem the owner's slashed "0" already solves for 0-vs-O.
do
  local same = true
  for r = 1, 6 do if F.BIG["S"][r] ~= F.BIG["5"][r] then same = false end end
  t.ok(not same, "S is not the same bitmap as 5")
end

-- ---- the layout budget: these six numbers ARE the design -------------------
-- Slot canvas is 30 subpixels wide, cage is 72. Every one of these is a regression
-- lock: if a glyph width changes, the advert copy silently stops fitting.
t.eq(F.textWidth(F.BIG, "GET", 1, 2), 26, "GET @2x = 26, fits the slot's 30")
t.eq(F.textWidth(F.BIG, "MONEY", 1, 2), 46, "MONEY @2x = 46, does NOT fit 30 -- why MONEY is 1x")
t.eq(F.textWidth(F.BIG, "MONEY", 1), 25, "MONEY @1x = 25, fits the slot's 30")
t.eq(F.textWidth(F.BIG, "THE CAGE", 1, 2), 69, "THE CAGE @2x = 69, fits the cage's 72")
t.eq(F.textWidth(F.BIG, "METAL IN", 1, 2), 71, "METAL IN @2x = 71 of 72 -- the tightest line on the floor")
t.eq(F.textWidth(F.BIG, "CASH OUT", 1, 2), 69, "CASH OUT @2x = 69, fits the cage's 72")
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `luajit test/test_pixelfont.lua`
Expected: FAIL. Many lines of `FAIL: BIG has letter A`, `FAIL: M is 5 wide` (expected 5, actual 0 — `glyphW` returns 0 for a missing glyph), etc. The run exits non-zero.

- [ ] **Step 4: Add the glyphs**

In `src/lib/pixelfont.lua`, replace the `M.BIG` table (lines 16-28) with the block below. **The digits are byte-for-byte the ones already there — do not alter them.**

```lua
-- The big square font: 6 rows tall, base 4 wide (M/W are 5), full-width top/bottom
-- bars, 1px stems, square corners. The owner drew the "0" (slashed, so 0 ~= O); 1-9
-- were extrapolated from it and are in-world verified -- DO NOT REDRAW THEM.
-- A-Z + punctuation extrapolated from the same style, 2026-07-17.
--
-- Letters and digits share ONE table on purpose: drawText takes a single `font`, so a
-- mixed string ("COPPER $25", "WIN 100") is only possible if they live together. It
-- also means slot.lua's and cage.lua's existing BIG call sites need no change.
M.BIG = {
  -- digits (owner-drawn "0"; 1-9 match it). Shipped + verified -- do not touch.
  ["0"] = { "####", "#..#", "#.##", "##.#", "#..#", "####" },
  ["1"] = { ".##.", "..#.", "..#.", "..#.", "..#.", "..#." },
  ["2"] = { "####", "...#", "####", "#...", "#...", "####" },
  ["3"] = { "####", "...#", ".###", "...#", "...#", "####" },
  ["4"] = { "#..#", "#..#", "####", "...#", "...#", "...#" },
  ["5"] = { "####", "#...", "####", "...#", "...#", "####" },
  ["6"] = { "####", "#...", "####", "#..#", "#..#", "####" },
  ["7"] = { "####", "...#", "..#.", ".#..", ".#..", ".#.." },
  ["8"] = { "####", "#..#", "####", "#..#", "#..#", "####" },
  ["9"] = { "####", "#..#", "####", "...#", "...#", "####" },

  -- letters
  ["A"] = { "####", "#..#", "####", "#..#", "#..#", "#..#" },
  ["B"] = { "###.", "#..#", "###.", "#..#", "#..#", "###." },
  ["C"] = { "####", "#...", "#...", "#...", "#...", "####" },
  ["D"] = { "###.", "#..#", "#..#", "#..#", "#..#", "###." },
  ["E"] = { "####", "#...", "####", "#...", "#...", "####" },
  ["F"] = { "####", "#...", "####", "#...", "#...", "#..." },
  ["G"] = { "####", "#...", "#.##", "#..#", "#..#", "####" },
  ["H"] = { "#..#", "#..#", "####", "#..#", "#..#", "#..#" },
  ["I"] = { "####", ".##.", ".##.", ".##.", ".##.", "####" },
  ["J"] = { "####", "..#.", "..#.", "..#.", "#.#.", ".##." },
  ["K"] = { "#..#", "#.#.", "##..", "##..", "#.#.", "#..#" },
  ["L"] = { "#...", "#...", "#...", "#...", "#...", "####" },
  -- M and W are the only 5-wide letters: at 4 they have no interior column and read
  -- as blobs against N. pixelfont is variable-width already, so this costs nothing.
  ["M"] = { "#...#", "##.##", "#.#.#", "#...#", "#...#", "#...#" },
  ["N"] = { "#..#", "##.#", "##.#", "#.##", "#.##", "#..#" },
  ["O"] = { "####", "#..#", "#..#", "#..#", "#..#", "####" },
  ["P"] = { "####", "#..#", "####", "#...", "#...", "#..." },
  -- Q's tail pokes out of the bottom-right instead of costing a 5th column. The cost
  -- is a 5-row bowl where every other letter's body is 6, so Q reads slightly short.
  -- Accepted (no advert copy has a Q); first glyph to redraw if the owner dislikes it.
  ["Q"] = { "####", "#..#", "#..#", "#.##", "####", "...#" },
  ["R"] = { "####", "#..#", "####", "##..", "#.#.", "#..#" },
  -- S is CHAMFERED top-left and bottom-right. A naive square S is byte-identical to
  -- the "5" above; this is the same disambiguation the slashed "0" does for 0-vs-O.
  ["S"] = { ".###", "#...", "####", "...#", "...#", "###." },
  ["T"] = { "####", ".##.", ".##.", ".##.", ".##.", ".##." },
  ["U"] = { "#..#", "#..#", "#..#", "#..#", "#..#", "####" },
  ["V"] = { "#..#", "#..#", "#..#", "#..#", ".##.", ".##." },
  ["W"] = { "#...#", "#...#", "#...#", "#.#.#", "##.##", "#...#" },
  ["X"] = { "#..#", "#..#", ".##.", ".##.", "#..#", "#..#" },
  -- Y's stem is 2 wide: a 1-wide stem under a 4-wide top is off-centre in an even box.
  ["Y"] = { "#..#", "#..#", ".##.", ".##.", ".##.", ".##." },
  ["Z"] = { "####", "...#", "..#.", ".#..", "#...", "####" },

  -- punctuation
  ["!"] = { "#", "#", "#", "#", ".", "#" },
  [":"] = { ".", "#", ".", ".", "#", "." },
  ["-"] = { "....", "....", "####", "....", "....", "...." },
  ["."] = { ".", ".", ".", ".", ".", "#" },
  [","] = { "..", "..", "..", "..", ".#", "#." },

  -- THE SPACE IS 3 WIDE, NOT 4, AND IT IS LOAD-BEARING. At 4, "METAL IN" @2x measures
  -- 73 against the cage's 72-subpixel canvas and the copy would have to change; at 3 it
  -- is 71. (A space narrower than a letter is ordinary typography anyway.) It must also
  -- EXIST: glyphW returns 0 for a missing glyph, so before this, drawText advanced a
  -- single subpixel for a space and words ran together.
  [" "] = { "...", "...", "...", "...", "...", "..." },
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `luajit test/test_pixelfont.lua`
Expected: PASS, `0 failed`, and the pass count is **higher than 27** (the original 27 plus the new ones).

- [ ] **Step 6: Syntax-check**

Run: `luajit -bl src/lib/pixelfont.lua /dev/null`
Expected: no output, exit 0.

- [ ] **Step 7: Commit**

```bash
git add src/lib/pixelfont.lua test/test_pixelfont.lua
git commit -m "feat(pixelfont): an alphabet -- A-Z, punctuation, and a space that is 3 wide"
```

---

### Task 2: Extract `slot_style.lua`

**Files:**
- Create: `src/slot/slot_style.lua`
- Create: `test/test_slot_style.lua`
- Modify: `src/slot/slot.lua` lines 34-43 (constants), 103-105 (`bulb`), 111-112 (band fill), 190-199 (`updateGradient`)

**Interfaces:**
- Consumes: nothing.
- Produces, all on the module table returned by `require("slot_style")`:
  - `M.GRAD` — `{ 2048, 512, 8, 1024, 64 }`, the 5 palette slots the gradient owns.
  - `M.GRAD_DEEP` = `{ 0.00, 0.10, 0.65 }`, `M.GRAD_TEAL` = `{ 0.00, 0.75, 0.65 }`.
  - `M.RED, M.YELLOW, M.GREEN, M.WHITE, M.BLACK, M.GREY, M.GRAY` — colour numbers.
  - `M.gradientRGB(i, phase) -> r, g, b` — **pure.** The deep↔teal ramp for band `i` at `phase`.
  - `M.bandFill(cv)` — paints the 5 gradient bands across the whole canvas.
  - `M.bulb(cv, x, y, seed, bulbTick)` — a 2×2 dot; on = `YELLOW`, off = `GREY`.
- Task 3 (`slot_advert`) consumes all of these.

> **Why `gradientRGB(i, phase)` returns numbers instead of an `applyGradient(mon)` doing the work:**
> `slot.lua` sets the palette on **two** targets (`topMon` *and* `topWin`, lines 196-197) — passing a
> monitor in would force the module to know about that. Returning `r, g, b` keeps the module pure (so
> it unit-tests under luajit with no CC globals) and leaves `slot.lua`'s dual-target loop untouched.

> **Why `bulb` keeps the 5-argument `(cv, x, y, seed, bulbTick)` signature** even though the advert
> only ever wants a static dot: changing it would edit `slot.lua`'s play loop, which this branch must
> not touch. The advert passes `bulbTick = 0`.

- [ ] **Step 1: Write the failing test**

Create `test/test_slot_style.lua`:

```lua
package.path = "src/lib/?.lua;src/slot/?.lua;test/?.lua;" .. package.path
local t = require("runner")
local S = require("slot_style")

-- a tiny recording canvas (mirrors the subpixel canvas contract)
local function mockCanvas(w, h)
  local cv = { w = w, h = h, px = {} }
  function cv:setPixel(x, y, color)
    if x < 1 or y < 1 or x > self.w or y > self.h then return end
    self.px[y * 1000 + x] = color
  end
  function cv:fillRect(x, y, w, h, color)
    for dy = 0, h - 1 do for dx = 0, w - 1 do self:setPixel(x + dx, y + dy, color) end end
  end
  return cv
end

-- the constants slot.lua and slot_advert.lua must agree on
t.eq(#S.GRAD, 5, "5 gradient palette slots")
t.eq(S.GRAD[1], 2048, "first gradient slot is 2048")
t.eq(S.RED, 16384, "RED")
t.eq(S.YELLOW, 16, "YELLOW")
t.eq(S.WHITE, 1, "WHITE")
t.eq(S.BLACK, 32768, "BLACK")
t.eq(S.GREY, 128, "GREY")

-- gradientRGB is PURE: same input, same output, no CC globals needed
do
  local r1, g1, b1 = S.gradientRGB(1, 0)
  local r2, g2, b2 = S.gradientRGB(1, 0)
  t.eq(r1, r2, "gradientRGB is deterministic (r)")
  t.eq(g1, g2, "gradientRGB is deterministic (g)")
  t.eq(b1, b2, "gradientRGB is deterministic (b)")
  -- every channel stays inside the deep..teal envelope, so a band can never be
  -- brighter than teal or darker than deep no matter the phase
  for _, phase in ipairs({ 0, 1, 2, 3, 4, 5, 6 }) do
    for i = 1, #S.GRAD do
      local r, g, b = S.gradientRGB(i, phase)
      t.ok(g >= S.GRAD_DEEP[2] - 1e-9 and g <= S.GRAD_TEAL[2] + 1e-9,
           ("band %d phase %d: green inside deep..teal"):format(i, phase))
      t.ok(r >= 0 and r <= 1 and b >= 0 and b <= 1,
           ("band %d phase %d: r,b are valid 0..1"):format(i, phase))
    end
  end
end

-- bandFill covers EVERY pixel of the canvas -- a gap would show as a black stripe
do
  local cv = mockCanvas(30, 72)
  S.bandFill(cv)
  local missing = 0
  for y = 1, 72 do for x = 1, 30 do if cv.px[y * 1000 + x] == nil then missing = missing + 1 end end end
  t.eq(missing, 0, "bandFill leaves no unpainted pixel")
end

-- bulb: 2x2, on = YELLOW, off = GREY, parity from seed + bulbTick
do
  local cv = mockCanvas(30, 72)
  S.bulb(cv, 5, 5, 0, 0)                     -- (0 + 0) % 2 == 0 -> on
  t.eq(cv.px[5 * 1000 + 5], S.YELLOW, "bulb on: top-left is YELLOW")
  t.eq(cv.px[6 * 1000 + 6], S.YELLOW, "bulb on: it is 2x2")
  t.eq(cv.px[5 * 1000 + 7], nil, "bulb on: it is only 2 wide")
  S.bulb(cv, 9, 9, 1, 0)                     -- (1 + 0) % 2 == 1 -> off
  t.eq(cv.px[9 * 1000 + 9], S.GREY, "bulb off: GREY")
end

t.done()
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `luajit test/test_slot_style.lua`
Expected: FAIL — `module 'slot_style' not found`.

- [ ] **Step 3: Create `src/slot/slot_style.lua`**

```lua
-- slot_style.lua — the slot station's shared visual kit: the animated gradient's palette slots and
-- ramp, the bulb, and the colour numbers. Required by BOTH slot.lua (the play screen) and
-- slot_advert.lua (the idle screen) so the idle face and the play face cannot drift apart — before
-- this, these constants lived only in slot.lua and the advert had no way to look like the machine.
--
-- Pure (no CC globals): gradientRGB returns numbers rather than calling setPaletteColour, because
-- slot.lua sets the palette on TWO targets (the monitor and its window) and this module has no
-- business knowing that. Keeps it unit-testable under luajit.
local M = {}

M.RED, M.YELLOW, M.GREEN, M.WHITE, M.BLACK, M.GREY = 16384, 16, 8192, 1, 32768, 128
M.GRAY = 128   -- alias: slot.lua's stake buttons spell it this way

-- Unused colour slots, redefined at runtime to a drifting deep-blue <-> teal gradient.
-- None collide with the symbol/UI colours above.
M.GRAD = { 2048, 512, 8, 1024, 64 }
M.GRAD_DEEP = { 0.00, 0.10, 0.65 }
M.GRAD_TEAL = { 0.00, 0.75, 0.65 }

-- The ramp for band `i` at `phase`, as r, g, b in 0..1. Each band is offset a little around the
-- sine so the five slots read as a moving gradient rather than five blocks pulsing in lockstep.
-- Callers do their own setPaletteColour (see the header).
function M.gradientRGB(i, phase)
  local a = 0.5 + 0.5 * math.sin(phase + i * 0.9)
  return M.GRAD_DEEP[1] + (M.GRAD_TEAL[1] - M.GRAD_DEEP[1]) * a,
         M.GRAD_DEEP[2] + (M.GRAD_TEAL[2] - M.GRAD_DEEP[2]) * a,
         M.GRAD_DEEP[3] + (M.GRAD_TEAL[3] - M.GRAD_DEEP[3]) * a
end

-- Paint the 5 gradient bands across the whole canvas. math.ceil so the last band overshoots rather
-- than leaving an unpainted stripe at the bottom (setPixel bounds-checks, so overshoot is free).
function M.bandFill(cv)
  local bandH = math.ceil(cv.h / #M.GRAD)
  for b = 1, #M.GRAD do cv:fillRect(1, 1 + (b - 1) * bandH, cv.w, bandH, M.GRAD[b]) end
end

-- A bulb: on = bright yellow, off = dim grey (blinks by seed+tick parity). A static screen passes
-- bulbTick = 0 and gets a fixed on/off pattern from the seed alone.
function M.bulb(cv, x, y, seed, bulbTick)
  cv:fillRect(x, y, 2, 2, ((seed + bulbTick) % 2 == 0) and M.YELLOW or M.GREY)
end

return M
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `luajit test/test_slot_style.lua`
Expected: PASS, `0 failed`.

- [ ] **Step 5: Point `slot.lua` at it — deletion + require only**

Four edits to `src/slot/slot.lua`. **Change nothing else in the file.**

(a) Replace lines 34-43 (the constants block) with:

```lua
local style = require("slot_style")
-- The slot's look now lives in slot_style so the idle advert can share it. These locals are kept
-- so the rest of this file (and its layout math) is untouched.
local RED, YELLOW, GREEN, WHITE, BLACK, GREY =
  style.RED, style.YELLOW, style.GREEN, style.WHITE, style.BLACK, style.GREY
local GRAY = style.GRAY                          -- stake buttons: selected YELLOW, others gray
local SYM_W, SYM_H = 8, 9
local SYMBOL_PX = SYM_H                          -- snug: each symbol fills exactly 3 cells (no gap)
local GRAD = style.GRAD
```

> `GRAD_DEEP` / `GRAD_TEAL` are **not** re-aliased — after edit (d) below, `updateGradient` is the
> only thing that used them and it now asks `slot_style` for the ramp instead.

(b) Replace the `bulb` function (lines 103-105) with:

```lua
-- a bulb: on = bright yellow, off = dim grey (blinks by seed+tick parity) — see slot_style
local bulb = style.bulb
```

(c) Replace the two band-fill lines inside `drawTop` (lines 111-112):

```lua
  -- gradient bands across the whole canvas (palette-driven; recoloured for free each tick)
  style.bandFill(cv)
```

(d) Replace `updateGradient` (lines 190-199) with:

```lua
local function updateGradient(phase)
  for i = 1, #GRAD do
    local r, g, b = style.gradientRGB(i, phase)
    topMon.setPaletteColour(GRAD[i], r, g, b)
    topWin.setPaletteColour(GRAD[i], r, g, b)
  end
end
```

- [ ] **Step 6: Verify `slot.lua` still parses and nothing else regressed**

Run: `luajit -bl src/slot/slot.lua /dev/null`
Expected: no output, exit 0. (`slot.lua` calls CC globals at load, so it cannot be *run* under luajit — `-bl` only parses, which is the check we want.)

Run: `luajit test/test_slot_logic.lua && luajit test/test_slot_pay.lua && luajit test/test_pixelfont.lua && luajit test/test_slot_style.lua`
Expected: all four print `0 failed`.

- [ ] **Step 7: Confirm the constants really moved (no duplicate source of truth)**

Run: `grep -n "GRAD_DEEP\|GRAD_TEAL\|16384, 16, 8192" src/slot/slot.lua`
Expected: **no output.** If anything prints, a constant was copied instead of moved — fix it before committing. That duplication is the entire reason this task exists.

- [ ] **Step 8: Commit**

```bash
git add src/slot/slot_style.lua test/test_slot_style.lua src/slot/slot.lua
git commit -m "refactor(slot): extract slot_style so the idle advert can look like the machine"
```

---

### Task 3: Rewrite `slot_advert.lua`

**Files:**
- Rewrite: `src/slot/slot_advert.lua` (all 18 lines)

**Interfaces:**
- Consumes: `require("subpixel").new(target) -> cv` with `cv.w`, `cv.h`, `cv:setPixel`, `cv:fillRect`, `cv:render`. `require("pixelfont")` → `M.BIG`, `M.SIGN_LG`, `M.drawCentered(cv, font, str, y, color, gap, scale)`, `M.drawGlyph(cv, font, ch, x, y, color, scale)`, `M.textWidth(font, str, gap, scale)`. `require("slot_style")` → everything in Task 2's Produces list.
- Produces: `M.draw(mon)` — the contract `idle_runner.lua:125` calls. Same signature as today. Returns nothing.

**Context the implementer needs:**

- **This is called ONCE and then the station blocks** (`idle_runner.lua:125-127`). It is a single
  static frame. **No loop, no timer, no animation** — idle must cost nothing (README principle 2).
  A static gradient is fine: 5 `setPaletteColour` calls, once.
- **Do not call `setTextScale`.** `slot.lua:179` already set it to 0.5 at module load, before
  `idle_runner.run`. The canvas is **30 × 72** subpixels.
- The gradient palette slots must be **set by this function**. Un-repalette'd, `GRAD`'s slots are
  stock blue/cyan/lightBlue/purple/pink — a garish stripe. Use a fixed `phase = 0`.
- `Rl(row) = (row - 1) * 3 + 1` converts a cell row (1-24) to its top subpixel — same helper
  `slot.lua` uses. **Lua is 1-indexed.**
- **Bulbs and the cell-straddle rule (`[[monitor-ui]]`, cost a real debugging round — do not
  re-derive):** a cell is 2×3 subpixels holding at most 2 colours. A 2×2 dot at an **even x**
  straddles two cell columns and `encodeCell` shreds it. Bar-row bulbs therefore start at **x = 6**,
  not x = 2. Side-lane bulbs at `x = 1` and `x = cv.w - 1` are the *aligned* case (subpixels 1-2 and
  29-30 each sit inside one cell column) — that is what `slot.lua` already ships and it is correct.

- [ ] **Step 1: Write the file**

```lua
-- slot_advert.lua — the slot machine's static idle face. Drawn ONCE by idle_runner while the zone is
-- empty, then the station blocks on os.pullEvent — so this is a SINGLE STATIC FRAME. No loop, no
-- timer, no animation: an idle station must cost nothing (README principle 2). The gradient is
-- static; setting a palette slot is 5 calls, once, and then it is free forever.
--
-- Copy is "GET" @2x / "MONEY" @1x / a big $. "COME PLAY" is gone on purpose: an advert is designed
-- to be read from across the floor, and at 30 subpixels wide "COME PLAY" fits at NO scale (44 @1x).
-- Fitting MONEY big beats fitting COME PLAY small (owner, 2026-07-17).
local subpixel = require("subpixel")
local font     = require("pixelfont")
local style    = require("slot_style")

local M = {}

-- cell row (1-24) -> its top subpixel. Same helper as slot.lua's topLayout. 1-indexed.
local function Rl(row) return (row - 1) * 3 + 1 end

-- The 30x72 band layout. Kept as a table (not magic numbers inline) for the same reason slot.lua's
-- topLayout is: the bands are the contract, the pixel rows are tuning.
local function layout()
  return {
    topBarY = Rl(1),  topBarH = 6,     -- red bar, cell rows 1-2
    getY    = Rl(4),                   -- "GET"   @2x, 12 tall -> y 10-21
    moneyY  = Rl(10),                  -- "MONEY" @1x,  6 tall -> y 28-33
    signY   = Rl(14),                  -- SIGN_LG $, 7x14      -> y 40-53
    botBarY = Rl(23), botBarH = 6,     -- red bar, cell rows 23-24
    sideTop = Rl(3),  sideBot = Rl(22), -- side bulb lanes, between the bars
  }
end

function M.draw(mon)
  -- Static gradient: pin the ramp at phase 0 rather than animating it. Set it on the monitor
  -- directly (no window here — a single frame cannot flicker, so the window+setVisible bracket
  -- slot.lua needs buys nothing).
  for i = 1, #style.GRAD do
    local r, g, b = style.gradientRGB(i, 0)
    mon.setPaletteColour(style.GRAD[i], r, g, b)
  end

  local cv = subpixel.new(mon)
  local L  = layout()

  -- draw order IS layering: background -> bars -> bulbs -> type
  style.bandFill(cv)
  cv:fillRect(1, L.topBarY, cv.w, L.topBarH, style.RED)
  cv:fillRect(1, L.botBarY, cv.w, L.botBarH, style.RED)

  -- Bulbs. bulbTick = 0 freezes the blink; the seed alone gives a fixed alternating pattern.
  -- The bar rows START AT x=6, not x=2: a 2x2 dot at the extreme edge column straddles two cells
  -- and encodeCell renders it as a squashed sliver. This already cost the slot a debugging round
  -- (the phantom "corner bulb") -- see [[monitor-ui]]. The side lanes at x=1 and x=cv.w-1 are the
  -- ALIGNED case (subpixels 1-2 / 29-30 each sit inside one cell column) and are fine.
  for x = 6, cv.w - 2, 4 do
    style.bulb(cv, x, L.topBarY + 2, math.floor(x / 4), 0)
    style.bulb(cv, x, L.botBarY + 2, math.floor(x / 4), 0)
  end
  for y = L.sideTop, L.sideBot, 4 do
    style.bulb(cv, 1, y, math.floor(y / 4), 0)
    style.bulb(cv, cv.w - 1, y, math.floor(y / 4), 0)
  end

  -- The type. GET is the biggest thing on the machine (2x = 26 of 30); MONEY does not fit at 2x
  -- (46) so it rides at 1x (25 of 30); the $ is the owner's hand-drawn SIGN_LG, centred by hand
  -- because drawCentered works on strings and this is one glyph.
  font.drawCentered(cv, font.BIG, "GET", L.getY, style.WHITE, 1, 2)
  font.drawCentered(cv, font.BIG, "MONEY", L.moneyY, style.WHITE, 1, 1)
  local signW = font.textWidth(font.SIGN_LG, "$", 1, 1)
  font.drawGlyph(cv, font.SIGN_LG, "$", math.floor((cv.w - signW) / 2) + 1, L.signY, style.WHITE, 1)

  cv:render()
end

return M
```

- [ ] **Step 2: Syntax-check**

Run: `luajit -bl src/slot/slot_advert.lua /dev/null`
Expected: no output, exit 0.

- [ ] **Step 3: Prove it draws against a stub, and that the type fits**

This is a throwaway check — Task 5 builds the real PNG harness. Create `/tmp/check_slot_advert.lua`
(or the repo root; delete it after):

```lua
package.path = "src/lib/?.lua;src/slot/?.lua;" .. package.path
local stub = { _p = 0 }
function stub.getSize() return 15, 24 end
function stub.setCursorPos() end
function stub.blit() end
function stub.setPaletteColour() stub._p = stub._p + 1 end
local advert = require("slot_advert")
advert.draw(stub)
print("palette calls:", stub._p)
```

Run: `luajit /tmp/check_slot_advert.lua`
Expected: prints `palette calls:  5` and **does not error**. A crash here is almost certainly a
fractional or out-of-range coordinate (see `[[monitor-ui]]`).

- [ ] **Step 4: Delete the throwaway check**

```bash
rm -f /tmp/check_slot_advert.lua
```

- [ ] **Step 5: Commit**

```bash
git add src/slot/slot_advert.lua
git commit -m "feat(slot): idle advert on the alphabet -- GET @2x, MONEY, a big \$"
```

---

### Task 4: Rewrite `cage_advert.lua`

**Files:**
- Rewrite: `src/cage/cage_advert.lua` (all 48 lines)
- Modify: `src/cage/cage_rates.lua` — **the CEILING comment only. Change no code.**

**Interfaces:**
- Consumes: `require("subpixel")`, `require("pixelfont")` (`M.BIG`, `M.drawCentered`), `require("cage_rates")` → `rates.DENOMS`, a list of `{ item, value, label }`.
- Produces: `M.draw(mon)` — the contract `idle_runner.lua:125` calls. Unchanged signature.

**Context the implementer needs:**

- Canvas is **72 × 72** subpixels (36×24 cells). `cage.lua:589` already set scale 0.5 — **do not
  call `setTextScale`.**
- Single static frame, same as Task 3. No animation.
- **The signage goes subpixel; the rate table stays NATIVE.** This is `[[monitor-ui-workflow]]`'s own
  native-vs-subpixel rule, not a shortcut: signage is short/precise/large → subpixel. The rate table
  is long strings of small print → native, which is also the **denser** option (a native row is 3
  subpixels tall; a pixelfont 1x row is 6). Rendering it at 1x would cost a whole 2x signage line and
  produce a worse table.
- **Order matters: `cv:render()` FIRST, then the native `write` calls on top.** That is the real CC
  order — the subpixel canvas blits every cell, then native text overwrites the cells it occupies.
  `slot.lua` does exactly this with its header. Writing native text first means `cv:render()` erases it.
- **This branch does not repalette the cage.** Use stock colours only (`colors.red`, `colors.white`,
  `colors.black`, `colors.lightGray`). The cage's 16 slots are already spent (see todo.md: "the
  palette, not screen space, is the scarce resource") and `cage.lua` owns them.
- **`cage_advert` may use the `colors` global** — unlike `pixelfont`/`slot_style` it is not unit
  tested and only ever runs in-game. The current file already does.

- [ ] **Step 1: Write `src/cage/cage_advert.lua`**

```lua
-- cage_advert.lua — the cage's static idle face: THE CAGE / METAL IN / CASH OUT in the big font,
-- over the rate table that teaches the prices while nobody's at the kiosk. Drawn ONCE by idle_runner
-- on entering deep sleep — a SINGLE STATIC FRAME, no animation, idle must cost nothing.
--
-- The split is by ROLE, and it is [[monitor-ui-workflow]]'s native-vs-subpixel rule, not a shortcut:
-- the three signage lines are short, precise and large -> subpixel pixelfont @2x. The rate table is
-- long strings of small print -> NATIVE, which is also the DENSER option (a native row is 3
-- subpixels tall; a pixelfont 1x row is 6). Rendering the table at 1x would cost a whole 2x signage
-- line and produce a worse table.
--
-- Stock palette only: cage.lua owns this monitor's 16 colour slots and they are already spent.
local subpixel = require("subpixel")
local font     = require("pixelfont")
local rates    = require("cage_rates")

local M = {}

-- cell row (1-24) -> top subpixel. 1-indexed.
local function Rl(row) return (row - 1) * 3 + 1 end

-- 72x72 band layout. Each signage line is 8 glyphs @2x and lands within a subpixel or two of the
-- full 72: THE CAGE 69, METAL IN 71 (the tightest line on the floor), CASH OUT 69.
local BAR1_Y,  BAR1_H  = Rl(1),  6      -- cell rows 1-2
local CAGE_Y           = Rl(3)          -- "THE CAGE" @2x -> y 7-18
local BAR2_Y,  BAR2_H  = Rl(7),  6      -- cell rows 7-8
local IN_Y             = Rl(9)          -- "METAL IN" @2x -> y 25-36
local OUT_Y            = Rl(13)         -- "CASH OUT" @2x -> y 37-48
local BAR3_Y,  BAR3_H  = Rl(23), 6      -- cell rows 23-24
local RATE_ROW0        = 17             -- native CELL row; row i lands at RATE_ROW0 + i
local RATE_COL         = 12             -- native cell column, matches the old layout

function M.draw(mon)
  local cv = subpixel.new(mon)

  cv:clear(colors.black)
  cv:fillRect(1, BAR1_Y, cv.w, BAR1_H, colors.red)
  cv:fillRect(1, BAR2_Y, cv.w, BAR2_H, colors.red)
  cv:fillRect(1, BAR3_Y, cv.w, BAR3_H, colors.red)

  font.drawCentered(cv, font.BIG, "THE CAGE", CAGE_Y, colors.white, 1, 2)
  font.drawCentered(cv, font.BIG, "METAL IN", IN_Y,   colors.white, 1, 2)
  font.drawCentered(cv, font.BIG, "CASH OUT", OUT_Y,  colors.white, 1, 2)

  -- Render the subpixel layer FIRST, then lay native text over it. This order is not optional:
  -- cv:render() blits every cell, so native text written before it is erased.
  cv:render()

  -- The rate table: one row per denomination. "%-9s%5s" is what keeps the "$" column aligned
  -- regardless of label/value width (cage_rates.DENOMS is the source of truth).
  -- CEILING: rows 18-21, with the bottom bar at cell row 23 -> at most FOUR denominations. This is
  -- TIGHTER than the old layout's six, and it is the price of the 2x signage above. cage_rates.lua's
  -- CEILING note says so; a 5th metal lands on the bar.
  mon.setBackgroundColor(colors.black)
  mon.setTextColor(colors.lightGray)
  for i = 1, #rates.DENOMS do
    local d = rates.DENOMS[i]
    mon.setCursorPos(RATE_COL, RATE_ROW0 + i)
    mon.write(("%-9s%5s"):format(d.label, "$" .. d.value))
  end
end

return M
```

- [ ] **Step 2: Move the CEILING note in `cage_rates.lua`**

Find the CEILING comment in `src/cage/cage_rates.lua` (it says at most **6** denominations, because
the old advert's `row = 13 + i` collided with a bar at row 20). Replace the count and the reasoning
with the new layout's. **Change no code — the comment only.** The new text:

```lua
-- CEILING: at most FOUR denominations. cage_advert.lua draws this table at native cell rows 18-21
-- (RATE_ROW0 = 17, row i -> 17 + i) with the bottom red bar at cell row 23. A 5th entry lands on
-- the bar. This is tighter than the old six-entry ceiling and it is the deliberate price of the 2x
-- pixelfont signage above the table (2026-07-17). To add a metal, re-lay out cage_advert's bands
-- first -- this file is still the one place to edit the rates themselves.
```

- [ ] **Step 3: Verify the count is actually within the new ceiling**

Run: `luajit -e 'package.path="src/cage/?.lua;"..package.path; local r=require("cage_rates"); print(#r.DENOMS)'`
Expected: `4`. If it prints more than 4, **stop** — the advert layout is wrong for the shipped rates
and the bands need re-laying out before this task can finish.

- [ ] **Step 4: Syntax-check and re-run the cage's tests**

Run: `luajit -bl src/cage/cage_advert.lua /dev/null`
Expected: no output, exit 0.

Run: `luajit test/test_cage_rates.lua`
Expected: `0 failed` — the comment edit must not have disturbed the data.

- [ ] **Step 5: Commit**

```bash
git add src/cage/cage_advert.lua src/cage/cage_rates.lua
git commit -m "feat(cage): idle advert on the big font; rate-table ceiling 6 -> 4"
```

---

### Task 5: Offline PNG verify

**Files:**
- Modify: `test/stub_target.lua` (additive only)
- Create: `test/render_adverts.lua`
- Create: `tools/render_adverts.py`

**Interfaces:**
- Consumes: `slot_advert.draw(mon)` and `cage_advert.draw(mon)` from Tasks 3 and 4; `subpixel.encodeCell`.
- Produces: two PNGs, `docs/mockups/slot-advert.png` and `docs/mockups/cage-advert.png`. Nothing consumes these — they are for human eyes.

**Why this task exists:** `[[monitor-ui-workflow]]` step 5. It caught real bugs (type overlapping a
bar, a stray corner bulb, off-by-ones) with **zero** deploy cycles, and the deploy loop is slow
(~5-min CDN cache). **Render through `encodeCell`, not the raw `cv.buf`** — the raw buffer is not
collapsed to 2 colours per cell, which is exactly how the phantom corner bulb survived a PNG check.

- [ ] **Step 1: Extend the stub (additive — do not change existing methods)**

In `test/stub_target.lua`, add these inside `M.new`, before `return t`:

```lua
  -- Additive for the advert harness: adverts write native text and set palette slots.
  t.writes   = {}
  t.palette  = {}
  function t.write(s) t.writes[#t.writes + 1] = { x = t._x, y = t._y, text = s } end
  function t.setPaletteColour(slot, r, g, b) t.palette[slot] = { r, g, b } end
  t.setPaletteColor = t.setPaletteColour
```

- [ ] **Step 2: Write the harness**

Create `test/render_adverts.lua`:

```lua
-- render_adverts.lua — offline PNG verify ([[monitor-ui-workflow]] step 5). Draws the REAL advert
-- code against a stub monitor and dumps what the real monitor would show, with NO game and no
-- deploy. Run: luajit test/render_adverts.lua   then: python tools/render_adverts.py
--
-- Dumps through encodeCell, NOT the raw cv.buf: a cell holds at most 2 colours, and the raw buffer
-- hides every straddle/squash bug because it has not been collapsed yet. That is how a stray bulb
-- once survived a PNG check.
package.path = "src/lib/?.lua;src/slot/?.lua;src/cage/?.lua;test/?.lua;" .. package.path

-- Minimal CC globals the advert code touches. pixelfont/slot_style are pure, but cage_advert uses
-- `colors` and subpixel's render() calls blit on the target.
_G.colors = { black = 32768, red = 16384, white = 1, lightGray = 256, yellow = 16, gray = 128 }

local stub     = require("stub_target")
local subpixel = require("subpixel")

-- Capture the canvas that draw() builds. subpixel.new reads target.getSize(), so a stub of the right
-- CELL size yields a canvas of the right SUBPIXEL size -- the sizes are the thing under test.
local realNew = subpixel.new
local captured
subpixel.new = function(target) captured = realNew(target); return captured end

local function dump(name, cols, rows, mod)
  captured = nil
  local target = stub.new(cols, rows)
  require(mod).draw(target)
  assert(captured, mod .. " never built a subpixel canvas")
  local cv = captured

  -- Collapse to monitor truth: per cell, encodeCell gives the char + the 2 colours it can actually
  -- show. We re-expand to per-subpixel colours so the PNG shows exactly what the monitor shows.
  local out = io.open(name .. ".txt", "w")
  out:write(("%d %d\n"):format(cv.w, cv.h))
  local truth = {}
  for y = 1, cv.h do truth[y] = {} end
  local BITS = { 1, 2, 4, 8, 16 }
  local function unhex(h) return 2 ^ (("0123456789abcdef"):find(h, 1, true) - 1) end
  for cy = 0, rows - 1 do
    for cx = 0, cols - 1 do
      local c = {}
      for i = 0, 5 do
        local dy, dx = math.floor(i / 2), i % 2
        c[i + 1] = cv.buf[cy * 3 + dy + 1][cx * 2 + dx + 1]
      end
      local ch, fg, bg = subpixel.encodeCell(c)
      local F, B = unhex(fg), unhex(bg)   -- encodeCell returns blit hex, not colour numbers

      -- DECODE FROM THE CHAR'S BITMASK, NOT BY COMPARING COLOURS. encodeCell has an INVERT branch
      -- (when subpixel 6 is the foreground it flips the mask and swaps F/B), and on that branch a
      -- cell holding a THIRD colour displays bg where a naive `c[i] == F` test says fg. A 3-colour
      -- cell is exactly the squashed-bulb case this render exists to catch, so a decode that is
      -- wrong there is blind to its own reason for existing. The char is the ground truth:
      -- bit i set -> subpixel i shows F; subpixel 6 ALWAYS shows B (true on both branches).
      local code = string.byte(ch) - 128
      for i = 1, 5 do
        local dy, dx = math.floor((i - 1) / 2), (i - 1) % 2
        local set = (math.floor(code / BITS[i]) % 2) == 1
        truth[cy * 3 + dy + 1][cx * 2 + dx + 1] = set and F or B
      end
      truth[cy * 3 + 3][cx * 2 + 2] = B
    end
  end
  for y = 1, cv.h do
    local row = {}
    for x = 1, cv.w do row[x] = tostring(truth[y][x]) end
    out:write(table.concat(row, ",") .. "\n")
  end
  out:close()
  print(("wrote %s.txt  (%dx%d subpixels, %d native writes)"):format(name, cv.w, cv.h, #target.writes))
end

dump("slot-advert", 15, 24, "slot_advert")
dump("cage-advert", 36, 24, "cage_advert")
```

- [ ] **Step 3: Run it**

Run: `luajit test/render_adverts.lua`
Expected, exactly:
```
wrote slot-advert.txt  (30x72 subpixels, 0 native writes)
wrote cage-advert.txt  (72x72 subpixels, 4 native writes)
```
The sizes are the assertion: **30×72 and 72×72**, matching the spec. `4 native writes` = the four
denominations. `0` for the slot = it is all subpixel, as designed.

> Gotcha from `[[monitor-ui-workflow]]`: luajit's `io.open` wants a Windows path, not `/c/…`. These
> write to the cwd, so run from the repo root.

- [ ] **Step 4: Write the PNG renderer**

Create `tools/render_adverts.py`:

```python
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
```

- [ ] **Step 5: Render and LOOK at the PNGs**

Run: `python tools/render_adverts.py`
Expected: `wrote docs/mockups/slot-advert.png` and `wrote docs/mockups/cage-advert.png`.

Now **open both images and check them against the spec's layout tables.** This is a human step and it
is the point of the task. Specifically:

- **No magenta anywhere.** Magenta = a colour number the palette map does not know = a bug.
- Slot: `GET` is large and centred, `MONEY` sits below it and is clearly smaller, the `$` is below
  that, red bars top and bottom, no type touches or overlaps a bar.
- Slot: **no squashed/half bulbs**, especially at the left and right edges. That is the exact bug
  this render exists to catch.
- Cage: three signage lines, all centred, none clipped at the right edge — `METAL IN` is 71 of 72, so
  if anything is going to clip it is that line's last stroke.
- Cage: the rate table region (cell rows 18-21) is **black and empty** in the PNG. That is correct —
  native text is not in `cv.buf` and does not appear here. Reason about it separately.

If anything is wrong, fix the advert (Task 3 / Task 4 file) and re-run both commands. Do not proceed
with a bad PNG.

- [ ] **Step 6: Clean up the intermediates and commit**

```bash
rm -f slot-advert.txt cage-advert.txt
git add test/stub_target.lua test/render_adverts.lua tools/render_adverts.py docs/mockups/slot-advert.png docs/mockups/cage-advert.png
git commit -m "test: offline PNG verify for both adverts, through encodeCell"
```

---

### Task 6: `tools/font-preview.html` — the owner's review surface

**Files:**
- Create: `tools/font-preview.html`

**Interfaces:**
- Consumes: nothing at runtime — the glyph tables are transcribed into the page.
- Produces: nothing code depends on. This is a human review surface.

**Context:** `[[monitor-ui-workflow]]` step 3. **Not in the `src/` deploy loop** — it never ships to
the game. Must be **self-contained**: no CDN, no external fonts, no fetch. Plain HTML + inline CSS/JS.

> **Duplication risk, state it in the file:** the JS glyph table is a transcription of
> `pixelfont.lua`'s. If the owner redraws a glyph here it must be hand-carried back into the Lua.
> Mitigate by keeping the JS rows a **verbatim paste** of the Lua rows — same strings, same order, no
> reformatting — so a diff between them is readable.

- [ ] **Step 1: Build the page with two panels**

Create `tools/font-preview.html`. Requirements, all of which must be met:

**Header:** a one-paragraph note saying this page is a transcription of `src/lib/pixelfont.lua`, that
it is not in the deploy loop, and that redrawn glyphs must be carried back to the Lua by hand.

**Panel 1 — Specimen.**
- Every glyph in `M.BIG`: A–Z, 0–9, `! : - . ,`, and the space (draw the space's 3-wide box as a
  dashed outline so it is visible). Plus `M.SIGN_SM`, `M.SIGN_LG`, and `M.WIN`'s four glyphs.
- Each glyph rendered at **1x and 2x**, labelled with its character and its **width in subpixels**.
- Render a subpixel as a square block (8px) so the bitmap is legible; on-pixels white, off-pixels a
  dark grey so the glyph's box is visible.
- **Running-text strip** below the grid — glyphs are judged next to each other, not in isolation,
  because that is where pixel fonts actually fail (`S` vs `5`, `I` vs `T`, `M` vs `N`). Render at
  least: `THE QUICK BROWN FOX JUMPS OVER THE LAZY DOG`, `METAL IN - CASH OUT`, `GET MONEY`,
  `0123456789`, and `S5 IT MN OQ` (the confusable pairs, side by side, deliberately).

**Panel 2 — Screens.**
- The slot advert at **30×72** and the cage advert at **72×72**, side by side, each drawn with the
  same band layout as the Lua (Task 3's `layout()` and Task 4's `BAR1_Y`… constants — transcribe the
  numbers, and remember the **JS is 0-indexed where the Lua is 1-indexed**; that is the classic port
  bug this project has hit before).
- Beside each, an **`encodeCell` truth panel** — a port of `subpixel.lua`'s `encodeCell` (most
  frequent colour → bg, first different → fg, everything else falls to bg), showing the 2-colour-per-
  cell reality. `tools/slot-preview.html` already has this port; copy it rather than rewriting it.
- The cage's four native rate rows drawn as an HTML text overlay on top of the truth panel — native
  `write` is not subpixel and not subject to `encodeCell`.

- [ ] **Step 2: Open it and check it renders**

Open `tools/font-preview.html` in a browser.
Expected: both panels render, no blank areas, no console errors (check devtools).

- [ ] **Step 3: Diff the transcription against the Lua**

Run: `grep -c '"####"' src/lib/pixelfont.lua tools/font-preview.html`
Expected: **the same count in both files.** A mismatch means the transcription drifted. This is a
coarse check, not a proof — also eyeball a few glyph rows side by side.

- [ ] **Step 4: Commit**

```bash
git add tools/font-preview.html
git commit -m "tools: font-preview -- glyph specimen + both advert screens at encodeCell truth"
```

- [ ] **Step 5: Hand it to the owner**

Send the file. Ask specifically about: `S` vs `5`, `Q`'s short bowl, `I` vs `T` (they differ only in
the last row), and `M`/`W` at 5 wide against their 4-wide neighbours. Redrawn glyphs come back as
`#`/`.` rows and go straight into `M.BIG`.

---

### Task 7: The shared files — LAST, one commit, then rebase

**Files:**
- Modify: `src/packages.lua` (one line)
- Modify: `todo.md`
- Modify: `README.md`

> **This task exists as its own commit for one reason: a second session is editing these three files
> right now.** One small, late commit is the difference between a clean rebase and an ugly one.
> **Do this task last**, and rebase immediately after.

**Interfaces:**
- Consumes: `slot_style.lua` exists (Task 2).
- Produces: `update slot` in-game installs `slot_style`.

- [ ] **Step 1: Add `slot_style` to the `slot` package**

In `src/packages.lua`, in the **`slot`** package's `files` list, add this line immediately after the
`pixelfont` entry:

```lua
      { name = "slot_style",   path = "slot/slot_style.lua" },
```

**Only the `slot` package.** The cage does not use `slot_style`.

> No other manifest change is needed: `subpixel` and `pixelfont` are **already** in both the `slot`
> and `cage` package lists, so the alphabet itself ships with no manifest edit at all.

- [ ] **Step 2: Verify every file the packages name actually exists**

Run:
```bash
luajit -e 'package.path="src/?.lua;"..package.path; local p=require("packages")
for name,pkg in pairs(p) do for _,f in ipairs(pkg.files) do
  local path = "src/"..(f.path or (f.name..".lua"))
  local fh = io.open(path, "r")
  if fh then fh:close() else print("MISSING: "..name.." -> "..path) end
end end print("manifest checked")'
```
Expected: `manifest checked` and **no MISSING lines**. A missing file is a broken in-game install.

- [ ] **Step 3: Update `todo.md`**

Two edits.

(a) In the OPEN phase, replace the **"The adverts — and the real deliverable under them is a
PIXELFONT ALPHABET"** bullet and its sub-bullets with a DONE entry recording: the alphabet went into
`M.BIG` (A–Z + `! : - . ,` + space); base 4 wide with `M`/`W` at 5, matching the owner's square
digits; the **space is 3 wide because at 4 `METAL IN` @2x is 73 of 72**; `slot_style.lua` was
extracted so the idle face and the play face share one gradient; slot copy is `GET`@2x / `MONEY`@1x /
big `$` with `COME PLAY` dropped (it fits at no scale — 44 @1x on a 30-wide canvas); the cage keeps
its rate table native per the native-vs-subpixel rule; **in-world verification is PENDING and is the
owner's** — walk up to each station, walk away, read the idle face from across the floor.

(b) Add two filed-not-fixed items to the OPEN phase list:

```markdown
- **`cage_rates.DENOMS` ceiling is now FOUR, not six** (tightened 2026-07-17). `cage_advert`'s 2x
  signage pushed the native rate table down to cell rows 18-21 with the bottom bar at 23. The
  CEILING note in `cage_rates.lua` is updated. A 5th metal needs `cage_advert`'s bands re-laid out
  first. Deliberate price of readable signage; `DENOMS` ships exactly 4.
- **`pixelfont.M.SIGN_SM` is dead code.** Zero call sites — only `SIGN_LG` ships (`cage.lua:170`,
  paired with `BIG`@2x). Its "pairs with 1x digits" comment is unverified and looks wrong: `SIGN_SM`
  is 10 tall and `BIG`@1x is 6, so their baselines have never been worked out. It is the owner's
  drawing, so it was filed rather than deleted. Decide: pair it with something, or drop it.
```

- [ ] **Step 4: Update `README.md`**

In the **Components & roadmap** table, the roadmap rows for the slot and the cage. Keep it to a
clause each — README is succinct by design and this is polish, not architecture. Note that both
stations' idle adverts now run on the `pixelfont` alphabet. **Do not add a new row** and do not
restate the design; that is what the spec is for.

- [ ] **Step 5: Full green — every test, every file**

Run: `for f in test/test_*.lua; do echo "-- $f"; luajit "$f" || exit 1; done`
Expected: every file prints `0 failed`, and the loop exits 0.

Run: `for f in $(git ls-files 'src/**/*.lua' 'src/*.lua'); do luajit -bl "$f" /dev/null || echo "SYNTAX FAIL: $f"; done`
Expected: no `SYNTAX FAIL` lines.

- [ ] **Step 6: Commit**

```bash
git add src/packages.lua todo.md README.md
git commit -m "docs+deploy: alphabet status, slot_style in the slot package, two follow-ups filed"
```

- [ ] **Step 7: Rebase onto main before merging**

```bash
git fetch origin
git rebase origin/main
```

Expected: clean, or conflicts **only** in `src/packages.lua` / `todo.md` / `README.md` — the three
shared files, which is exactly why this commit is small and last. Resolve by **keeping both sides**:
the other session's multiplayer entries AND ours. If a conflict appears in any `src/lib/pixelfont.lua`,
`src/slot/*`, or `src/cage/cage_advert.lua`, **stop and ask** — that means the sessions overlapped in
a way this plan did not predict.

Then re-run Step 5's full green **after** the rebase. A rebase that compiles is not a rebase that passes.

---

## Verification (whole branch, before merge)

1. Every `test/test_*.lua` prints `0 failed`. `test_pixelfont.lua`'s original 27 assertions are
   untouched and still green.
2. `luajit -bl` passes on every `.lua` under `src/`.
3. Both PNGs in `docs/mockups/` match the spec's layout tables, with no magenta and no squashed bulbs.
4. The owner has reviewed the specimen in `tools/font-preview.html`.
5. `grep -n "GRAD_DEEP\|GRAD_TEAL" src/slot/slot.lua` returns nothing (no duplicated constants).
6. The manifest check in Task 7 Step 2 reports no MISSING files.
7. Whole-branch code review clean.
8. **In-world is the owner's, after merge+push** — the deploy loop pulls from the repo, so
   verification happens *after*. Mind the ~5-min raw-CDN cache; `update slot` and `update cage` run
   immediately after a push can fetch a stale `packages.lua` and report `slot_style` as unknown. That
   is not a bug — wait 2-5 minutes and re-run.
