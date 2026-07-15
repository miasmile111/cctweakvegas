# Slot Machine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A diegetic CC:Tweaked slot machine: tap a touchscreen SPIN button on a front 1×1 monitor, watch 3 reels spin on a top 1×2 portrait monitor, land on WIN or LOSE.

**Architecture:** A reusable `subpixel.lua` teletext-canvas library (2×3 subpixels per cell via `term.blit` + chars 128–159) renders all graphics. `slot.lua` consumes it, holds the reel/spin/win logic, and drives both monitors from one `os.pullEvent` loop. Pure logic (subpixel encoding, reel snap, win-check, blit render) is unit-tested locally with luajit against a recording stub; monitor/peripheral/loop code is verified in-game via a `test` submode.

**Tech Stack:** CraftOS / Lua 5.1 (in-game), luajit 2.1 (local test runner, Lua 5.1-compatible), CC:Tweaked advanced monitors, `term.blit`, wired modems, HTTP deploy (pastebin/gist).

## Global Constraints

- **Runtime:** CraftOS, **Lua 5.1**. No `goto`, no `//`, no native bitwise operators, no `bit`/`bit32` — use **arithmetic only** for bit math (portable across luajit-local and CC).
- **Load-time purity:** library and logic modules must reference **no CC globals** (`term`, `colors`, `peripheral`, `os.epoch`, `redstone`) at module load — only inside functions, and only via a passed-in target. This keeps them `require`-able under luajit for tests. Use numeric color codes (white=1 … black=32768 = 2^0…2^15), not the `colors` table, inside the library.
- **Palette:** advanced monitors, 16 colors. Color numbers are powers of two; blit hex digit = log2(color).
- **Monitors found by network name** (wired modem), never by side. Never hardcode monitor dimensions — read `getSize()` at runtime.
- **Diegetic input:** `monitor_touch` on the front monitor is the only gameplay control. Keyboard `Q` / Ctrl+T = admin quit only.
- **Files:** one program per file in `src/`, `.lua` extension. Header comment on each: what it does, how to run, wiring notes.
- **Flicker-free:** wrap monitor draws in a `window`; `setVisible(false)` → draw → `setVisible(true)`.
- **Deploy:** HTTP-only; in-game copy is a snapshot, re-host + re-import after each edit. Two files imported in-game: `subpixel` then `slot`.

---

## File Structure

```
src/
  lib/subpixel.lua      reusable teletext 2x3 subpixel canvas (pure at load; render binds to a target)
  slot.lua              the game: config, logic, both-monitor rendering, event loop
test/
  runner.lua            tiny assert harness (run with luajit)
  test_subpixel.lua     unit tests for subpixel encoding, buffer, render-to-stub
  test_slot_logic.lua   unit tests for reel snap + win evaluation
  stub_target.lua       fake term/monitor recording blit/setCursorPos/getSize calls
.claude/skills/cc-lua/references/subpixel-drawing.md   the harvested hack, documented
docs/superpowers/
  specs/2026-07-15-slot-machine-design.md   (source spec)
  plans/2026-07-15-slot-machine.md          (this file)
```

**One-time setup (fold into Task 1 Step 0):** the project is not yet a git repo.

```bash
cd /d/KreaFolder/cctweaked
git init
printf '.superpowers/\n' >> .gitignore
git add .gitignore docs/superpowers/specs/2026-07-15-slot-machine-design.md
git commit -m "chore: init repo, add slot machine spec"
```

If the user prefers no git, treat each "Commit" step as a review checkpoint instead.

---

## Task 1: Local test harness + subpixel cell encoding

**Files:**
- Create: `test/runner.lua`
- Create: `test/stub_target.lua`
- Create: `test/test_subpixel.lua`
- Create: `src/lib/subpixel.lua`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `runner.lua` returns `{ eq(actual, expected, msg), ok(cond, msg), done() }`.
  - `stub_target.lua` returns `new(cols, rows)` → a fake target with `.getSize()`→(cols,rows), `.setCursorPos(x,y)`, `.blit(text,fg,bg)` (appends `{y=.., text=.., fg=.., bg=..}` to `.calls`), `.setBackgroundColor/.setTextColor/.clear/.setVisible` (no-ops), `.calls` array.
  - `subpixel.encodeCell(c)` where `c` = array of 6 color numbers in order `{topL, topR, midL, midR, botL, botR}` → returns `char` (1-char string), `fgHex` (1-char), `bgHex` (1-char).

- [ ] **Step 0: One-time repo setup** — run the git init block from File Structure above.

- [ ] **Step 1: Write the test harness** — `test/runner.lua`:

```lua
-- Minimal assert harness. Run test files with: luajit test/test_xxx.lua
local M = { pass = 0, fail = 0 }
function M.eq(actual, expected, msg)
  if actual == expected then M.pass = M.pass + 1
  else M.fail = M.fail + 1
    print(("FAIL: %s\n  expected: %s\n  actual:   %s"):format(tostring(msg), tostring(expected), tostring(actual)))
  end
end
function M.ok(cond, msg)
  if cond then M.pass = M.pass + 1
  else M.fail = M.fail + 1; print("FAIL: " .. tostring(msg)) end
end
function M.done()
  print(("%d passed, %d failed"):format(M.pass, M.fail))
  if M.fail > 0 then os.exit(1) end
end
return M
```

- [ ] **Step 2: Write the recording stub** — `test/stub_target.lua`:

```lua
local M = {}
function M.new(cols, rows)
  local t = { calls = {}, _cols = cols, _rows = rows }
  function t.getSize() return t._cols, t._rows end
  function t.setCursorPos(x, y) t._x, t._y = x, y end
  function t.blit(text, fg, bg) t.calls[#t.calls + 1] = { y = t._y, text = text, fg = fg, bg = bg } end
  function t.setBackgroundColor() end
  function t.setTextColor() end
  function t.setTextScale() end
  function t.clear() end
  function t.setVisible() end
  return t
end
return M
```

- [ ] **Step 3: Write the failing test** — `test/test_subpixel.lua`:

