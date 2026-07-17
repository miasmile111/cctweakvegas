-- idle_logic.lua — pure decision helpers for the 3-tier idle model.
-- No CC APIs: unit-testable under luajit. See docs/superpowers/specs/2026-07-16-idle-lag-model-design.md.
local M = {}

-- Is this rednet value a presence update for my zone? Returns the present boolean, or nil to ignore.
-- A zone name means what it says. This deliberately does NOT special-case "all" as a wildcard:
-- an UNREGISTERED station's zone IS literally the string "all", so it still matches the hub's
-- floor-wide broadcast (no regression), while a station registered to its own computer ID stops
-- matching it. Treating "all" as a wildcard here is what made per-station zones a no-op -- a player
-- at the hub woke every station on the floor, which is the bug this whole feature exists to kill.
function M.presenceFor(msg, myZone)
  if type(msg) ~= "table" or msg.kind ~= "presence" then return nil end
  if msg.zone == myZone then
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

-- Is this rednet value a station's presence query (asking the hub for current occupancy)?
function M.isPresenceQuery(msg)
  return type(msg) == "table" and msg.kind == "presence?"
end

-- Build a presence handle for a station's active loop. `present` starts true (we entered ACTIVE
-- because someone is here); fromEvent(ev) folds a matching presence message into `present`.
function M.newPresence(zone)
  local p = { present = true }
  function p.fromEvent(ev)
    if type(ev) == "table" and ev[1] == "rednet_message" then
      local v = M.presenceFor(ev[3], zone)
      if v ~= nil then p.present = v end
    end
    return p.present
  end
  function p.gone() return not p.present end
  return p
end

return M
