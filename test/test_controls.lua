-- test_controls.lua — logical input names -> a redstone source (relay peripheral or computer sides).
--
-- The rule this file defends: NO peripheral name is ever hardcoded in a station. CC does not hand
-- identically-built stations identical peripheral names, so wiring lives in the station's .cfg and
-- discovery is BY TYPE. An explicit name in cfg always wins over discovery.
package.path = "src/lib/?.lua;test/?.lua;" .. package.path
local t = require("runner")
local controls = require("controls")

-- ---- fakes -----------------------------------------------------------------
local function fakeRedstone(levels)
  return { getInput = function(side) return levels[side] == true end }
end

-- names = ordered peripheral names; types = name -> type string; levels = name -> {side->bool}
local function fakePeripheral(names, types, levels)
  return {
    getNames = function() return names end,
    hasType  = function(n, ty) return types[n] == ty end,
    wrap     = function(n)
      if not types[n] then return nil end
      return { getInput = function(side) return (levels[n] or {})[side] == true end }
    end,
  }
end

local INPUTS = { "p1_up", "p1_down", "p2_up", "p2_down" }
local WIRING = { p1_up = "left", p1_down = "front", p2_up = "right", p2_down = "back" }

local function cfgWith(extra)
  local c = {}
  for k, v in pairs(WIRING) do c[k] = v end
  for k, v in pairs(extra or {}) do c[k] = v end
  return c
end

-- ---- source = computer ----
do
  local rs = fakeRedstone{ left = true, back = true }
  local ctl = controls.new{
    cfg = cfgWith{ source = "computer" }, inputs = INPUTS,
    deps = { redstone = rs, peripheral = fakePeripheral({}, {}, {}) },
  }
  t.eq(ctl.get("p1_up"), true, "computer source reads the built-in redstone table")
  t.eq(ctl.get("p1_down"), false, "an unpowered side reads false")
  t.eq(ctl.get("p2_down"), true, "back is powered")
  t.eq(ctl.sourceName(), "computer", "sourceName reports the computer")
end

-- ---- source omitted defaults to computer (a station with no relay must still work) ----
do
  local rs = fakeRedstone{ left = true }
  local ctl = controls.new{
    cfg = cfgWith{}, inputs = INPUTS,
    deps = { redstone = rs, peripheral = fakePeripheral({}, {}, {}) },
  }
  t.eq(ctl.sourceName(), "computer", "no source= in cfg defaults to the computer's own sides")
  t.eq(ctl.get("p1_up"), true, "and it reads")
end

-- ---- source = relay: discovered BY TYPE, not by name ----
do
  local per = fakePeripheral(
    { "monitor_0", "drive_1", "redstone_relay_3" },
    { monitor_0 = "monitor", drive_1 = "drive", redstone_relay_3 = "redstone_relay" },
    { redstone_relay_3 = { left = true } })
  local ctl = controls.new{
    cfg = cfgWith{ source = "relay" }, inputs = INPUTS,
    deps = { redstone = fakeRedstone{}, peripheral = per },
  }
  t.eq(ctl.sourceName(), "redstone_relay_3", "relay is discovered by TYPE -- the index is not 0")
  t.eq(ctl.get("p1_up"), true, "reads through the discovered relay")
  t.eq(ctl.get("p2_up"), false, "an unpowered relay side reads false")
end

-- ---- an explicit peripheral name WINS over discovery ----
do
  local per = fakePeripheral(
    { "redstone_relay_0", "redstone_relay_1" },
    { redstone_relay_0 = "redstone_relay", redstone_relay_1 = "redstone_relay" },
    { redstone_relay_0 = {}, redstone_relay_1 = { left = true } })
  local ctl = controls.new{
    cfg = cfgWith{ source = "redstone_relay_1" }, inputs = INPUTS,
    deps = { redstone = fakeRedstone{}, peripheral = per },
  }
  t.eq(ctl.sourceName(), "redstone_relay_1", "a named source is used verbatim")
  t.eq(ctl.get("p1_up"), true, "and it is the named one, not the first discovered")