```lua
package.path = "src/lib/?.lua;test/?.lua;" .. package.path
local t = require("runner")
local sub = require("subpixel")

local WHITE, BLACK = 1, 32768   -- 2^0, 2^15

-- uniform cell -> solid char 128, fg == bg
do
  local ch, fg, bg = sub.encodeCell({ WHITE, WHITE, WHITE, WHITE, WHITE, WHITE })
  t.eq(ch, string.char(128), "uniform -> char 128")
  t.eq(fg, bg, "uniform -> fg == bg")
  t.eq(bg, "0", "uniform white -> blit '0'")
end

-- only top-left differs -> char 129, fg = differing color
do
  local ch, fg, bg = sub.encodeCell({ BLACK, WHITE, WHITE, WHITE, WHITE, WHITE })
  t.eq(ch, string.char(129), "top-left -> char 129")
  t.eq(fg, "f", "top-left fg = black 'f'")
  t.eq(bg, "0", "top-left bg = white '0'")
end

-- only bottom-right differs -> inversion path -> char 159, colors swapped
do
  local ch, fg, bg = sub.encodeCell({ WHITE, WHITE, WHITE, WHITE, WHITE, BLACK })
  t.eq(ch, string.char(159), "bottom-right -> char 159 (inverted)")
  t.eq(fg, "0", "inverted fg = white '0'")
  t.eq(bg, "f", "inverted bg = black 'f'")
end

t.done()
```

- [ ] **Step 4: Run to verify it fails**

Run: `luajit test/test_subpixel.lua`
Expected: FAIL — `module 'subpixel' not found` (or nil index once file exists but function missing).

- [ ] **Step 5: Implement `encodeCell`** — `src/lib/subpixel.lua`:

```lua
-- subpixel.lua — reusable CC:Tweaked teletext canvas.
-- Each character cell (chars 128-159) encodes a 2x3 subpixel block: the char's
-- FOREGROUND color fills the "on" subpixels, BACKGROUND the "off" ones. Any 2x3
-- block is thus 2 colors. Pure at load (no CC globals) so it tests under luajit;
-- render() binds to a passed-in monitor/term target.
local M = {}

local BLIT = "0123456789abcdef"
local function toBlit(color)   -- color is a power of two; hex digit = log2
  local n = 0
  while color > 1 do color = color / 2; n = n + 1 end
  return BLIT:sub(n + 1, n + 1)
end
M._toBlit = toBlit

-- c = { topL, topR, midL, midR, botL, botR } color numbers -> char, fgHex, bgHex
function M.encodeCell(c)
  -- pick most frequent color as background
  local counts = {}
  for i = 1, 6 do counts[c[i]] = (counts[c[i]] or 0) + 1 end
  local bg, best = c[1], -1
  for col, n in pairs(counts) do if n > best then best, bg = n, col end end
  -- foreground = first color that isn't bg (uniform cell -> fg == bg)
  local fg = bg
  for i = 1, 6 do if c[i] ~= bg then fg = c[i]; break end end
  -- low5 bitmask over positions 1..5 (bits 1,2,4,8,16); position 6 is the invert anchor
  local bits = { 1, 2, 4, 8, 16 }
  local low5 = 0
  for i = 1, 5 do if c[i] == fg then low5 = low5 + bits[i] end end
  local char, F, B
  if c[6] == fg then          -- bottom-right is foreground -> invert so it becomes bg
    char = 128 + (31 - low5)
    F, B = bg, fg
  else
    char = 128 + low5
    F, B = fg, bg
  end
  return string.char(char), toBlit(F), toBlit(B)
end

return M
```

- [ ] **Step 6: Run to verify it passes**

Run: `luajit test/test_subpixel.lua`
Expected: PASS — `... passed, 0 failed`.

- [ ] **Step 7: Commit**

```bash
git add test/ src/lib/subpixel.lua
git commit -m "feat(subpixel): teletext cell encoding + local test harness"
```

---

## Task 2: Subpixel canvas buffer (setPixel / clear / fillRect / drawSprite)

**Files:**
- Modify: `src/lib/subpixel.lua`
- Modify: `test/test_subpixel.lua`

**Interfaces:**
- Consumes: `M.encodeCell` (Task 1).
- Produces:
  - `M.new(target)` → canvas object bound to a target (reads `target.getSize()` → cols,rows; buffer is `cols*2` wide, `rows*3` tall, filled with 32768/black).
  - `canvas:clear(color)`
  - `canvas:setPixel(x, y, color)` (1-indexed; off-canvas is a silent no-op)
  - `canvas:getPixel(x, y)` → color (for tests)
  - `canvas:fillRect(x, y, w, h, color)`
  - `canvas:drawSprite(x, y, sprite)` where `sprite = { w=, h=, px={...} }`, `px` a row-major array of color numbers, `0` = transparent (skipped).
  - `canvas.cols`, `canvas.rows`, `canvas.w`, `canvas.h`.

- [ ] **Step 1: Write the failing tests** — append to `test/test_subpixel.lua` (before `t.done()`):

```lua
-- buffer geometry + setPixel/getPixel
do
  local stub = require("stub_target").new(3, 2)   -- 3 cols x 2 rows
  local cv = sub.new(stub)
  t.eq(cv.w, 6, "canvas width = cols*2")
  t.eq(cv.h, 6, "canvas height = rows*3")
  cv:clear(1)                    -- white
  t.eq(cv:getPixel(1, 1), 1, "clear sets pixels")
  cv:setPixel(2, 3, 32768)       -- black
  t.eq(cv:getPixel(2, 3), 32768, "setPixel sets one pixel")
  cv:setPixel(999, 999, 1)       -- off-canvas no-op (must not error)
  t.ok(true, "off-canvas setPixel is a no-op")
end

-- fillRect + drawSprite (transparent 0 skipped)
do
  local stub = require("stub_target").new(2, 1)
  local cv = sub.new(stub)
  cv:clear(1)
  cv:fillRect(1, 1, 2, 2, 32768)
  t.eq(cv:getPixel(1, 1), 32768, "fillRect top-left")
  t.eq(cv:getPixel(2, 2), 32768, "fillRect bottom-right")
  t.eq(cv:getPixel(3, 1), 1, "fillRect respects width")
  local sprite = { w = 2, h = 1, px = { 0, 2 } }   -- 0 transparent, 2 orange
  cv:drawSprite(1, 1, sprite)
  t.eq(cv:getPixel(1, 1), 32768, "sprite transparent pixel unchanged")
  t.eq(cv:getPixel(2, 1), 2, "sprite opaque pixel drawn")
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `luajit test/test_subpixel.lua`
Expected: FAIL — `attempt to call method 'new'` (nil).

- [ ] **Step 3: Implement the canvas** — add to `src/lib/subpixel.lua` before `return M`:

```lua
local Canvas = {}
Canvas.__index = Canvas

