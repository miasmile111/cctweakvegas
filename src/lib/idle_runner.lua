-- idle_runner.lua — the shared idle lifecycle for every station. Owns rednet + deep sleep + wake +
-- the presence? query, draws the station's <name>_advert on player-leave, and runs its play() while
-- present. All lag-critical machinery lives here so a station is just a play file + an advert file.
local idle = require("idle_logic")
local PROTO = "ccvegas"

-- Open EVERY modem, never guess one. "Prefer wired" is wrong the moment a station's PERIPHERALS sit
-- on a wired cable while its only link to the hub is an ENDER modem: rednet opened the cable, the hub
-- was never on it, and the station reported "HUB OFFLINE" against a hub that was up the whole time.
-- Safe by rednet's own design: send/broadcast already transmit on every open modem, and the rednet
-- daemon de-duplicates by message ID (~9.5s), so a hub reachable on two networks is heard once.
local function openAllModems()
  local n = 0
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.hasType(name, "modem") then
      if not rednet.isOpen(name) then rednet.open(name) end
      n = n + 1
    end
  end
  return n
end

-- cfg: { name, monitor, zone?, wake={side,level}?, play=function(mon, pres)->"sleep"|"quit" }
local function run(cfg)
  local zone   = cfg.zone or "all"
  local mon    = cfg.monitor
  local advert = require(cfg.name .. "_advert")

  local hasRednet = openAllModems() > 0
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
