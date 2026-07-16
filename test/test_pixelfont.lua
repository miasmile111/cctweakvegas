package.path = "src/lib/?.lua;test/?.lua;" .. package.path
local t = require("runner")
local F = require("pixelfont")

-- a tiny recording canvas (mirrors the subpixel canvas contract: setPixel(x,y,color))
local function mockCanvas(w, h)
  local cv = { w = w, h = h, px = {}, n = 0 }
  function cv:setPixel(x, y, color)
    if x < 1 or y < 1 or x > self.w or y > self.h then return end
    self.px[y * 1000 + x] = color; self.n = self.n + 1
  end
  return cv
end

-- widths (variable-width WIN: label): W5 + I3 + N4 + colon1, 1px gaps between = 16
t.eq(F.textWidth(F.WIN, "WIN:", 1), 5 + 1 + 3 + 1 + 4 + 1 + 1, "WIN: width = 16")
-- big digits are 4 wide, gap 1
t.eq(F.textWidth(F.BIG, "0", 1), 4, "one big digit = 4 wide")
t.eq(F.textWidth(F.BIG, "250", 1), 4 + 1 + 4 + 1 + 4, "big '250' = 14 wide")
t.eq(F.textWidth(F.BIG, "2500", 1), 4 * 4 + 3, "big '2500' (jackpot) = 19 wide (fits 30)")

-- drawGlyph lights exactly the '#' pixels of the "0" glyph (18 of them)
do
  local cv = mockCanvas(30, 72)
  F.drawGlyph(cv, F.BIG, "0", 1, 1, 1)
  t.eq(cv.n, 18, "big '0' lights 18 subpixels")
  t.eq(cv.px[1 * 1000 + 1], 1, "top-left pixel of '0' is on")
end

-- drawText advances by glyph width + gap (second digit starts 5px right of the first)
do
  local cv = mockCanvas(30, 72)
  F.drawText(cv, F.BIG, "11", 1, 1, 7, 1)   -- "1" glyph, then gap 1, then "1" at x=6
  t.eq(cv.px[1 * 1000 + 3], 7, "first '1' stem at x=3")   -- '1' is ".##." so col 2-3 on row1
  t.eq(cv.px[1 * 1000 + 8], 7, "second '1' stem at x=8 (advanced 5)")
end

-- drawCentered centers on cv.w: "0" (4 wide) on a 30-wide canvas starts at floor((30-4)/2)+1 = 14
do
  local cv = mockCanvas(30, 72)
  F.drawCentered(cv, F.BIG, "0", 1, 1, 1)
  t.eq(cv.px[1 * 1000 + 14], 1, "centered '0' top-left at x=14")
end

t.done()
