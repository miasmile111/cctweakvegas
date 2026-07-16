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
-- Later this same service will handle the score economy (credit/query) — see the spec.

local PROTO = "ccvegas"
local STORE = "registry.tbl"

local function findWiredModem()
  return peripheral.find("modem", function(_, m) return not m.isWireless() end)
end

local modem = findWiredModem()
if not modem then
  print("=================================")
  print(" HUB needs a WIRED MODEM to run!")
  print("=================================")
  print("Attach a modem on a network cable, then re-run `hub`.")
  return
end

rednet.open(peripheral.getName(modem))
rednet.host(PROTO, "hub")

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

while true do
  local sender, msg = rednet.receive(PROTO)
  if type(msg) == "table" and msg.kind == "register"
     and type(msg.computerID) == "number" and type(msg.package) == "string" then
    local n = assign(msg.computerID, msg.package)
    rednet.send(sender, { kind = "assigned", package = msg.package, instance = n }, PROTO)
    print(("  #%d  %s -> %s%d"):format(msg.computerID, msg.package, msg.package, n))
  end
end
