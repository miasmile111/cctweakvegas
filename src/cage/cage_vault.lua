-- cage_vault.lua — the cage's item math: what a chest of metal is worth, and how items are
-- spread across the droppers and flung out one pulse at a time. PURE (no CC globals) so it
-- unit-tests under luajit; every peripheral call lives in cage_hw.lua.
--
-- Dropper model: all droppers sit on ONE redstone line, so a single pulse fires all of them at
-- once and every non-empty dropper ejects exactly one item. `loads` is a per-dropper count of
-- items still to fling; the shower is that table draining one pulse per tick.
local M = {}

-- Value a deposit chest listing. Returns total $, the stacks worth moving to the vault (sorted by
-- slot), and how many stacks were ignored. Unknown items are valued at 0 and NEVER moved — a
-- player's tools stay exactly where they left them.
function M.valueListing(list, rates)
  local total, moves, ignored = 0, {}, 0
  local slots = {}
  for slot in pairs(list) do slots[#slots + 1] = slot end
  table.sort(slots)                       -- deterministic order: tests and review depend on it
  for i = 1, #slots do
    local slot = slots[i]
    local it = list[slot]
    local d = rates.byItem(it.name)
    if d then
      total = total + d.value * it.count
      moves[#moves + 1] = { slot = slot, count = it.count }
    else
      ignored = ignored + 1
    end
  end
  return total, moves, ignored
end

-- total count of `item` across every slot of a listing
function M.countItem(list, item)
  local n = 0
  for _, it in pairs(list) do
    if it.name == item then n = n + it.count end
  end
  return n
end

-- spread `count` items round-robin across the droppers, starting at `nextIdx`. Mutates and returns
-- `loads` plus the index to start the NEXT tap from — so spam-tapping keeps the rotation even
-- instead of always reloading dropper 1.
function M.addLoad(loads, count, nextIdx)
  local n = #loads
  local i = nextIdx
  for _ = 1, count do
    loads[i] = loads[i] + 1
    i = i % n + 1
  end
  return loads, i
end

-- one redstone pulse: every non-empty dropper ejects exactly one item.
function M.pulseLoads(loads)
  local ejected = 0
  for i = 1, #loads do
    if loads[i] > 0 then
      loads[i] = loads[i] - 1
      ejected = ejected + 1
    end
  end
  return loads, ejected
end

function M.anyLoaded(loads)
  for i = 1, #loads do
    if loads[i] > 0 then return true end
  end
  return false
end

return M
