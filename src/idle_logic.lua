-- idle_logic.lua — pure decision helpers for the 3-tier idle model.
-- No CC APIs: unit-testable under luajit. See docs/superpowers/specs/2026-07-16-idle-lag-model-design.md.
local M = {}

-- Is this rednet value a presence update for my zone? Returns the present boolean, or nil to ignore.
function M.presenceFor(msg, myZone)
  if type(msg) ~= "table" or msg.kind ~= "presence" then return nil end
  if msg.zone == "all" or msg.zone == myZone then
    return msg.present and true or false
  end
  return nil
end

-- Hub: broadcast only when occupancy crosses an edge (booleans coerced so nil == false).
function M.occupancyChanged(lastOcc, occ)
  return (lastOcc and true or false) ~= (occ and true or false)
end

-- Station: drop from ACTIVE to DEEP SLEEP only when the zone is empty AND we're idle in attract
-- (a spin/result always finishes first).
function M.shouldSleep(present, state)
  return (not present) and state == "attract"
end

-- Analog rising edge across a threshold (lever pull): was below, now at/above.
function M.leverRose(prev, now, threshold)
  return prev < threshold and now >= threshold
end

return M
