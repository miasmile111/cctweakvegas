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

-- ---- scale + the $ glyphs (cage) -----------------------------------------
t.ok(F.SIGN_SM["$"] ~= nil, "SIGN_SM has a $")
t.eq(#F.SIGN_SM["$"], 10, "SIGN_SM $ is 10 rows tall")
t.eq(#F.SIGN_SM["$"][1], 5, "SIGN_SM $ is 5 px wide")
t.ok(F.SIGN_LG["$"] ~= nil, "SIGN_LG has a $")
t.eq(#F.SIGN_LG["$"], 14, "SIGN_LG $ is 14 rows tall")
t.eq(#F.SIGN_LG["$"][1], 7, "SIGN_LG $ is 7 px wide")

-- textWidth: scale multiplies glyph width, gap is NOT scaled
t.eq(F.textWidth(F.BIG, "8", 1, 1), 4, "one BIG digit @1x = 4")
t.eq(F.textWidth(F.BIG, "8", 1, 2), 8, "one BIG digit @2x = 8")
t.eq(F.textWidth(F.BIG, "88", 1, 2), 17, "two BIG digits @2x = 8+1+8")
t.eq(F.textWidth(F.BIG, "123456", 1, 2), 53, "6 digits @2x = 6*8 + 5*1 = 53")
-- the cage's balance line: SIGN_LG(7) + gap(1) + 6 digits @2x(53) = 61, fits the 72-wide canvas
t.eq(F.textWidth(F.SIGN_LG, "$", 1, 1) + 1 + F.textWidth(F.BIG, "123456", 1, 2), 61,
     "$ + 6 digits = 61 of 72 subpx")
-- default scale is 1 (back-compat with slot.lua call sites)
t.eq(F.textWidth(F.BIG, "88", 1), 9, "omitted scale = 1x")
t.eq(F.textWidth(F.WIN, "WIN:", 1), 16, "WIN: unchanged at 16")

-- drawGlyph @2x: each on-pixel becomes a 2x2 block
local cv = { w = 20, px = {} }
function cv:setPixel(x, y, c) self.px[y .. "," .. x] = c end
F.drawGlyph(cv, F.BIG, "1", 1, 1, 7, 2)
-- "1" row 1 is ".##." -> @2x cols 3,4,5,6 on rows 1,2
t.eq(cv.px["1,3"], 7, "@2x glyph fills x=3 y=1")
t.eq(cv.px["1,4"], 7, "@2x glyph fills x=4 y=1")
t.eq(cv.px["2,3"], 7, "@2x glyph doubles vertically (y=2)")
t.eq(cv.px["1,1"], nil, "@2x leaves off-pixels clear")

-- drawCentered @2x centers on the SCALED width
local cv2 = { w = 20, px = {} }
function cv2:setPixel(x, y, c) self.px[y .. "," .. x] = c end
F.drawCentered(cv2, F.BIG, "8", 1, 7, 1, 2)
-- scaled width 8 -> x = floor((20-8)/2)+1 = 7
t.eq(cv2.px["1,7"], 7, "@2x centered starts at x=7")

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

t.done()
