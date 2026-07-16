-- cage_advert.lua — the cage's static idle face: METAL IN - CASH OUT, plus the rate table that
-- teaches the prices while nobody's at the kiosk. Drawn ONCE by idle_runner on entering deep sleep,
-- while the zone is empty. Native text only (no subpixel/pixelfont); default palette colours, no
-- animation — idle must cost nothing, so this is a single draw and return, same as slot_advert.
local rates = require("cage_rates")
local M = {}

function M.draw(mon)
  local w = mon.getSize()
  mon.setBackgroundColor(colors.black)
  mon.clear()

  local function center(text, y, fg)
    mon.setTextColor(fg)
    mon.setCursorPos(math.floor((w - #text) / 2) + 1, y)
    mon.write(text)
  end

  local function bar(y)
    mon.setBackgroundColor(colors.red)
    mon.setCursorPos(1, y)
    mon.write(string.rep(" ", w))
    mon.setBackgroundColor(colors.black)
  end

  center("THE CAGE", 5, colors.white)

  bar(8)
  bar(9)

  center("METAL IN - CASH OUT", 12, colors.white)

  -- the rate table: one row per denomination, left col 12, "%-9s%5s" is what keeps the "$" column
  -- aligned regardless of label/value width (see cage_rates.DENOMS for the source of truth).
  -- Row = 13 + i assumes <= 6 denominations (row 20 collides with the bar below) — see the CEILING
  -- note in cage_rates.lua, the one file to edit to add a metal.
  for i = 1, #rates.DENOMS do
    local d = rates.DENOMS[i]
    mon.setTextColor(colors.lightGray)
    mon.setCursorPos(12, 13 + i)
    mon.write(("%-9s%5s"):format(d.label, "$" .. d.value))
  end

  bar(20)
  bar(21)
end

return M
