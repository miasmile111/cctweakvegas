-- cage_rates.lua — the cage's denomination table + qty ladder. Data + lookups, nothing else:
-- this is the ONE file to edit to reprice the floor or add a metal (the slot_pay idiom).
-- Rates are FLAT and symmetric: a deposit and a withdrawal of the same item move the same $.
-- Pure (no CC globals) so it unit-tests under luajit.
-- CEILING: at most FIVE denominations (a 6th lands on the bar at cell row 23). The rate table draws
-- at native cell rows 18-22 (RATE_ROW0 = 17, row i -> 17 + i). A 5th entry fits at row 22 but sits
-- directly against the bar with no blank row; four ships and is designed around, maintaining that
-- breathing room. This is tighter than the old six-entry ceiling, the deliberate price of the 2x
-- pixelfont signage above (2026-07-17). To add a metal, re-lay out cage_advert's bands first -- this
-- file is still the one place to edit the rates themselves.
local M = {}

-- ordered cheapest -> dearest; the UI renders them left to right in this order.
M.DENOMS = {
  { key = "copper",  item = "minecraft:copper_ingot", value = 25,   label = "COPPER"  },
  { key = "iron",    item = "minecraft:iron_ingot",   value = 100,  label = "IRON"    },
  { key = "gold",    item = "minecraft:gold_ingot",   value = 250,  label = "GOLD"    },
  { key = "diamond", item = "minecraft:diamond",      value = 1000, label = "DIAMOND" },
}

-- how many of a metal one tap withdraws. Default 1x; resets to 1x on wake.
M.QTYS = { 1, 5, 20 }

function M.byItem(item)
  for i = 1, #M.DENOMS do
    if M.DENOMS[i].item == item then return M.DENOMS[i] end
  end
  return nil
end

function M.byKey(key)
  for i = 1, #M.DENOMS do
    if M.DENOMS[i].key == key then return M.DENOMS[i] end
  end
  return nil
end

return M
