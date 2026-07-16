-- idle_runner.lua — the shared idle lifecycle for every station. Owns rednet + deep sleep + wake +
-- the presence? query, draws the station's <name>_advert on player-leave, and runs its play() while
-- present. All lag-critical machinery lives here so a station is just a play file + an advert file.
local idle = require("idle_logic")
local PROTO = "ccvegas"

local function findModem()
  local wired = peripheral.find("modem", function(_, m) return not m.isWireless() end)
  return wired or peripheral.find("modem")
end

-- cfg: { name, monitor, zone?, wake={side,level}?, play=function(mon, pres)->"sleep"|"quit" }
local function run(cfg)
  local zone   = cfg.zone or "all"
  local mon    = cfg.monitor
  local advert = require(cfg.name .. "_advert")

  local hasRednet = false
  do local m = findModem(); if m then rednet.open(peripheral.getName(m)); hasRednet = true end end
  local function queryPresence()
    if hasRednet then rednet.broadcast({ kind = "presence?", zone = zone }, PROTO) end
  end

  -- DEEP SLEEP: draw the advert once, then block (no timer). Returns "wake" or "quit".
  local function deepSleep()
    advert.draw(mon)
    queryPresence()                       -- if a player is already here, the hub's reply wakes us
    local prevLvl = cfg.wake and redstone.getAnalogInput(cfg.wake.side) or 0
    while true do
      local ev = { os.pullEvent() }
      if ev[1] == "rednet_message" then
        if idle.presenceFor(ev[3], zone) == true then return "wake" end
      elseif ev[1] == "redstone" and cfg.wake then
        local lvl = redstone.getAnalogInput(cfg.wake.side)
        if idle.leverRose(prevLvl, lvl, cfg.wake.level) then return "wake" end
        prevLvl = lvl
      elseif ev[1] == "key" and ev[2] == keys.q then
        return "quit"
      end
    end
  end

  while true do
    if deepSleep() == "quit" then break end
    local pres = idle.newPresence(zone)
    queryPresence()                       -- sync real presence on active entry
    if cfg.play(mon, pres) == "quit" then break end
    -- "sleep" -> loop back to deepSleep (redraws the advert)
  end

  mon.setBackgroundColor(colors.black); mon.clear(); mon.setCursorPos(1, 1); mon.setTextScale(1)
end

return { run = run }
