-- cage_rates.lua — the cage's denomination table + qty ladder. Data + lookups, nothing else:
-- this is the ONE file to edit to reprice the floor or add a metal (the slot_pay idiom).
-- Rates are FLAT and symmetric: a deposit and a withdrawal of the same item move the same $.
-- Pure (no CC globals) so it unit-tests under luajit.
-- CEILING: cage_advert.lua's idle rate table places row i at `13 + i` and the bottom red bar
-- starts at row 20 — so a 7th DENOMS entry (row 20) would collide with the bar. #DENOMS <= 6.
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
