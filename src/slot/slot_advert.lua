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
