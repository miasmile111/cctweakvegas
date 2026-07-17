-- hub.lua — Hub v0: the station registrar. First brick of the hub-authoritative base.
--
-- Assigns each station a unique, persistent instance number (slot -> slot1, slot2, ...),
-- keyed by the computer's immutable os.getComputerID(), so re-running `update` never
-- renumbers or collides. The assignment table is persisted to disk.
--
-- Setup: computer + WIRED MODEM (on a network cable). Run `hub`. Keep it in a
-- FORCE-LOADED chunk — the hub is the one part of the base that must always be online.
-- (This is the deliberate exception to "idle = asleep": it's infrastructure.)
--
-- This service also owns the score economy: a persisted id->score ledger with bet/credit/query/mint
-- handlers (see the registrar loop below) and the mint tool `issue`. See the hub-economy spec.

local PROTO = "ccvegas"
local STORE = "registry.tbl"
local DET_RANGE = 8      -- blocks: how near a player must be for the hub to wake stations (v1: one range)
local POLL      = 0.3    -- seconds between detector polls (the hub's one forever-loop)
local idle      = require("idle_logic")
local prox      = require("proximity")
local DIM       = "minecraft:overworld"   -- stations are assumed here unless they say otherwise.
                                          -- There is no CC API for "what dimension am I in", so this
                                          -- is config -- but a station that GPS-located itself has
                                          -- already proved it shares the constellation's dimension
                                          -- (spec fact 7).
local args      = { ... }

-- Open EVERY modem, never guess one. THE HUB ESPECIALLY: it is the one machine every station must
-- reach, and the floor is not one network — a cabled station talks over the wire while a distant one
-- can only reach the hub by ENDER modem. "Prefer wired" made the hub listen on the cable alone and
-- go deaf to every wireless station, which they report as "HUB OFFLINE" while the hub sits there
-- running. Safe by rednet's design: send/broadcast transmit on all open modems and the rednet daemon
-- de-duplicates by message ID (~9.5s), so a station reachable two ways is still heard once.
local function openAllModems()
  local names = {}
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.hasType(name, "modem") then
      if not rednet.isOpen(name) then rednet.open(name) end
      names[#names + 1] = name
    end
  end
  return names
end

local modems = openAllModems()
if #modems == 0 then
  print("===========================")
  print(" HUB needs a MODEM to run!")
  print("===========================")
  print("Attach a modem, then re-run `hub`. Wired reaches cabled stations; add an ENDER modem")
  print("too if any station is off the cable network — the hub now listens on ALL of them.")
  return
end

rednet.host(PROTO, "hub")
print(("Rednet open on %d modem(s): %s"):format(#modems, table.concat(modems, ", ")))

-- `hub test pos` — THE SPIKE. Per-station proximity reads player POSITIONS, and three Advanced
-- Peripherals config values can each silently break that. All three default in our favour, but
-- pre-1.21 AP defaulted playerDetMaxRange to 100 (it is -1 now), so nothing here is assumed.
-- Run this ONCE standing at the hub and ONCE from a station ~1000 blocks out — a capped range looks
-- exactly like "nobody is there", which is the failure this tool exists to make loud.
-- See docs/superpowers/specs/2026-07-17-per-station-proximity-design.md facts (2) and (3).
if args[1] == "test" and args[2] == "pos" then
  local det = peripheral.find("player_detector")
  if not det then
    print("No 'player_detector' found. Check the block is on the wired network.")
    return
  end
  local names = det.getOnlinePlayers()
  print(("getOnlinePlayers() -> %d: %s"):format(#names, table.concat(names, ", ")))
  if #names == 0 then print("Nobody online?? Stand in the world and re-run."); return end
  for _, n in ipairs(names) do
    local ok, p = pcall(det.getPlayerPos, n)
    if not ok then
      print(("  %s: THREW: %s"):format(n, tostring(p)))
      print("  => enablePlayerPosFunction = FALSE. Per-station proximity CANNOT work.")
      print("  => Ask for it to be enabled, or fall back to Plan B (detector per station).")
    elseif type(p) ~= "table" then
      print(("  %s: returned %s"):format(n, tostring(p)))
      print("  => nil = you are OUTSIDE playerDetMaxRange. It is CAPPED; ask for -1, or Plan B.")
    else
      print(("  %s: x=%s y=%s z=%s"):format(n, tostring(p.x), tostring(p.y), tostring(p.z)))
      print(("     dim=%s"):format(tostring(p.dimension)))
      if p.dimension == nil then
        print("  => no `dimension` field: morePlayerInformation = FALSE.")
        print("  => Ask for TRUE, else a player in the Nether can wake the floor.")
      end
    end
  end
  print("")
  print("CHECK: compare the x/z above against F3.")
  print("Off by tens of blocks => enablePlayerPosRandomError = TRUE => remote stations WILL NOT work.")
  print("Re-run this from ~1000 blocks out. nil there = capped range.")
  return
end

if args[1] == "test" and not args[2] then
  local det = peripheral.find("player_detector")
  if not det then
    print("No 'player_detector' found. Check the block is on the wired network.")
    print("Attached peripherals:")
    for _, n in ipairs(peripheral.getNames()) do print(("  %s (%s)"):format(n, peripheral.getType(n))) end
    return
  end
  print(("Player detector OK. Live isPlayersInRange(%d) — walk in/out; Q quits:"):format(DET_RANGE))
  local timer = os.startTimer(0.25)
  while true do
    local ev = { os.pullEvent() }
    if ev[1] == "timer" and ev[2] == timer then
      local _, row = term.getCursorPos()
      term.setCursorPos(1, row); term.clearLine()
      io.write("in range: " .. tostring(det.isPlayersInRange(DET_RANGE)))
      term.setCursorPos(1, row)
      timer = os.startTimer(0.25)
    elseif ev[1] == "key" and ev[2] == keys.q then
      print(""); return
    end
  end
end

-- load or initialise the registry
local reg = { assignments = {}, counters = {} }
if fs.exists(STORE) then
  local f = fs.open(STORE, "r"); local data = f.readAll(); f.close()
  local ok, t = pcall(textutils.unserialize, data)
  if ok and type(t) == "table" then reg = t end
end
reg.assignments = reg.assignments or {}   -- computerID -> { package = instance }
reg.counters    = reg.counters or {}      -- package -> highest instance handed out
reg.stations    = reg.stations or {}      -- computerID -> { pos = {x,y,z}, dim, range, label }

-- `hub test zones` — what the hub thinks the floor looks like. A station that never appears here
-- never registered a position, and is therefore still on the legacy "all" zone (not an error).
if args[1] == "test" and args[2] == "zones" then
  local n = 0
  for id, s in pairs(reg.stations) do
    n = n + 1
    -- %s, not %d, on the coords: parsePos accepts decimals BY DESIGN (F3 shows fractional XYZ, so
    -- `pos=105.5,64,-238.25` is what an owner naturally types) and gps.locate rounds to 0.01. %d
    -- would print 105 for 105.5 -- a diagnostic that quietly lies about the very value you ran it
    -- to inspect -- and on a Lua that errors instead of truncating, this print is inside the
    -- registrar loop, so it would take the hub and the whole floor down over a config typo.
    print(("  #%d  %s  pos=%s,%s,%s  range=%s  dim=%s"):format(
      id, s.label or "?", tostring(s.pos.x), tostring(s.pos.y), tostring(s.pos.z),
      tostring(s.range or prox.DEFAULT_RANGE), tostring(s.dim or DIM)))
  end
  if n == 0 then print("No stations have registered a position. All are on the legacy 'all' zone.") end
  return
end

-- An unknown subcommand must not silently boot the hub: `hub test drop` would otherwise look like it
-- worked while actually starting the registrar.
if args[1] == "test" then
  print(("Unknown subcommand: test %s"):format(tostring(args[2])))
  print("Try: `hub test` (range meter), `hub test pos`, `hub test zones`.")
  return
end

local function persist()
  local f = fs.open(STORE, "w"); f.write(textutils.serialize(reg)); f.close()
end

-- ---- score ledger (the economy) --------------------------------------------
local ledger      = require("ledger")
local LEDGER_STORE = "ledger.tbl"
local scores = {}
if fs.exists(LEDGER_STORE) then
  local f = fs.open(LEDGER_STORE, "r"); local d = f.readAll(); f.close()
  local ok, t = pcall(textutils.unserialize, d)
  if ok and type(t) == "table" then scores = t end
end
local function persistLedger()
  local f = fs.open(LEDGER_STORE, "w"); f.write(textutils.serialize(scores)); f.close()
end

local function assign(computerID, package)
  local a = reg.assignments[computerID]
  if not a then a = {}; reg.assignments[computerID] = a end
  if a[package] then return a[package] end          -- idempotent: same box keeps its number
  local n = (reg.counters[package] or 0) + 1
  reg.counters[package] = n
  a[package] = n
  persist()
  return n
end

print("Hub v0 registrar online.")
print(("  protocol '%s', hostname 'hub', computer ID %d"):format(PROTO, os.getComputerID()))
print("Listening for station registrations (Ctrl+T to stop)...")

-- shared occupancy: presenceLoop writes it each poll; registrar reads it to answer presence? queries
local occupied = false
-- Shared with presenceLoop, same reason `occupied` is: the registrar answers `presence?` pulls and
-- must give a registered station ITS OWN presence, not the floor-wide answer. A station that just
-- booted (chunk loaded because a player walked up) pulls before it can be pushed to -- that pull is
-- the entire reason a station 1000 blocks out works at all.
local zonePresent = {}     -- computerID -> boolean

local function registrar()
  while true do
    local sender, msg = rednet.receive(PROTO)
    if type(msg) == "table" and msg.kind == "register"
       and type(msg.computerID) == "number" and type(msg.package) == "string" then
      local n = assign(msg.computerID, msg.package)
      rednet.send(sender, { kind = "assigned", package = msg.package, instance = n }, PROTO)
      print(("  #%d  %s -> %s%d"):format(msg.computerID, msg.package, msg.package, n))
    elseif type(msg) == "table" and msg.kind == "station_pos"
           and type(msg.computerID) == "number" then
      -- A station reporting where it is. `pos = nil` deregisters it (it lost GPS and has no cfg),
      -- which drops it back to the legacy "all" zone rather than stranding it asleep forever.
      local pos = prox.parsePos(msg.pos)
      if pos then
        reg.stations[msg.computerID] = {
          pos   = pos,
          dim   = (type(msg.dim) == "string") and msg.dim or nil,
          range = tonumber(msg.range) or nil,
          label = (type(msg.label) == "string") and msg.label or nil,
        }
        print(("  #%d  pos %s,%s,%s%s"):format(msg.computerID,
          tostring(pos.x), tostring(pos.y), tostring(pos.z),
          msg.label and (" (" .. msg.label .. ")") or ""))
      else
        reg.stations[msg.computerID] = nil
        print(("  #%d  pos cleared -> legacy 'all' zone"):format(msg.computerID))
      end
      persist()
      rednet.send(sender, { kind = "station_pos_ok", computerID = msg.computerID,
                            zone = msg.computerID }, PROTO)
    elseif type(msg) == "table" and msg.kind == "mint" and type(msg.name) == "string" then
      local id, err = ledger.mint(scores, msg.name, tonumber(msg.balance) or 0)
      if id then
        persistLedger()
        rednet.send(sender, { kind = "minted", id = id }, PROTO)
        print(("  mint %s = %d"):format(id, scores[id]))
      else
        rednet.send(sender, { kind = "mint_deny", reason = err }, PROTO)
      end
    elseif type(msg) == "table" and msg.kind == "bet"
           and type(msg.id) == "string" and type(msg.stake) == "number" then
      local ok, bal = ledger.debit(scores, msg.id, msg.stake)
      if ok then
        persistLedger()
        rednet.send(sender, { kind = "bet_ok", id = msg.id, balance = bal }, PROTO)
      else
        rednet.send(sender, { kind = "bet_deny", id = msg.id, balance = bal,
                              reason = (bal == nil) and "unknown" or "insufficient" }, PROTO)
      end
    elseif type(msg) == "table" and msg.kind == "debit"
           and type(msg.id) == "string" and type(msg.amount) == "number" then
      local ok, bal = ledger.debit(scores, msg.id, msg.amount)
      if ok then
        persistLedger()
        rednet.send(sender, { kind = "debit_ok", id = msg.id, balance = bal }, PROTO)
      else
        rednet.send(sender, { kind = "debit_deny", id = msg.id, balance = bal,
                              reason = (bal == nil) and "unknown" or "insufficient" }, PROTO)
      end
    elseif type(msg) == "table" and msg.kind == "credit"
           and type(msg.id) == "string" and type(msg.delta) == "number" then
      local bal = ledger.apply(scores, msg.id, msg.delta)
      if bal then
        persistLedger()
        rednet.send(sender, { kind = "balance", id = msg.id, balance = bal }, PROTO)
      else
        rednet.send(sender, { kind = "credit_deny", id = msg.id, reason = "unknown" }, PROTO)
      end
    elseif type(msg) == "table" and msg.kind == "query" and type(msg.id) == "string" then
      rednet.send(sender, { kind = "balance", id = msg.id, balance = ledger.balance(scores, msg.id) }, PROTO)
    elseif idle.isPresenceQuery(msg) then
      local z = msg.zone
      if type(z) == "number" and zonePresent[z] ~= nil then
        rednet.send(sender, { kind = "presence", zone = z, present = zonePresent[z] }, PROTO)
      else
        rednet.send(sender, { kind = "presence", zone = "all", present = occupied }, PROTO)
      end
    end
  end
end

-- The hub's one forever-loop, and the floor's only proximity cost.
--
-- Per poll: isPlayersInRange (1 call, the legacy "all" zone) + getOnlinePlayers (1 call) +
-- getPlayerPos per online player (P calls). That is `2 + P` -- it does NOT grow with the number of
-- stations, which is the whole reason this design exists. Every one of those is mainThread = true
-- (~50ms of parked coroutine each, see [[main-thread-peripheral-calls-cost-a-tick]]), so the call
-- count is the budget. Matching is pure Lua and free. NEVER add a per-station peripheral call here.
--
-- Known bound, named not fixed: P is every player online SERVER-WIDE (playerDetMaxRange = -1), not
-- just the ones near the floor. Fine for a close-friends server; if this ever runs 20+ concurrent
-- players, raise POLL or gate on getPlayersInRange first. Do not pre-optimise.
local function presenceLoop()
  local det = peripheral.find("player_detector")
  if not det then
    print("No player detector attached — presence disabled (registrar only).")
    return
  end
  print(("Presence loop online: isPlayersInRange(%d) + position oracle every %.2fs."):format(DET_RANGE, POLL))
  local proxOff, warnedNil = false, false
  local timer = os.startTimer(POLL)
  while true do
    local ev = { os.pullEvent() }
    if ev[1] == "timer" and ev[2] == timer then
      -- ---- legacy "all" zone: byte-for-byte the old behaviour, for stations with no position ----
      local occ = det.isPlayersInRange(DET_RANGE) and true or false
      if idle.occupancyChanged(occupied, occ) then
        rednet.broadcast({ kind = "presence", zone = "all", present = occ }, PROTO)
        print(occ and "[presence] occupied -> WAKE" or "[presence] empty -> SLEEP")
      end
      occupied = occ

      -- ---- per-station zones ----
      if next(reg.stations) ~= nil then
        local now
        if proxOff then
          -- Degraded, but HONEST: with no positions we cannot say who is at WHICH station, so every
          -- registered station follows the hub's own floor-wide answer -- which is exactly the
          -- pre-feature behaviour. We cannot just let the "all" broadcast do it: presenceFor no
          -- longer treats "all" as a wildcard, so a registered station ignores it and would sleep
          -- forever. The cage has no lever; that would brick it.
          now = {}
          for id in pairs(reg.stations) do now[id] = occ end
        else
          local positions = {}
          local names = det.getOnlinePlayers()
          for _, name in ipairs(names) do
            -- pcall: getPlayerPos THROWS when enablePlayerPosFunction = false (spec fact 3). Unguarded,
            -- that kills the hub, and the hub is the one machine the whole floor depends on.
            local ok, p = pcall(det.getPlayerPos, name)
            if not ok then
              proxOff = true
              print("=====================================================")
              print(" PER-STATION PROXIMITY DISABLED")
              print(" getPlayerPos is disabled in the server config")
              print(" (enablePlayerPosFunction = false). Run `hub test pos`.")
              print(" Registered stations now follow the hub's own detector")
              print(" range instead of their real position -- same as before")
              print(" per-station zones existed: anyone near the HUB wakes ALL")
              print(" of them.")
              print("=====================================================")
              break
            end
            if type(p) == "table" then
              positions[name] = p
            elseif not warnedNil then
              -- nil for a player who IS online is the ONLY tell that playerDetMaxRange is capped --
              -- and it is otherwise completely silent: a capped range looks exactly like "nobody is
              -- there", so distant stations would just never wake and nothing would say why. (It can
              -- also mean the player logged off mid-poll, which is harmless -- hence a one-time note,
              -- not a fatal.) The owner verified getPlayerPos out to ~500 blocks, so at -1 this should
              -- never print; if it starts printing, the cap is real and the stations beyond it are the
              -- ones going dark.
              warnedNil = true
              print(("[proximity] NOTE: getPlayerPos(%s) returned nil for an ONLINE player."):format(name))
              print("  Harmless if they just logged off. If it repeats, playerDetMaxRange is CAPPED —")
              print("  stations beyond it will never wake. Run `hub test pos` from a far station.")
            end
          end
          if proxOff then
            now = nil   -- latched on THIS poll: skip; next poll takes the degraded arm above
          else
            now = prox.evaluate(reg.stations, positions, DIM)
          end
        end
        if now then
          for _, e in ipairs(prox.edges(zonePresent, now)) do
            rednet.send(e.id, { kind = "presence", zone = e.id, present = e.present }, PROTO)
            print(("[zone] #%d -> %s"):format(e.id, e.present and "WAKE" or "SLEEP"))
          end
          zonePresent = now   -- shared upvalue: the registrar answers `presence?` pulls from this
        end
      end

      timer = os.startTimer(POLL)
    end
  end
end

parallel.waitForAll(registrar, presenceLoop)
