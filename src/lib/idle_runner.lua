-- idle_runner.lua — the shared idle lifecycle for every station. Owns rednet + deep sleep + wake +
-- the presence? query, draws the station's <name>_advert on player-leave, and runs its play() while
-- present. All lag-critical machinery lives here so a station is just a play file + an advert file.
local idle = require("idle_logic")
local prox  = require("proximity")
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

-- Where am I? gps.locate first, so a floor of hundreds of stations never needs hand-typed
-- coordinates; `pos=x,y,z` in the station's .cfg is the escape hatch and the answer before the GPS
-- constellation exists. Neither -> we simply do not register, and stay on the legacy "all" zone.
--
-- gps.locate needs a WIRELESS MODEM ON A SIDE OF THE COMPUTER -- it scans rs.getSides() only, never
-- the cable (spec fact 8). Mounting the ender modem on a wired network (if that even works) would
-- silently kill GPS here. Keep it on a side.
--
-- The constellation must be 3 hosts + a 4th LIFTED OFF THEIR PLANE; four coplanar hosts cannot
-- resolve trilateration's mirror and gps.locate just returns nil (spec fact 9,
-- test/spikes/gps_constellation.lua). One force-loaded chunk is plenty -- CC's GPS distances are
-- exact, so horizontal spread buys nothing.
local function resolvePos(cfg)
  local fromCfg = prox.parsePos(cfg.pos)
  if fromCfg then return fromCfg, "cfg" end
  if gps then
    local x, y, z = gps.locate(2)
    if x then return { x = x, y = y, z = z }, "gps" end
  end
  return nil, "none"
end

-- Tell the hub where we are. Best-effort and non-fatal: a station whose hub is down still plays
-- (its lever wakes it), it just will not get proximity until the hub hears from it again.
-- Returns true only if the hub ACKED -- an OLD hub silently ignores station_pos and would otherwise
-- look identical to success (see todo.md's `hub_version` follow-up).
--
-- Note on the event loop below: this runs once at boot, before deepSleep, so there is no caller loop
-- whose timer it could swallow -- unlike wallet.request, it needs no stash/re-queue
-- ([[event-pump-reentrancy]]). Do not copy this pattern into a hot path.
local function registerPos(pos, cfg)
  local hub = rednet.lookup(PROTO, "hub")
  if not hub then return false end
  rednet.send(hub, {
    kind = "station_pos", computerID = os.getComputerID(), pos = pos,
    dim = cfg.dim, range = cfg.range, label = os.getComputerLabel(),
  }, PROTO)
  local timer = os.startTimer(2)
  while true do
    local ev = { os.pullEvent() }
    if ev[1] == "rednet_message" and type(ev[3]) == "table"
       and ev[3].kind == "station_pos_ok" then
      return true
    elseif ev[1] == "timer" and ev[2] == timer then
      return false
    end
  end
end

-- cfg: { name, monitor, zone?, pos?, dim?, range?, wake={side,level}?, play=function(mon, pres)->"sleep"|"quit" }
local function run(cfg)
  local mon    = cfg.monitor
  local advert = require(cfg.name .. "_advert")

  local hasRednet = openAllModems() > 0

  -- Sample the lever BEFORE resolvePos/registerPos below, not after: gps.locate blocks its full
  -- timeout on every boot while this server has no GPS constellation, via a bare os.pullEvent loop
  -- that silently swallows any redstone event that arrives during that wait (CC:Tweaked's
  -- rom/apis/gps.lua). A lever pulled in that window must not be lost -- capturing wakeLvl here,
  -- ahead of the blocking calls, means deepSleep can re-check the CURRENT reading against it and
  -- catch the pull regardless of whether the event survived. Do not move this back down into
  -- deepSleep -- that's the bug this fixes.
  local wakeLvl = cfg.wake and redstone.getAnalogInput(cfg.wake.side) or 0

  -- Zone resolution. cfg.zone pins it (legacy stations, or two computers sharing one zone).
  -- Otherwise: our own computer ID if the hub knows where we are, else the floor-wide "all".
  -- The registrar already keys everything by the immutable os.getComputerID(), so reusing it as the
  -- zone costs no new names, cannot collide, and lets the hub rednet.send straight to us --
  -- rednet addresses BY computer ID, so per-station presence needs no broadcast at all.
  local zone = cfg.zone
  if not zone then
    zone = "all"
    if hasRednet then
      local pos, src = resolvePos(cfg)
      if pos and registerPos(pos, cfg) then
        zone = os.getComputerID()
        print(("[zone] #%d at %d,%d,%d (%s)"):format(zone, pos.x, pos.y, pos.z, src))
      elseif pos then
        print("[zone] hub did not ack station_pos (offline, or too old) -> zone 'all'")
      else
        print("[zone] no position (no GPS fix, no pos= in cfg) -> zone 'all'")
      end
    end
  end
  local function queryPresence()
    if hasRednet then rednet.broadcast({ kind = "presence?", zone = zone }, PROTO) end
  end

  -- DEEP SLEEP: draw the advert once, then block (no timer). Returns "wake" or "quit".
  local function deepSleep()
    advert.draw(mon)
    queryPresence()                       -- if a player is already here, the hub's reply wakes us
    -- Re-check against wakeLvl (the baseline sampled up in run(), before resolvePos/registerPos)
    -- instead of resampling fresh here: pull, don't trust push -- same reasoning as queryPresence()
    -- re-asking the hub rather than relying on a broadcast that may have been missed. This is what
    -- makes a redstone event swallowed by gps.locate's boot-time pullEvent loop irrelevant.
    local lvl = cfg.wake and redstone.getAnalogInput(cfg.wake.side) or 0
    local rose = cfg.wake and idle.leverRose(wakeLvl, lvl, cfg.wake.level)
    wakeLvl = lvl
    if rose then return "wake" end
    while true do
      local ev = { os.pullEvent() }
      if ev[1] == "rednet_message" then
        if idle.presenceFor(ev[3], zone) == true then return "wake" end
      elseif ev[1] == "redstone" and cfg.wake then
        local l = redstone.getAnalogInput(cfg.wake.side)
        if idle.leverRose(wakeLvl, l, cfg.wake.level) then
          wakeLvl = l
          return "wake"
        end
        wakeLvl = l
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
