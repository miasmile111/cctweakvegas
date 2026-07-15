-- slot.lua — diegetic slot machine on two CC:Tweaked advanced monitors.
--   Top monitor (1x2 portrait) shows the reels; front monitor (1x1) is the touch SPIN button.
--   Run:  slot          -> play (tap the front monitor to spin)
--   Run:  slot test     -> list monitors + sizes, echo touch coords (to fill config below)
--
-- Wiring: put BOTH advanced monitors on a wired modem + networking cable so they don't use up
-- computer sides. Run `slot test`, note each monitor's network name + which one is front/top,
-- then set TOP_NAME / FRONT_NAME below. Re-host + re-import after editing (HTTP snapshot).

-- ---- config ----------------------------------------------------------------
local TOP_NAME   = "monitor_0"   -- 1x2 portrait play monitor (network name)
local FRONT_NAME = "monitor_1"   -- 1x1 touch button monitor
local TOP_SCALE  = 0.5
local FRONT_SCALE = 0.5
-- ----------------------------------------------------------------------------

local args = { ... }

local function findMon(name)
  local m = peripheral.wrap(name)
  if not m or peripheral.getType(name) ~= "monitor" then
    error(("Monitor '%s' not found. Run `slot test` to list names, then edit config."):format(name), 0)
  end
  return m
end

local function testMode()
  print("Attached monitors:")
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "monitor" then
      local m = peripheral.wrap(name)
      m.setTextScale(0.5)
      local w, h = m.getSize()
      print(("  %s  ->  %d x %d  @0.5"):format(name, w, h))
    end
  end
  print("Tap a monitor (Q to quit). Coords print below:")
  while true do
    local ev = { os.pullEvent() }
    if ev[1] == "monitor_touch" then
      print(("touch: %s  x=%d y=%d"):format(ev[2], ev[3], ev[4]))
    elseif ev[1] == "key" and ev[2] == keys.q then
      return
    end
  end
end

if args[1] == "test" then
  testMode()
  print("Test mode done.")
  return
end

-- (play mode wired up in later tasks)
print("slot: play mode not yet implemented — run `slot test` for now.")
