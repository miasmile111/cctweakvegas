-- proximity.lua — pure zone math for per-station presence. No CC APIs: unit-testable under luajit.
--
-- The hub asks the player detector WHO is online and WHERE each player is -- that is O(players) --
-- and then everything below is free Lua, however many stations the floor grows to. See
-- docs/superpowers/specs/2026-07-17-per-station-proximity-design.md.
--
-- A zone is an axis-aligned BOX around the station: `range` in x/z, `yRange` in y. This is OUR
-- shape, not Advanced Peripherals' -- AP's own ranges are Chebyshev squares in x/z with a quirky
-- feet/eye y rule (spec fact 5), which we never inherit because we never ask AP to do the matching.
local M = {}

-- Owner-set 2026-07-17, after the first constellation went live. A BOX, so range 10 is a 21x21
-- column, not a circle -- stations closer than ~20 blocks apart will both wake for one player. That
-- is fine and costs nothing (matching is pure Lua; only the rednet EDGE is sent), and on a casino
-- floor it is arguably right: walk down a row and the row lights up.
M.DEFAULT_RANGE  = 10  -- blocks in x/z: a 21x21 column. Walk-up distance, not "somewhere in the room".
M.DEFAULT_YRANGE = 3   -- blocks in y: deliberately NOT widened with range -- it is what stops the
                       -- floor above (or below) from waking a station you are nowhere near.

-- Accept a cfg `pos=x,y,z` string (or an already-good table) -> {x,y,z} | nil.
function M.parsePos(v)
  if type(v) == "table" then
    if type(v.x) == "number" and type(v.y) == "number" and type(v.z) == "number" then return v end
    return nil
  end
  if type(v) ~= "string" then return nil end
  local x, y, z = v:match("^%s*(-?%d+%.?%d*)%s*,%s*(-?%d+%.?%d*)%s*,%s*(-?%d+%.?%d*)%s*$")
  if not x then return nil end
  return { x = tonumber(x), y = tonumber(y), z = tonumber(z) }
end

-- Is this player inside this station's box? `p` is a getPlayerPos return.
function M.near(station, p, defaultDim)
  if type(station) ~= "table" or type(p) ~= "table" then return false end
  local sp = station.pos
  if type(sp) ~= "table" then return false end
  if type(p.x) ~= "number" or type(p.y) ~= "number" or type(p.z) ~= "number" then return false end

  -- getPlayerPos does NOT filter by dimension (spec fact 4): at playerDetMaxRange = -1 with
  -- playerDetMultiDimensional on, it happily returns a player standing in the Nether. So a station
  -- at the same x/z would wake for them. This line is the only thing stopping that.
  -- If the field is missing entirely (morePlayerInformation = false) we CANNOT filter -- be
  -- permissive: a rare false wake is cosmetic, a floor that never wakes is a brick. `hub test pos`
  -- reports the missing field so it gets fixed at the server, not papered over here.
  local dim = station.dim or defaultDim
  if dim and p.dimension and dim ~= p.dimension then return false end

  local r  = station.range  or M.DEFAULT_RANGE
  local yr = station.yRange or M.DEFAULT_YRANGE
  return math.abs(p.x - sp.x) <= r
     and math.abs(p.z - sp.z) <= r
     and math.abs(p.y - sp.y) <= yr
end

-- stations: computerID -> {pos, dim?, range?, yRange?}. positions: playerName -> getPlayerPos return.
-- -> computerID -> boolean. O(stations x players) of pure Lua, and ZERO peripheral calls.
function M.evaluate(stations, positions, defaultDim)
  local out = {}
  for id, station in pairs(stations or {}) do
    local present = false
    for _, p in pairs(positions or {}) do
      if M.near(station, p, defaultDim) then present = true; break end
    end
    out[id] = present
  end
  return out
end

-- Only what CHANGED. The hub sends one addressed message per edge, so a floor where nobody moves
-- is a floor with no rednet traffic at all -- the same edge-only contract idle_logic.occupancyChanged
-- gives the legacy "all" zone.
function M.edges(prev, now)
  prev, now = prev or {}, now or {}
  local out = {}
  for id, present in pairs(now) do
    if (prev[id] and true or false) ~= (present and true or false) then
      out[#out + 1] = { id = id, present = present and true or false }
    end
  end
  -- Deregistered (or forgotten) while present: it is still awake and nothing else will ever tell it
  -- to sleep. Say so once.
  for id, was in pairs(prev) do
    if was and now[id] == nil then out[#out + 1] = { id = id, present = false } end
  end
  table.sort(out, function(a, b) return a.id < b.id end)   -- deterministic: stable tests, stable logs
  return out
end

return M
