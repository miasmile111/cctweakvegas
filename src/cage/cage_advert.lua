-- cage_advert.lua — the cage's static idle face: METAL IN / CASH OUT in the big font, over the rate
-- table that teaches the prices while nobody's at the kiosk. Drawn ONCE by idle_runner on entering
-- deep sleep — a SINGLE STATIC FRAME, no animation, idle must cost nothing.
--
-- The signage is subpixel pixelfont @2x (short, precise, large — [[monitor-ui-workflow]]'s
-- native-vs-subpixel rule); the rate table stays NATIVE (long small print, and denser: a native row
-- is 3 subpixels tall vs 6 for a 1x pixelfont row).
--
-- BACKGROUND: the same green->gold "casino felt to money gold" gradient the player sees on the ACTIVE
-- screen (cage.lua's GRAD), so the idle face and the play face are one machine. STATIC here — one
-- phase, drawn once, then the station blocks. Safe on the shared palette: the advert only runs during
-- deep sleep, and when a player arrives cage.lua's play loop re-sets these same 4 slots every tick;
-- cage.lua redefines ONLY these 4 (everything else is stock), so the red bars / white text are
-- unaffected. Values MIRROR cage.lua's palette block — retune both together if that gradient changes.
local subpixel = require("subpixel")
local font     = require("pixelfont")
local rates    = require("cage_rates")

local M = {}

-- cell row (1-24) -> top subpixel. 1-indexed.
local function Rl(row) return (row - 1) * 3 + 1 end

-- The active screen's gradient, sampled at a single static phase. Same 4 slots, same endpoints, same
-- ramp as cage.lua's updateGradient (green -> gold).
local GRAD      = { colors.blue, colors.purple, colors.magenta, colors.cyan }
local GRAD_DEEP = { 0.00, 0.28, 0.10 }   -- deep casino-felt green
local GRAD_GOLD = { 0.62, 0.46, 0.06 }   -- money gold
local function gradientRGB(i)            -- static: phase 0
  local a = 0.5 + 0.5 * math.sin(i * 0.9)
  return GRAD_DEEP[1] + (GRAD_GOLD[1] - GRAD_DEEP[1]) * a,
         GRAD_DEEP[2] + (GRAD_GOLD[2] - GRAD_DEEP[2]) * a,
         GRAD_DEEP[3] + (GRAD_GOLD[3] - GRAD_DEEP[3]) * a
end

-- 72x72 band layout. THE CAGE title + its banner bar are GONE (owner, 2026-07-17): just the two
-- signage lines, lifted ~12% higher than before, over the gradient, framed by the top & bottom red
-- bars, with the rate table below.
local BAR1_Y,  BAR1_H  = Rl(1),  6      -- top red frame, cells 1-2
local IN_Y             = Rl(6)          -- "METAL IN" @2x -> y16-27 (was y25 — ~12% higher up)
local OUT_Y            = Rl(11)         -- "CASH OUT" @2x -> y31-42 (one blank cell-row above it)
local BAR3_Y,  BAR3_H  = Rl(23), 6      -- bottom red frame, cells 23-24
local RATE_ROW0        = 17             -- native CELL row; row i lands at RATE_ROW0 + i (cells 18-21)
local RATE_COL         = 12             -- native cell column
local CELLS_PER_BAND   = 6              -- 24 cells / 4 gradient bands

function M.draw(mon)
  -- set the 4 gradient slots to the static green->gold ramp (mirrors the active screen)
  for i = 1, #GRAD do mon.setPaletteColour(GRAD[i], gradientRGB(i)) end

  local cv = subpixel.new(mon)

  -- gradient bands across the whole canvas — same band math as cage.lua's drawCage (4 bands, 6 cell
  -- rows each, no straddle). This replaces the old flat black background.
  local bandH = math.ceil(cv.h / #GRAD)
  for b = 1, #GRAD do cv:fillRect(1, 1 + (b - 1) * bandH, cv.w, bandH, GRAD[b]) end
  cv:fillRect(1, BAR1_Y, cv.w, BAR1_H, colors.red)
  cv:fillRect(1, BAR3_Y, cv.w, BAR3_H, colors.red)

  font.drawCentered(cv, font.BIG, "METAL IN", IN_Y,  colors.white, 1, 2)
  font.drawCentered(cv, font.BIG, "CASH OUT", OUT_Y, colors.white, 1, 2)

  -- Render the subpixel layer FIRST, then lay native text over it. cv:render() blits every cell, so
  -- native text written before it is erased.
  cv:render()

  -- The rate table: one row per denomination. "%-9s%5s" keeps the "$" column aligned regardless of
  -- label/value width (cage_rates.DENOMS is the source of truth). Each row's background is set to the
  -- gradient slot of the BAND it sits in, so the cell-locked native text seams into the gradient
  -- instead of boxing on it (row 18 -> band 3, rows 19-21 -> band 4; bands are 6 cells each).
  -- CEILING: rows 18-22, bottom bar at cell row 23 -> at most FIVE denominations fit (a 6th lands on
  -- the bar); four ships with a blank row of breathing room. cage_rates.lua's CEILING has the geometry.
  mon.setTextColor(colors.white)
  for i = 1, #rates.DENOMS do
    local d = rates.DENOMS[i]
    local cellRow = RATE_ROW0 + i
    local band = math.min(math.floor((cellRow - 1) / CELLS_PER_BAND) + 1, #GRAD)
    mon.setBackgroundColor(GRAD[band])
    mon.setCursorPos(RATE_COL, cellRow)
    mon.write(("%-9s%5s"):format(d.label, "$" .. d.value))
  end
end

return M