end

-- ---- FAIL LOUD: a missing relay is a hard stop, never a silently dead paddle ----
do
  local per = fakePeripheral({ "monitor_0" }, { monitor_0 = "monitor" }, {})
  local ok, err = pcall(function()
    controls.new{ cfg = cfgWith{ source = "relay" }, inputs = INPUTS,
                  deps = { redstone = fakeRedstone{}, peripheral = per } }
  end)
  t.eq(ok, false, "source=relay with no relay attached errors")
  t.ok(tostring(err):find("redstone_relay"), "and the error names what it looked for")
end

do
  local per = fakePeripheral({}, {}, {})
  local ok, err = pcall(function()
    controls.new{ cfg = cfgWith{ source = "nope_0" }, inputs = INPUTS,
                  deps = { redstone = fakeRedstone{}, peripheral = per } }
  end)
  t.eq(ok, false, "a named source that is not attached errors")
  t.ok(tostring(err):find("nope_0"), "and the error names it")
end

-- ---- FAIL LOUD: an unmapped or nonsense input is a hard stop ----
do
  local ok, err = pcall(function()
    controls.new{ cfg = { source = "computer", p1_up = "left" }, inputs = INPUTS,
                  deps = { redstone = fakeRedstone{}, peripheral = fakePeripheral({}, {}, {}) } }
  end)
  t.eq(ok, false, "an input with no cfg line errors")
  t.ok(tostring(err):find("p1_down"), "and the error names the MISSING logical input")
end

do
  local ok, err = pcall(function()
    controls.new{ cfg = cfgWith{ p2_up = "sideways" }, inputs = INPUTS,
                  deps = { redstone = fakeRedstone{}, peripheral = fakePeripheral({}, {}, {}) } }
  end)
  t.eq(ok, false, "a non-side value errors")
  t.ok(tostring(err):find("sideways"), "and the error quotes the bad value")
end

-- ---- get() on an unknown name errors rather than silently reading false ----
do
  local ctl = controls.new{
    cfg = cfgWith{ source = "computer" }, inputs = INPUTS,
    deps = { redstone = fakeRedstone{}, peripheral = fakePeripheral({}, {}, {}) },
  }
  t.eq(ctl.sideOf("p1_up"), "left", "sideOf exposes the resolved wiring for diagnostics")
  local ok = pcall(function() return ctl.get("p3_up") end)
  t.eq(ok, false, "get() on an unconfigured name errors -- a typo must not read as 'not pressed'")
end

-- ---- rawGet / sides: the commissioning path, which must work with NO mapping ----
-- `pong test` cannot require a complete cfg: you cannot map a plate to a logical name until you
-- have watched which side it lights up. So controls must construct with zero required inputs and
-- still read raw sides.
do
  local rs = fakeRedstone{ left = true, back = true }
  local ctl = controls.new{
    cfg = { source = "computer" }, inputs = {},
    deps = { redstone = rs, peripheral = fakePeripheral({}, {}, {}) },
  }
  t.eq(ctl.rawGet("left"), true, "a powered side reads true with no logical mapping configured")
  t.eq(ctl.rawGet("right"), false, "an unpowered side reads false")
  t.eq(#ctl.sides(), 6, "sides() lists all six")
  t.eq(ctl.sides()[1], "top", "in a stable order")
end

do
  -- The point of the empty-inputs construction: it must NOT error the way a normal boot does.
  local ok = pcall(function()
    controls.new{ cfg = { source = "computer" }, inputs = {},
                  deps = { redstone = fakeRedstone{}, peripheral = fakePeripheral({}, {}, {}) } }
  end)
  t.eq(ok, true, "an empty inputs list validates nothing -- this is what lets `pong test` run bare")
end

t.done()