function M.new(target)
  local cols, rows = target.getSize()
  local self = setmetatable({}, Canvas)
  self.target = target
  self.cols, self.rows = cols, rows
  self.w, self.h = cols * 2, rows * 3
  self.buf = {}
  self:clear(32768)   -- black
  return self
end

function Canvas:clear(color)
  for y = 1, self.h do
    local row = {}
    for x = 1, self.w do row[x] = color end
    self.buf[y] = row
  end
end

function Canvas:getPixel(x, y)
  local row = self.buf[y]
  return row and row[x] or nil
end

function Canvas:setPixel(x, y, color)
  if x < 1 or y < 1 or x > self.w or y > self.h then return end
  self.buf[y][x] = color
end

function Canvas:fillRect(x, y, w, h, color)
  for dy = 0, h - 1 do
    for dx = 0, w - 1 do self:setPixel(x + dx, y + dy, color) end
  end
end

-- sprite = { w=, h=, px = { row-major color numbers, 0 = transparent } }
function Canvas:drawSprite(x, y, sprite)
  for dy = 0, sprite.h - 1 do
    for dx = 0, sprite.w - 1 do
      local col = sprite.px[dy * sprite.w + dx + 1]
      if col and col ~= 0 then self:setPixel(x + dx, y + dy, col) end
    end
  end
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `luajit test/test_subpixel.lua`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/lib/subpixel.lua test/test_subpixel.lua
git commit -m "feat(subpixel): pixel buffer, fillRect, drawSprite"
```

---

## Task 3: Subpixel render to target (blit rows)

**Files:**
- Modify: `src/lib/subpixel.lua`
- Modify: `test/test_subpixel.lua`

**Interfaces:**
- Consumes: `M.encodeCell`, `Canvas` buffer (Tasks 1–2), `stub_target` recording `.blit`.
- Produces: `canvas:render()` — for each cell row `cy` (1..rows), builds three strings of length `cols` (chars/fg/bg) by encoding each cell's 2×3 pixel group from the buffer, then `target.setCursorPos(1, cy)` and `target.blit(text, fg, bg)`. Emits exactly `rows` blit calls.

- [ ] **Step 1: Write the failing test** — append to `test/test_subpixel.lua` (before `t.done()`):

```lua
-- render emits one blit per cell-row; a black canvas -> all char 128, bg 'f'
do
  local stub = require("stub_target").new(2, 1)   -- 2 cols x 1 row -> one blit
  local cv = sub.new(stub)                          -- cleared to black (32768)
  cv:render()
  t.eq(#stub.calls, 1, "render: one blit per cell row")
  local call = stub.calls[1]
  t.eq(#call.text, 2, "blit text length == cols")
  t.eq(call.text, string.char(128) .. string.char(128), "black canvas -> char 128 cells")
  t.eq(call.bg, "ff", "black canvas -> bg 'f' per cell")
end

-- a single subpixel lights the correct cell
do
  local stub = require("stub_target").new(2, 1)
  local cv = sub.new(stub)                          -- black
  cv:setPixel(1, 1, 1)                              -- top-left of cell 1 -> white
  cv:render()
  local call = stub.calls[1]
  t.eq(call.text:byte(1), 129, "lit top-left -> char 129 in cell 1")
  t.eq(call.text:byte(2), 128, "cell 2 untouched -> char 128")
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `luajit test/test_subpixel.lua`
Expected: FAIL — `attempt to call method 'render'` (nil).

- [ ] **Step 3: Implement `render`** — add to `src/lib/subpixel.lua` before `return M`:

```lua
function Canvas:render()
  local tgt = self.target
  for cy = 1, self.rows do
    local py = (cy - 1) * 3            -- top subpixel row of this cell
    local text, fg, bg = {}, {}, {}
    for cx = 1, self.cols do
      local px = (cx - 1) * 2
      local cell = {
        self.buf[py + 1][px + 1], self.buf[py + 1][px + 2],
        self.buf[py + 2][px + 1], self.buf[py + 2][px + 2],
        self.buf[py + 3][px + 1], self.buf[py + 3][px + 2],
      }
      local ch, f, b = M.encodeCell(cell)
      text[cx], fg[cx], bg[cx] = ch, f, b
    end
    tgt.setCursorPos(1, cy)
    tgt.blit(table.concat(text), table.concat(fg), table.concat(bg))
  end
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `luajit test/test_subpixel.lua`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/lib/subpixel.lua test/test_subpixel.lua
git commit -m "feat(subpixel): render buffer to target via term.blit rows"
```

---

## Task 4: Document the subpixel hack in the cc-lua skill

**Files:**
- Create: `.claude/skills/cc-lua/references/subpixel-drawing.md`

**Interfaces:**
- Consumes: the finished `src/lib/subpixel.lua`.
- Produces: a skill reference doc (no code contract). This is a documentation task — no automated test; the deliverable is the doc itself.

- [ ] **Step 1: Write the reference doc** — `.claude/skills/cc-lua/references/subpixel-drawing.md`:

````markdown
# Subpixel (teletext) drawing on CC monitors — reusable hack

CC:Tweaked characters **128–159** each render a **2×3 subpixel** block. The character's
**foreground** color fills the "on" subpixels; **background** fills the "off" ones — so any
2×3 block is expressible in **exactly two colors**. `term.blit(text, fg, bg)` writes a whole
row of these cells in one call. Net effect: a monitor of `cols × rows` characters becomes a
**`(cols*2) × (rows*3)` pixel canvas** — 6× the resolution — at the cost of 2 colors per cell.

## Encoding

Positions in a cell: `{ topL, topR, midL, midR, botL, botR }`. Bits for the first five:
`topL=1, topR=2, midL=4, midR=8, botL=16`. The **bottom-right** pixel is the "invert anchor":
32 chars (128–159) cover all 64 combos because you may swap fg/bg. Algorithm (arithmetic only,
Lua 5.1 safe):

1. Pick the most frequent color as `bg`, the first differing color as `fg`.
2. `low5` = sum of bits where that position's pixel == `fg`.
3. If bottom-right == `fg`: `char = 128 + (31 - low5)`, and swap fg/bg. Else `char = 128 + low5`.
4. blit hex per color = `log2(color)` → `"0123456789abcdef"`.

## Reuse

`src/lib/subpixel.lua` is the canonical implementation. It is **pure at load** (no CC globals),
so it runs under luajit for unit tests and in CraftOS for real:

```lua
local subpixel = require("subpixel")     -- or dofile if require path isn't set
local canvas = subpixel.new(monitor)     -- reads monitor.getSize()
canvas:clear(colors.black)
canvas:setPixel(x, y, colors.red)        -- 1-indexed, (cols*2 x rows*3) space
canvas:fillRect(x, y, w, h, colors.white)
canvas:drawSprite(x, y, { w=, h=, px={ row-major colors, 0=transparent } })
canvas:render()                          -- flush to the monitor via blit
```

Wrap the monitor in a `window` and flush with `setVisible` for flicker-free animation. Define
game art as `sprite` data tables so new icons need no new code.

See `src/slot.lua` for a working consumer (reel symbols, beveled button, chasing lights).
````

- [ ] **Step 2: Verify it reads correctly** — open the file, confirm the encoding steps match `encodeCell` in `src/lib/subpixel.lua` (bit values, the `31 - low5` invert). Fix any drift.

- [ ] **Step 3: Commit**

```bash
git add .claude/skills/cc-lua/references/subpixel-drawing.md
git commit -m "docs(cc-lua): reference the subpixel drawing hack"
```

---

## Task 5: Reel + win logic (pure)

**Files:**
- Create: `src/slot_logic.lua`
- Create: `test/test_slot_logic.lua`

**Interfaces:**
- Consumes: nothing (pure, load-safe — no CC globals; RNG injected).
- Produces `src/slot_logic.lua` returning `L` with:
  - `L.NUM_SYMBOLS` = 4 (seven, cherry, bell, bar indices 1..4).
  - `L.newReel(finalSymbol, stopTick)` → `{ final=, stopTick=, offset=0, stopped=false }`.
  - `L.stepReel(reel, tick, symbolPx)` → mutates: while `tick < reel.stopTick`, `offset` grows by a fixed spin speed (blur); at/after `stopTick`, snap `offset` to `0` and set `stopped=true`. Returns `reel.stopped`.
  - `L.isWin(a, b, c)` → boolean (all three equal).
  - `L.pickFinals(rng)` → `a, b, c` each `= 1 + floor(rng() * NUM_SYMBOLS)` (rng returns [0,1)).

- [ ] **Step 1: Write the failing tests** — `test/test_slot_logic.lua`:

```lua
package.path = "src/?.lua;test/?.lua;" .. package.path
local t = require("runner")
local L = require("slot_logic")

-- win check
t.ok(L.isWin(3, 3, 3), "three equal -> win")
t.ok(not L.isWin(3, 3, 2), "one different -> lose")

-- reel stops exactly at stopTick and snaps offset to 0
do
  local reel = L.newReel(2, 5)   -- final symbol 2, stops at tick 5
  local stopped = L.stepReel(reel, 3, 8)
  t.ok(not stopped, "before stopTick: still spinning")
  t.ok(reel.offset > 0, "before stopTick: offset advanced (blur)")
  L.stepReel(reel, 5, 8)
  t.ok(reel.stopped, "at stopTick: stopped")
  t.eq(reel.offset, 0, "on stop: offset snapped to 0")
end

-- pickFinals maps rng [0,1) into 1..NUM_SYMBOLS
do
  local seq = { 0.0, 0.999, 0.5 }
  local i = 0
  local rng = function() i = i + 1; return seq[i] end
  local a, b, c = L.pickFinals(rng)
  t.eq(a, 1, "rng 0.0 -> symbol 1")
  t.eq(b, L.NUM_SYMBOLS, "rng ~1 -> last symbol")
  t.ok(c >= 1 and c <= L.NUM_SYMBOLS, "rng mid -> in range")
end

t.done()
```

- [ ] **Step 2: Run to verify it fails**

Run: `luajit test/test_slot_logic.lua`
Expected: FAIL — `module 'slot_logic' not found`.

- [ ] **Step 3: Implement** — `src/slot_logic.lua`:

```lua
-- slot_logic.lua — pure reel/win logic (no CC globals; RNG injected). Testable under luajit.
local L = {}
L.NUM_SYMBOLS = 4
local SPIN_SPEED = 3   -- subpixels of blur scroll per tick while spinning

function L.newReel(finalSymbol, stopTick)
  return { final = finalSymbol, stopTick = stopTick, offset = 0, stopped = false }
end

function L.stepReel(reel, tick, symbolPx)
  if reel.stopped then return true end
  if tick >= reel.stopTick then
    reel.offset = 0
    reel.stopped = true
  else
    reel.offset = (reel.offset + SPIN_SPEED) % symbolPx
  end
  return reel.stopped
end

function L.isWin(a, b, c)
  return a == b and b == c
end

function L.pickFinals(rng)
  local function pick() return 1 + math.floor(rng() * L.NUM_SYMBOLS) end
  return pick(), pick(), pick()
end

return L
```

- [ ] **Step 4: Run to verify it passes**

Run: `luajit test/test_slot_logic.lua`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/slot_logic.lua test/test_slot_logic.lua
git commit -m "feat(slot): pure reel + win logic with injected RNG"
```

---

## Task 6: Symbol sprite data

**Files:**
- Create: `src/slot_symbols.lua`
- Modify: `test/test_slot_logic.lua`

**Interfaces:**
- Consumes: nothing (pure data).
- Produces: `src/slot_symbols.lua` returning array `S[1..4]`, each a sprite `{ w=, h=, px={...} }` (same shape `drawSprite` consumes). Indices: 1=seven, 2=cherry, 3=bell, 4=bar. All sprites share one `w`,`h` (fit a reel cell-group; use `w=8, h=9`). `px` uses numeric colors (0 = transparent).

- [ ] **Step 1: Write the failing test** — append to `test/test_slot_logic.lua` (before `t.done()`):

```lua
-- symbols are well-formed sprites, one per logic symbol
do
  local S = require("slot_symbols")
  t.eq(#S, L.NUM_SYMBOLS, "one sprite per symbol")
  for i = 1, #S do
    t.ok(S[i].w > 0 and S[i].h > 0, "sprite " .. i .. " has size")
    t.eq(#S[i].px, S[i].w * S[i].h, "sprite " .. i .. " px count == w*h")
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `luajit test/test_slot_logic.lua`
Expected: FAIL — `module 'slot_symbols' not found`.

- [ ] **Step 3: Implement** — `src/slot_symbols.lua`. Colors: red=16384? No — use CC numbers: white=1, red=16384, yellow=16, orange=2, lime=32, green=8192, black=32768. Build each 8×9 sprite row-major (0 = transparent). Example uses a compact builder so rows are readable:

```lua
-- slot_symbols.lua — reel icons as subpixel sprite data (0 = transparent).
local W, H = 8, 9
local C = { _=0, r=16384, y=16, o=2, l=32, g=8192, k=32768, w=1 }
-- build sprite from H strings of W chars keyed into C
local function make(rows)
  local px = {}
  for y = 1, H do
    local line = rows[y]
    for x = 1, W do px[(y - 1) * W + x] = C[line:sub(x, x)] end
  end
  return { w = W, h = H, px = px }
end

local seven = make({
  "rrrrrrrr",
  "rrrrrrrr",
  "______rr",
  "_____rr_",
  "____rr__",
  "___rr___",
  "__rr____",
  "__rr____",
  "__rr____",
})
local cherry = make({
  "_____gg_",
  "____gg__",
  "_g__g___",
  "rrr_rrr_",
  "rrrrrrrr",
  "rrrrrrrr",
  "_rrr_rr_",
  "__r___r_",
  "________",
})
local bell = make({
  "___yy___",
  "__yyyy__",
  "__yyyy__",
  "_yyyyyy_",
  "_yyyyyy_",
  "yyyyyyyy",
  "yyyyyyyy",
  "___kk___",
  "___kk___",
})
local bar = make({
  "kkkkkkkk",
  "kwwwwwwk",
  "kw_ww_wk",
  "kw_ww_wk",
  "kwwwwwwk",
  "kw_ww_wk",
  "kw_ww_wk",
  "kwwwwwwk",
  "kkkkkkkk",
})
return { seven, cherry, bell, bar }
```

- [ ] **Step 4: Run to verify it passes**

Run: `luajit test/test_slot_logic.lua`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/slot_symbols.lua test/test_slot_logic.lua
git commit -m "feat(slot): reel symbol sprite data"
```

---

## Task 7: Slot config, monitor discovery, and `test` submode

**Files:**
- Create: `src/slot.lua`

**Interfaces:**
- Consumes: nothing yet (this task establishes the program skeleton). Later tasks add rendering + loop.
- Produces the program skeleton with:
  - A config block: `TOP_NAME`, `FRONT_NAME` (network names of the two monitors), `TOP_SCALE`, `FRONT_SCALE`.
  - `findMon(name)` → monitor peripheral or clear `error`.
  - `slot test` submode: prints every attached monitor's name + `getSize` at the configured scale, and enters a loop echoing `monitor_touch` events (side + x,y) until `Q`. Cleans up on exit.
- **This task is verified in-game** (needs peripherals) — no luajit test. Deliverable = running `slot test` shows monitor names/sizes and touch coords.

- [ ] **Step 1: Write the skeleton** — `src/slot.lua`:

```lua
-- slot.lua — diegetic slot machine on two CC:Tweaked advanced monitors.
--   Top monitor (1x2 portrait) shows the reels; front monitor (1x1) is the touch SPIN button.
--   Run:  slot          -> play (tap the front monitor to spin)
--   Run:  slot test     -> list monitors + sizes, echo touch coords (to fill config below)
--
-- Wiring: put BOTH advanced monitors on a wired modem + networking cable so they don't use up
-- computer sides. Run `slot test`, note each monitor's network name + which one is front/top,
-- then set TOP_NAME / FRONT_NAME below. Re-host + re-import after editing (HTTP snapshot).

-- ---- config ----------------------------------------------------------------
local TOP_NAME   = "monitor_0"   -- 1x2 portrait play monitor (network name)
local FRONT_NAME = "monitor_1"   -- 1x1 touch button monitor
local TOP_SCALE  = 0.5
local FRONT_SCALE = 0.5
-- ----------------------------------------------------------------------------

local args = { ... }

local function findMon(name)
  local m = peripheral.wrap(name)
  if not m or peripheral.getType(name) ~= "monitor" then
    error(("Monitor '%s' not found. Run `slot test` to list names, then edit config."):format(name), 0)
  end
  return m
end

local function testMode()
  print("Attached monitors:")
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "monitor" then
      local m = peripheral.wrap(name)
      m.setTextScale(0.5)
      local w, h = m.getSize()
      print(("  %s  ->  %d x %d  @0.5"):format(name, w, h))
    end
  end
  print("Tap a monitor (Q to quit). Coords print below:")
  while true do
    local ev = { os.pullEvent() }
    if ev[1] == "monitor_touch" then
      print(("touch: %s  x=%d y=%d"):format(ev[2], ev[3], ev[4]))
    elseif ev[1] == "key" and ev[2] == keys.q then
      return
    end
  end
end

if args[1] == "test" then
  testMode()
  print("Test mode done.")
  return
end

-- (play mode wired up in later tasks)
print("slot: play mode not yet implemented — run `slot test` for now.")
```

- [ ] **Step 2: Syntax-check locally**

Run: `luajit -bl src/slot.lua /dev/null` (byte-compiles; catches syntax errors without running CC APIs)
Expected: no output, exit 0. (If luajit rejects a CC-only global it will NOT — this only parses.)

- [ ] **Step 3: In-game verification** — host `src/lib/subpixel.lua` and `src/slot.lua`, import both, run `slot test`. Confirm: both monitors listed with sizes; tapping the front monitor prints its name + coords. Record the real network names into `TOP_NAME`/`FRONT_NAME`.

- [ ] **Step 4: Commit**

```bash
git add src/slot.lua
git commit -m "feat(slot): program skeleton, monitor discovery, test submode"
```

---

## Task 8: Top-monitor rendering (marquee, reels, payline, bulbs, banner)

**Files:**
- Modify: `src/slot.lua`

**Interfaces:**
- Consumes: `subpixel` (Tasks 1–3), `slot_symbols` (Task 6), `slot_logic` reels (Task 5).
- Produces `drawTop(canvas, reels, phase, bulbTick, result)` — draws onto the top monitor's subpixel canvas: reserved dark upper block, margin, marquee title, 3 vertical reels (each showing its current + neighbor symbols offset by `reel.offset`), lit center payline row, chasing bulb columns keyed to `bulbTick`, and the WIN!/LOSE banner when `result` is set. Uses `canvas:drawSprite` for symbols. **In-game visual verification.**

- [ ] **Step 1: Add rendering helpers + `drawTop`** to `src/slot.lua` (above the `if args[1]=="test"` block, after `findMon`):

```lua
local subpixel = require("subpixel")
local SYMBOLS  = require("slot_symbols")
local logic    = require("slot_logic")

local RED, YELLOW, GREEN, WHITE, BLACK, GREY = 16384, 16, 8192, 1, 32768, 128
local SYM_W, SYM_H = 8, 9
local REEL_GAP = 2

-- layout computed from the canvas size so it fits any real monitor
local function topLayout(cv)
  local playTop = math.floor(cv.h * 0.45)         -- upper ~45% reserved for scoreboard
  local reelsX  = math.floor((cv.w - (3 * SYM_W + 2 * REEL_GAP)) / 2) + 1
  local paylineY = playTop + 12                    -- center row baseline
  return { playTop = playTop, reelsX = reelsX, paylineY = paylineY }
end

local function drawReel(cv, x, centerY, reel, dimAbove)
  -- center symbol
  cv:drawSprite(x, centerY, SYMBOLS[reel.final])
  -- dim spin-past neighbors above/below (drawn darker by overlaying a translucent-ish band:
  -- simplest: draw neighbor sprites shifted by offset; CC has no alpha, so we just draw them)
  local above = SYMBOLS[(reel.final % logic.NUM_SYMBOLS) + 1]
  local below = SYMBOLS[((reel.final - 2) % logic.NUM_SYMBOLS) + 1]
  cv:drawSprite(x, centerY - SYM_H - 1 + (reel.offset or 0), above)
  cv:drawSprite(x, centerY + SYM_H + 1 + (reel.offset or 0), below)
end

local function drawTop(cv, reels, phase, bulbTick, result)
  cv:clear(BLACK)
  local L = topLayout(cv)
  -- marquee bar
  cv:fillRect(1, L.playTop, cv.w, 3, RED)
  -- payline highlight band
  cv:fillRect(1, L.paylineY - 1, cv.w, SYM_H + 2, GREY)
  -- reels
  for i = 1, 3 do
    local x = L.reelsX + (i - 1) * (SYM_W + REEL_GAP)
    drawReel(cv, x, L.paylineY, reels[i], true)
  end
  -- chasing bulb columns (both sides)
  for y = L.playTop, cv.h - 3, 4 do
    local on = ((math.floor(y / 4) + bulbTick) % 2 == 0)
    local c = on and YELLOW or GREY
    cv:fillRect(1, y, 2, 2, c)
    cv:fillRect(cv.w - 1, y, 2, 2, c)
  end
  -- result banner
  if result == "win" then
    cv:fillRect(1, cv.h - 5, cv.w, 5, GREEN)
  elseif result == "lose" then
    cv:fillRect(1, cv.h - 5, cv.w, 5, RED)
  end
  cv:render()
end
```

- [ ] **Step 2: Add a temporary render-once path** so it can be eyeballed in-game before the loop exists. Replace the final placeholder `print(...)` line with:

```lua
local topMon = findMon(TOP_NAME)
topMon.setTextScale(TOP_SCALE)
local topCv = subpixel.new(topMon)
local demoReels = {
  logic.newReel(1, 0), logic.newReel(1, 0), logic.newReel(1, 0),
}
for _, r in ipairs(demoReels) do r.stopped = true end
drawTop(topCv, demoReels, "idle", 0, "win")
print("Rendered a demo frame to the top monitor. Ctrl+T to exit.")
```

- [ ] **Step 3: Syntax-check** — `luajit -bl src/slot.lua /dev/null` → exit 0.

- [ ] **Step 4: In-game verification** — re-host + re-import `subpixel`, `slot_symbols`, `slot_logic`, `slot`; run `slot`. Confirm the top monitor shows: reserved dark upper area, red marquee, three `7` symbols on a lit payline, yellow bulb columns, green WIN banner. Note any layout overflow (symbols clipped) and adjust `topLayout` constants. Iterate until it reads clearly.

- [ ] **Step 5: Commit**

```bash
git add src/slot.lua
git commit -m "feat(slot): top monitor render — marquee, reels, payline, bulbs, banner"
```

---

## Task 9: Front-monitor button rendering (bevel, states, chasing border)

**Files:**
- Modify: `src/slot.lua`

**Interfaces:**
- Consumes: `subpixel`.
- Produces `drawButton(canvas, state, borderTick)` where `state` ∈ `"idle" | "pressed" | "locked"`: draws a beveled 3D button filling the canvas (light top/left edges, dark bottom/right; inverted when pressed/locked), the label (`SPIN` idle/pressed, `WAIT` locked) via a simple block-letter routine or sprite, and a chasing light border around the perimeter keyed to `borderTick`. **In-game visual verification.**

- [ ] **Step 1: Add `drawButton`** to `src/slot.lua` (after `drawTop`):

```lua
local ORANGE = 2
local RED_D  = 16384   -- reuse RED as base; darker shade approximated with GREY edge

local function drawBorder(cv, tick)
  -- march a lit cell around the perimeter; every 3rd perimeter slot is "on"
  local lit = YELLOW
  local dim = ORANGE
  local i = 0
  local function seg(x, y) local on = ((i + tick) % 3 == 0); cv:fillRect(x, y, 2, 2, on and lit or dim); i = i + 1 end
  for x = 1, cv.w - 1, 2 do seg(x, 1) end
  for y = 3, cv.h - 1, 2 do seg(cv.w - 1, y) end
  for x = cv.w - 1, 1, -2 do seg(x, cv.h - 1) end
  for y = cv.h - 1, 3, -2 do seg(1, y) end
end

local function drawButton(cv, state, borderTick)
  cv:clear(BLACK)
  local m = 4                                   -- border margin
  local x, y, w, h = m, m, cv.w - 2 * m, cv.h - 2 * m
  local pressed = (state ~= "idle")
  local face = pressed and 8192 or RED          -- pressed: dark (green stand-in? use darker red)
  face = pressed and 16384 or 16384             -- keep red; differentiate via bevel only
  local hi, lo = WHITE, GREY
  if pressed then hi, lo = GREY, WHITE end
  cv:fillRect(x, y, w, h, RED)
  -- bevel: top + left highlight, bottom + right shadow (swapped when pressed)
  cv:fillRect(x, y, w, 1, hi); cv:fillRect(x, y, 1, h, hi)
  cv:fillRect(x, y + h - 1, w, 1, lo); cv:fillRect(x + w - 1, y, 1, h, lo)
  drawBorder(cv, borderTick)
  cv:render()
  -- label via monitor text overlay (crisp) — draw after render using the raw monitor:
  return state == "locked" and "WAIT" or "SPIN"
end
```

Note: the label is returned so the caller can `mon.setCursorPos`/`mon.write` it as plain text centered over the button (glyph text is crisper than subpixel for letters). The caller (Task 10) does the text overlay.

- [ ] **Step 2: Temporary front-render path** — extend the demo section from Task 8 Step 2 to also draw the button:

```lua
local frontMon = findMon(FRONT_NAME)
frontMon.setTextScale(FRONT_SCALE)
local frontCv = subpixel.new(frontMon)
local label = drawButton(frontCv, "idle", 0)
local fw, fh = frontMon.getSize()
frontMon.setTextColor(WHITE)
frontMon.setCursorPos(math.floor((fw - #label) / 2) + 1, math.floor(fh / 2) + 1)
frontMon.write(label)
```

- [ ] **Step 3: Syntax-check** — `luajit -bl src/slot.lua /dev/null` → exit 0.

- [ ] **Step 4: In-game verification** — re-host + re-import; run `slot`. Confirm the front monitor shows a red beveled button labelled `SPIN` with a chasing yellow border. Temporarily hardcode `"pressed"` then `"locked"` to eyeball those states (bevel inverts, label → `WAIT`). Revert to `"idle"`.

- [ ] **Step 5: Commit**

```bash
git add src/slot.lua
git commit -m "feat(slot): front monitor beveled button + chasing border"
```

---

## Task 10: Main event loop (spin, animate, evaluate, cleanup)

**Files:**
- Modify: `src/slot.lua`

**Interfaces:**
- Consumes: `drawTop`, `drawButton`, `logic`, both canvases/monitors.
- Produces the play loop: replace the Task 8/9 temporary demo section with the real loop. States: `idle` (accept touch) → `spinning` (animate reels + button, staggered stops) → `result` (show banner ~2s) → back to `idle`. `monitor_touch` on the front monitor starts a spin; touches while spinning are ignored. `Q`/Ctrl+T quits with cleanup.

- [ ] **Step 1: Replace the temporary demo section** (everything after `drawButton` definition, i.e. Task 8 Step 2 + Task 9 Step 2 blocks) with the loop:

```lua
-- ===== PLAY =================================================================
math.randomseed(os.epoch("utc"))
local rng = function() return math.random() end

local topMon = findMon(TOP_NAME);   topMon.setTextScale(TOP_SCALE)
local frontMon = findMon(FRONT_NAME); frontMon.setTextScale(FRONT_SCALE)
local topCv = subpixel.new(topMon)
local frontCv = subpixel.new(frontMon)
local fw, fh = frontMon.getSize()

local TICK = 0.05
local SYMBOL_PX = SYM_H + 2

local function drawFront(state, borderTick)
  local label = drawButton(frontCv, state, borderTick)
  frontMon.setTextColor(WHITE)
  frontMon.setCursorPos(math.floor((fw - #label) / 2) + 1, math.floor(fh / 2) + 1)
  frontMon.write(label)
end

local function newSpin()
  local a, b, c = logic.pickFinals(rng)
  return {
    logic.newReel(a, 12),   -- staggered stop ticks
    logic.newReel(b, 20),
    logic.newReel(c, 28),
  }
end

local state = "idle"        -- idle | spinning | result
local reels = newSpin()
for _, r in ipairs(reels) do r.stopped = true end
local tick, spinTick, resultAt, result = 0, 0, nil, nil

drawTop(topCv, reels, "idle", 0, nil)
drawFront("idle", 0)
local timer = os.startTimer(TICK)

while true do
  local ev = { os.pullEvent() }
  if ev[1] == "timer" and ev[2] == timer then
    tick = tick + 1
    if state == "spinning" then
      spinTick = spinTick + 1
      local allStopped = true
      for _, r in ipairs(reels) do
        if not logic.stepReel(r, spinTick, SYMBOL_PX) then allStopped = false end
      end
      drawTop(topCv, reels, "spin", tick, nil)
      drawFront("locked", tick)
      if allStopped then
        result = logic.isWin(reels[1].final, reels[2].final, reels[3].final) and "win" or "lose"
        drawTop(topCv, reels, "result", tick, result)
        state, resultAt = "result", tick
      end
    elseif state == "result" then
      drawFront("idle", tick)
      if tick - resultAt > 40 then          -- ~2s banner
        result = nil
        drawTop(topCv, reels, "idle", tick, nil)
        state = "idle"
      end
    else -- idle: keep the attract border + bulbs alive
      drawTop(topCv, reels, "idle", tick, nil)
      drawFront("idle", tick)
    end
    timer = os.startTimer(TICK)
  elseif ev[1] == "monitor_touch" and ev[2] == FRONT_NAME and state == "idle" then
    reels = newSpin()
    state, spinTick = "spinning", 0
    drawFront("pressed", tick)
  elseif ev[1] == "key" and ev[2] == keys.q then
    break
  end
end

-- cleanup
for _, m in ipairs({ topMon, frontMon }) do
  m.setBackgroundColor(colors.black); m.clear(); m.setCursorPos(1, 1); m.setTextScale(1)
end
print("Thanks for playing Slots!")
```

- [ ] **Step 2: Syntax-check** — `luajit -bl src/slot.lua /dev/null` → exit 0.

- [ ] **Step 3: In-game verification** — re-host + re-import all files; run `slot`. Confirm the full loop: idle button + chasing border + live bulbs; tap front monitor → button shows pressed then locked, reels blur and stop left→right, banner flips WIN!/LOSE, returns to idle after ~2s; tapping mid-spin is ignored; `Q` cleans up both monitors. Tune stop ticks / banner duration / layout constants as needed.

- [ ] **Step 4: Commit**

```bash
git add src/slot.lua
git commit -m "feat(slot): main event loop — spin, animate, evaluate, cleanup"
```

---

## Task 11: End-to-end polish pass + README note

**Files:**
- Modify: `src/slot.lua` (tuning only)
- Modify: `README.md`

**Interfaces:**
- Consumes: the whole working game.
- Produces: final tuned constants + a README section documenting import + wiring. No new code contract.

- [ ] **Step 1: Play-test tuning** — in-game, confirm reel blur speed reads as spinning (not too fast/slow), stop stagger feels like a slot, bulbs/border chase smoothly, symbols aren't clipped on the real monitor size. Adjust `SPIN_SPEED` (in `slot_logic.lua`), stop ticks (`newSpin`), and `topLayout` constants. Re-run `luajit test/test_slot_logic.lua` after any `slot_logic` change (Expected: PASS).

- [ ] **Step 2: Add a README section** — append to `README.md`:

```markdown
## slot — two-monitor slot machine

Files: `src/lib/subpixel.lua` + `src/slot.lua` (+ `src/slot_logic.lua`, `src/slot_symbols.lua`).

Wiring: one computer; two ADVANCED monitors on a wired modem + networking cable. Top monitor
1×2 (portrait) = reels; front monitor 1×1 = touchscreen SPIN button.

Import (each file, over HTTP):
```
pastebin get <code> subpixel     # or wget <raw-url> subpixel
pastebin get <code> slot_logic
pastebin get <code> slot_symbols
pastebin get <code> slot
```
Then `slot test` to find monitor names → edit `TOP_NAME`/`FRONT_NAME` in `slot` → run `slot`.
Tap the front monitor to spin.
```

- [ ] **Step 3: Full local test run**

Run: `luajit test/test_subpixel.lua && luajit test/test_slot_logic.lua`
Expected: both print `... passed, 0 failed`.

- [ ] **Step 4: Commit**

```bash
git add src/slot.lua src/slot_logic.lua README.md
git commit -m "polish(slot): tuning + README import/wiring notes"
```

---

## Self-Review

**Spec coverage:**
- Two advanced monitors, wired-modem names, runtime `getSize` → Tasks 7, 8, 10. ✓
- `monitor_touch` front-monitor control → Task 10. ✓
- Reusable `subpixel.lua` (setPixel/clear/fillRect/drawSprite/render, 2×3 chars 128–159, `term.blit`) → Tasks 1–3. ✓
- Skill reference doc → Task 4. ✓
- Portrait top layout: reserved block + margin + marquee + 3 reels + payline + bulb columns + banner → Task 8. ✓
- Beveled button, idle/pressed/locked, chasing border → Task 9. ✓
- Event loop: touch→spin, staggered stops, center-row win, green flash, cleanup, RNG seeded → Tasks 5, 10. ✓
- Symbols seven/cherry/bell/bar as data → Task 6. ✓
- Deferred (credits, scoreboard, paytable, sound) → not implemented, space reserved. ✓
- Verification: pure funcs via luajit + in-game test submode → Tasks 1–3, 5, 6 (local), 7–11 (in-game). ✓

**Open items carried from spec (resolve during execution):**
- Lib loading `require` vs `dofile`: plan uses `require` with `package.path`/import into same dir; if CraftOS `require` fails, fall back to `dofile("subpixel.lua")` returning `M`. Verify in Task 7 Step 3.
- Exact 128–159 mapping: encoded per Task 1; confirm glyphs look right in Task 8 in-game.
- Marquee title text: `LUCKY` placeholder in Task 8 (currently a red bar; add text overlay if desired during Task 11 polish).

**Placeholder scan:** no TBD/TODO; all code steps carry full code. ✓
**Type consistency:** `sprite = {w,h,px}` consistent across Tasks 2/6/8; `reel = {final,stopTick,offset,stopped}` consistent Tasks 5/8/10; color numbers consistent. ✓
