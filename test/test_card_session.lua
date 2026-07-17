-- test_card_session.lua — one card on one drive: the session machinery sp_econ and cage_econ
-- both grew independently, extracted when mp_econ made it three.
package.path = "src/lib/?.lua;test/?.lua;" .. package.path
local t = require("runner")

-- ---- stub the two modules card_session composes ---------------------------
local stubCard = { _disks = {}, _mirrors = {}, _reads = 0 }
function stubCard.read(drive)
  stubCard._reads = stubCard._reads + 1
  return stubCard._disks[drive or "_first"]
end
function stubCard.writeMirror(score, drive) stubCard._mirrors[drive or "_first"] = score end
function stubCard.isCardEvent(ev) return ev[1] == "disk" or ev[1] == "disk_eject" end

local stubWallet = { _query = {}, _flushes = 0, _queries = 0 }
function stubWallet.flush() stubWallet._flushes = stubWallet._flushes + 1 end
function stubWallet.query(id)
  stubWallet._queries = stubWallet._queries + 1
  return stubWallet._query.balance, stubWallet._query.reason
end

package.loaded["card"]   = stubCard
package.loaded["wallet"] = stubWallet
local cs = require("card_session")

local function reset()
  stubCard._disks, stubCard._mirrors, stubCard._reads = {}, {}, 0
  stubWallet._query, stubWallet._flushes, stubWallet._queries = {}, 0, 0
end

-- ---- a bound session reads ITS drive ----
do
  reset()
  stubCard._disks["drive_0"] = { id = "alice", score = 500 }
  stubCard._disks["drive_1"] = { id = "bob",   score = 120 }
  stubWallet._query = { balance = 640 }
  local s = cs.new{ drive = "drive_1" }
  t.eq(s.player, "bob", "a session bound to a drive reads THAT card")
  t.eq(s.balance, 640, "hub balance wins over the card mirror")
  t.eq(stubCard._mirrors["drive_1"], 640, "and the mirror is written back to THAT drive")
end

-- ---- an unbound session is the old single-card behaviour ----
do
  reset()
  stubCard._disks["_first"] = { id = "alice", score = 500 }
  stubWallet._query = { balance = 500 }
  local s = cs.new{}
  t.eq(s.player, "alice", "drive=nil -> the first drive, exactly as before")
end

-- ---- hub offline: fall back to the mirror, and SAY it is offline ----
do
  reset()
  stubCard._disks["_first"] = { id = "alice", score = 500 }
  stubWallet._query = { balance = nil, reason = "timeout" }
  local s = cs.new{}
  t.ok(s.offline, "card in + hub timeout -> offline")
  t.eq(s.balance, 500, "offline falls back to the card's score mirror")
  t.eq(stubCard._mirrors["_first"], nil, "and does NOT write a mirror it never got from the hub")
end

-- ---- no card is anonymous free play, NOT a hub error ----
do
  reset()
  stubWallet._query = { balance = nil, reason = "timeout" }
  local s = cs.new{}
  t.eq(s.player, nil, "no card -> anonymous")
  t.ok(not s.offline, "no card -> not offline: nobody asked the hub anything")
  t.eq(stubWallet._queries, 0, "and no card means no pointless hub round-trip")
end

-- ---- onEvent: only MY drive's events (the N-round-trips bug) ----
do
  reset()
  stubCard._disks["drive_1"] = { id = "bob", score = 120 }
  stubWallet._query = { balance = 120 }
  local s = cs.new{ drive = "drive_1" }
  local before = stubWallet._queries

  s.onEvent({ "disk", "drive_0" })
  t.eq(stubWallet._queries, before, "another seat's disk event does NOT re-query my card")

  stubCard._disks["drive_1"] = { id = "carol", score = 9 }
  s.onEvent({ "disk", "drive_1" })
  t.eq(s.player, "carol", "MY drive's disk event refreshes me")

  s.onEvent({ "timer", 1 })
  t.eq(s.player, "carol", "a non-card event changes nothing")
end

-- ---- an UNBOUND session refreshes on any drive's event (it has no drive of its own) ----
do
  reset()
  stubCard._disks["_first"] = { id = "alice", score = 500 }
  stubWallet._query = { balance = 500 }
  local s = cs.new{}
  stubCard._disks["_first"] = nil
  s.onEvent({ "disk_eject", "left" })
  t.eq(s.player, nil, "drive=nil -> any card event refreshes; ejected -> anonymous")
end

-- ---- ejecting while offline clears offline ----
do
  reset()
  stubCard._disks["_first"] = { id = "alice", score = 500 }
  stubWallet._query = { balance = nil, reason = "timeout" }
  local s = cs.new{}
  t.ok(s.offline, "precondition: starts offline with a card in")
  stubCard._disks["_first"] = nil
  s.onEvent({ "disk_eject", "left" })
  t.ok(not s.offline, "card ejected while offline -> offline cleared")
end

-- ---- noteHub: the caller's hub calls decide offline too ----
do
  reset()
  stubCard._disks["_first"] = { id = "alice", score = 500 }
  stubWallet._query = { balance = 500 }
  local s = cs.new{}
  t.ok(not s.offline, "precondition: hub answered")
  s.noteHub("timeout")
  t.ok(s.offline, "noteHub('timeout') -> offline")
  s.noteHub("insufficient")
  t.ok(not s.offline, "an insufficient deny is NOT offline -- the hub answered")
  s.noteHub(nil)
  t.ok(not s.offline, "a clean call clears offline")
end

-- ---- setBalance: display + mirror in step ----
do
  reset()
  stubCard._disks["drive_1"] = { id = "bob", score = 120 }
  stubWallet._query = { balance = 120 }
  local s = cs.new{ drive = "drive_1" }
  s.setBalance(90)
  t.eq(s.balance, 90, "setBalance updates the displayed balance")
  t.eq(stubCard._mirrors["drive_1"], 90, "setBalance writes the mirror to MY drive")
end

-- ---- flush: once per station, not once per seat ----
do
  reset()
  local s = cs.new{}
  t.eq(stubWallet._flushes, 1, "a session flushes the outbox on entry by default")

  reset()
  local a = cs.new{ drive = "drive_0", flush = false }
  local b = cs.new{ drive = "drive_1", flush = false }
  t.eq(stubWallet._flushes, 0, "flush=false suppresses it -- mp_econ flushes ONCE for the station")
end

-- ---- status() ----
do
  reset()
  stubCard._disks["_first"] = { id = "alice", score = 500 }
  stubWallet._query = { balance = 640 }
  local st = cs.new{}.status()
  t.eq(st.player, "alice", "status carries the player")
  t.eq(st.balance, 640, "status carries the balance")
  t.ok(not st.offline, "status carries offline")
end

t.done()
