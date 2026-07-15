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
