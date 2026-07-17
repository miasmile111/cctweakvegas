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
local OUT_Y            = Rl(14)         -- "CASH OUT" @2x -> y 40-51 (one blank cell-row above it, so
                                        -- it doesn't merge with METAL IN; still clears the rate table)
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
  -- CEILING: rows 18-22, with the bottom bar at cell row 23 -> at most FIVE denominations fit (a 6th
  -- lands on the bar); four ships with a blank row of breathing room. This is TIGHTER than the old
  -- layout's six, the price of the 2x signage above. cage_rates.lua's CEILING has the exact geometry.
  mon.setBackgroundColor(colors.black)
  mon.setTextColor(colors.lightGray)
  for i = 1, #rates.DENOMS do
    local d = rates.DENOMS[i]
    mon.setCursorPos(RATE_COL, RATE_ROW0 + i)
    mon.write(("%-9s%5s"):format(d.label, "$" .. d.value))
  end
end

return M
