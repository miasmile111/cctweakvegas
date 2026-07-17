package.path = "src/lib/?.lua;src/slot/?.lua;test/?.lua;" .. package.path
local t = require("runner")

-- ---- stub the two modules sp_econ composes -------------------------------
local stubCard = { _disk = nil }
function stubCard.read() return stubCard._disk end
function stubCard.writeMirror(b) stubCard._mirror = b end
function stubCard.isCardEvent(ev) return ev[1] == "disk" or ev[1] == "disk_eject" end

local stubWallet = { _query = {}, _bet = {} }
function stubWallet.flush() end
function stubWallet.query(id) return stubWallet._query.balance, stubWallet._query.reason end
function stubWallet.bet(id, st) return stubWallet._bet.ok, stubWallet._bet.balance, stubWallet._bet.reason end
function stubWallet.credit(id, d) return true, 0 end

package.loaded["card"]   = stubCard
package.loaded["wallet"] = stubWallet
local sp = require("sp_econ")

local PAY = { STAKE = 10, eval = function() return 0 end }
local function newEcon() return sp.new({ pay = PAY }) end

-- ---- refreshCard: a hub timeout with a card in is OFFLINE, not "no balance" ----
do
  stubCard._disk = { id = "alice", score = 500 }
  stubWallet._query = { balance = nil, reason = "timeout" }
  local e = newEcon()
  t.ok(e.status().offline, "card in + hub timeout -> offline")
  t.eq(e.status().balance, 500, "offline falls back to the card's score mirror")
end

-- ---- a healthy hub is not offline ----
do
  stubCard._disk = { id = "alice", score = 500 }
  stubWallet._query = { balance = 640, reason = nil }
  local e = newEcon()
  t.ok(not e.status().offline, "hub answered -> not offline")
  t.eq(e.status().balance, 640, "hub balance wins over the card mirror")
end

-- ---- no card: not offline, regardless of the hub ----
do
  stubCard._disk = nil
  stubWallet._query = { balance = nil, reason = "timeout" }
  local e = newEcon()
  t.ok(not e.status().offline, "no card -> anonymous free play, not an offline error")
end

-- ---- ejecting a card WHILE offline clears offline (anonymous free play is not a hub error) ----
-- Without a starting offline=true this asserts nothing: fresh state is already false.
do
  stubCard._disk = { id = "alice", score = 500 }
  stubWallet._query = { balance = nil, reason = "timeout" }
  local e = newEcon()
  t.ok(e.status().offline, "precondition: starts offline with a card in")
  stubCard._disk = nil
  e.onEvent({ "disk_eject", "left" })
  t.ok(not e.status().offline, "card ejected while offline -> offline cleared")
  t.eq(e.status().player, nil, "and the player is anonymous again")
end

-- ---- tryBet: THE LIE. A hub timeout must NOT read as INSUFFICIENT ----
do
  stubCard._disk = { id = "alice", score = 500 }
  stubWallet._query = { balance = 500, reason = nil }
  local e = newEcon()
  stubWallet._bet = { ok = false, balance = nil, reason = "timeout" }
  t.eq(e.tryBet(10), "deny", "hub timeout still fails closed (no free spins)")
  t.ok(e.status().offline, "hub timeout -> offline, NOT insufficient")
end

-- ---- tryBet: a real insufficient-funds deny is NOT offline ----
do
  stubCard._disk = { id = "alice", score = 5 }
  stubWallet._query = { balance = 5, reason = nil }
  local e = newEcon()
  stubWallet._bet = { ok = false, balance = 5, reason = "insufficient" }
  t.eq(e.tryBet(10), "deny", "insufficient funds fails closed")
  t.ok(e.status().denied, "insufficient -> denied")
  t.ok(not e.status().offline, "insufficient is NOT offline -- the hub answered")
end

-- ---- a successful bet clears a STALE offline (hub went down, then came back) ----
-- Must start offline, or this test passes against a tryBet that never clears the flag at all.
do
  stubCard._disk = { id = "alice", score = 500 }
  stubWallet._query = { balance = nil, reason = "timeout" }
  local e = newEcon()
  t.ok(e.status().offline, "precondition: starts offline")
  stubWallet._bet = { ok = true, balance = 490 }
  t.eq(e.tryBet(10), "staked", "funded bet stakes the round once the hub is back")
  t.ok(not e.status().offline, "a successful bet clears the stale offline")
  t.ok(not e.status().denied, "and leaves denied clear")
end

-- ---- the hub coming back clears offline on the next card read ----
do
  stubCard._disk = { id = "alice", score = 500 }
  stubWallet._query = { balance = nil, reason = "timeout" }
  local e = newEcon()
  t.ok(e.status().offline, "starts offline")
  stubWallet._query = { balance = 640, reason = nil }
  e.onEvent({ "disk", "left" })
  t.ok(not e.status().offline, "hub back -> offline clears, no reboot")
  t.eq(e.status().balance, 640, "and the live balance returns")
end

t.done()
