-- controls.lua — logical input names -> a redstone source. The station's diegetic input layer.
--
--   local ctl = controls.new{ cfg = CFG, inputs = { "p1_up", "p1_down", "p2_up", "p2_down" } }
--   if ctl.get("p1_up") then ... end
--
-- WHY THIS EXISTS: pong's plates moved from the computer's own sides onto a REDSTONE RELAY, and
-- `redstone.getInput(side)` reads the computer, which now never changes state. A relay is a
-- peripheral whose methods are NAME-IDENTICAL to the built-in redstone API (verified: tweaked.cc,
-- peripheral type `redstone_relay`, CC:Tweaked 1.114.0+), so a "source" is simply either the global
-- `redstone` table or `peripheral.wrap(name)` -- duck-type identical, which is what makes this
-- abstraction nearly free.
--
-- WIRING LIVES IN THE STATION'S .cfg, NEVER HERE. CC does not hand identically-built stations
-- identical peripheral names, so `source = relay` discovers the relay BY TYPE and an explicit name
-- in cfg always wins. Nothing in a station file may hardcode a peripheral name.
--
--   source  = relay        # or a peripheral name, or "computer" (the default)
--   p1_up   = left
--   p1_down = front
--
-- Every failure here is LOUD. A miswired station must stop at boot naming what it could not find --
-- a paddle that silently reads "not pressed" forever is the worst possible failure for a game.
local M = {}

local RELAY_TYPE = "redstone_relay"
local SIDES = { top = true, bottom = true, left = true, right = true, front = true, back = true }

-- cfg.cfg     = the parsed station .cfg table (source + one line per logical input)
-- cfg.inputs  = the logical names this station REQUIRES; every one must be mapped
-- cfg.deps    = { peripheral =, redstone = } test injection only; production omits it
function M.new(cfg)
  cfg = cfg or {}
  local conf   = cfg.cfg or {}
  local deps   = cfg.deps or {}
  local per    = deps.peripheral or peripheral
  local rsApi  = deps.redstone or redstone
  local wanted = cfg.inputs or {}

  local sourceCfg = conf.source or "computer"
  local src, srcName

  if sourceCfg == "computer" then
    src, srcName = rsApi, "computer"
  elseif sourceCfg == "relay" then
    for _, name in ipairs(per.getNames()) do
      if per.hasType(name, RELAY_TYPE) then
        src, srcName = per.wrap(name), name
        break
      end
    end
    if not src then
      error("controls: source=relay but no " .. RELAY_TYPE .. " peripheral is attached", 0)
    end
  else
    src, srcName = per.wrap(sourceCfg), sourceCfg
    if not src then
      error("controls: no peripheral named '" .. tostring(sourceCfg) .. "'", 0)
    end
  end

  local map = {}
  for _, name in ipairs(wanted) do
    local side = conf[name]
    if not side then
      error("controls: input '" .. name .. "' has no line in the station .cfg", 0)
    end
    if not SIDES[side] then
      error("controls: input '" .. name .. "' = '" .. tostring(side) .. "' is not a side "
            .. "(top/bottom/left/right/front/back)", 0)
    end
    map[name] = side
  end

  local self = {}

  function self.get(name)
    local side = map[name]
    if not side then
      error("controls: unknown input '" .. tostring(name) .. "'", 0)
    end
    return src.getInput(side) and true or false
  end

  function self.sideOf(name) return map[name] end
  function self.sourceName() return srcName end

  return self
end

return M
