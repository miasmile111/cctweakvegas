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
local args      = { ... }

local function findModem()
  -- prefer a wired modem (floor network); accept wireless for testing.
  local wired = peripheral.find("modem", function(_, m) return not m.isWireless() end)
  return wired or peripheral.find("modem")
end

local modem = findModem()
if not modem then
  print("===========================")
  print(" HUB needs a MODEM to run!")
  print("===========================")
  print("Attach a modem (wired on a network cable), then re-run `hub`.")
  return
end

rednet.open(peripheral.getName(modem))
rednet.host(PROTO, "hub")

if args[1] == "test" then
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

local function registrar()
  while true do
    local sender, msg = rednet.receive(PROTO)
    if type(msg) == "table" and msg.kind == "register"
       and type(msg.computerID) == "number" and type(msg.package) == "string" then
      local n = assign(msg.computerID, msg.package)
      rednet.send(sender, { kind = "assigned", package = msg.package, instance = n }, PROTO)
      print(("  #%d  %s -> %s%d"):format(msg.computerID, msg.package, msg.package, n))
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
      rednet.send(sender, { kind = "presence", zone = "all", present = occupied }, PROTO)
    end
  end
end

local function presenceLoop()
  local det = peripheral.find("player_detector")
  if not det then
    print("No player detector attached — presence disabled (registrar only).")
    return
  end
  print(("Presence loop online: isPlayersInRange(%d) every %.2fs."):format(DET_RANGE, POLL))
  local timer = os.startTimer(POLL)
  while true do
    local ev = { os.pullEvent() }
    if ev[1] == "timer" and ev[2] == timer then
      local occ = det.isPlayersInRange(DET_RANGE) and true or false
      if idle.occupancyChanged(occupied, occ) then
        rednet.broadcast({ kind = "presence", zone = "all", present = occ }, PROTO)
        print(occ and "[presence] occupied -> WAKE" or "[presence] empty -> SLEEP")
      end
      occupied = occ                    -- keep shared state current so registrar can answer queries
      timer = os.startTimer(POLL)
    end
  end
end

parallel.waitForAll(registrar, presenceLoop)
