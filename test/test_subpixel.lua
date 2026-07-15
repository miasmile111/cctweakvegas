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

t.done()
