-- test_cage_econ.lua — the cage's gateway on the shared card_session.
--
-- Two jobs: pin the shipped behaviour through the extraction (the cage is in-world verified), and
-- kill the drift -- cage_econ folded hub-unreachable and insufficient-funds into one msg string, so
-- a card whose ledger id was deleted rendered "NEED $100" at a player who was not broke.
package.path = "src/lib/?.lua;test/?.lua;" .. package.path
local t = require("runner")

local stubCard = { _disk = nil, _mirror = nil }
function stubCard.read(drive) return stubCard._disk end
function stubCard.writeMirror(b, drive) stubCard._mirror = b end
function stubCard.isCardEvent(ev) return ev[1] == "disk" or ev[1] == "disk_eject" end

local stubWallet = { _query = {}, _debit = {}, _credit = {} }
function stubWallet.flush() end
function stubWallet.query(id) return stubWallet._query.balance, stubWallet._query.reason end
function stubWallet.debit(id, amt)
  stubWallet._lastDebit = { id = id, amount = amt }
  return stubWallet._debit.ok, stubWallet._debit.balance, stubWallet._debit.reason
end
function stubWallet.credit(id, d)
  stubWallet._lastCredit = { id = id, delta = d }
  return stubWallet._credit.ok, stubWallet._credit.balance, stubWallet._credit.reason
end

package.loaded["card"]   = stubCard
package.loaded["wallet"] = stubWallet
local ce = require("cage_econ")

local function reset()
  stubCard._disk, stubCard._mirror = nil, nil
  stubWallet._query, stubWallet._debit, stubWallet._credit = {}, {}, {}
  stubWallet._lastDebit, stubWallet._lastCredit = nil, nil
end

-- ---- no card: buttons inert, never a gate ----
do
  reset()
  local e = ce.new{}
  t.eq(e.tryDebit(100), "nocard", "no card -> nocard")
  t.eq(e.status().msg, "INSERT CARD", "and it says so")
  t.eq(stubWallet._lastDebit, nil, "and nothing was debited")
end

-- ---- a funded debit ----
do
  reset()
  stubCard._disk = { id = "alice", score = 500 }
  stubWallet._query = { balance = 500 }
  local e = ce.new{}
  stubWallet._debit = { ok = true, balance = 400 }
  t.eq(e.tryDebit(100), "ok", "a funded debit succeeds")
  t.eq(e.status().balance, 400, "balance updates")
  t.eq(stubCard._mirror, 400, "and the card mirror is written")
end

-- ---- insufficient: the honest message ----
do
  reset()
  stubCard._disk = { id = "alice", score = 50 }
  stubWallet._query = { balance = 50 }
  local e = ce.new{}
  stubWallet._debit = { ok = false, balance = 50, reason = "insufficient" }
  t.eq(e.tryDebit(100), "deny", "insufficient fails closed")
  t.eq(e.status().msg, "NEED $100", "insufficient says what you need")
  t.ok(e.status().denied, "and is denied")
  t.ok(not e.status().offline, "insufficient is NOT offline -- the hub answered")
end

-- ---- hub down ----
do
  reset()
  stubCard._disk = { id = "alice", score = 500 }
  stubWallet._query = { balance = 500 }
  local e = ce.new{}
  stubWallet._debit = { ok = false, balance = nil, reason = "timeout" }
  t.eq(e.tryDebit(100), "deny", "a hub timeout fails closed -- no metal moves")
  t.eq(e.status().msg, "HUB OFFLINE", "and says the hub is offline")
  t.ok(e.status().offline, "offline flag is set")
end

-- ---- THE DRIFT: a dead card id must not read as "you are broke" ----
do
  reset()
  stubCard._disk = { id = "ghost", score = 500 }
  stubWallet._query = { balance = 500 }
  local e = ce.new{}
  stubWallet._debit = { ok = false, balance = nil, reason = "unknown" }
  t.eq(e.tryDebit(100), "deny", "a dead card id fails closed")
  t.eq(e.status().msg, "BAD CARD", "a deleted ledger id says BAD CARD, NOT 'NEED $100'")
  t.ok(not e.status().offline, "and it is not offline -- the hub answered")
end

-- ---- deposit ----
do
  reset()
  stubCard._disk = { id = "alice", score = 500 }
  stubWallet._query = { balance = 500 }
  local e = ce.new{}
  stubWallet._credit = { ok = true, balance = 600 }
  t.eq(e.deposit(100), 600, "a deposit credits and returns the new balance")
  t.eq(stubCard._mirror, 600, "and mirrors it")
end

do
  reset()
  stubCard._disk = { id = "ghost", score = 500 }
  stubWallet._query = { balance = 500 }
  local e = ce.new{}
  stubWallet._credit = { ok = false, balance = nil, reason = "unknown" }
  t.eq(e.deposit(100), nil, "a deposit to a dead id is refused")
  t.eq(e.status().msg, "BAD CARD", "and says BAD CARD")
end

do
  reset()
  stubCard._disk = { id = "alice", score = 500 }
  stubWallet._query = { balance = 500 }
  local e = ce.new{}
  stubWallet._credit = { ok = false, balance = nil, reason = "queued" }
  t.eq(e.deposit(100), 600, "a hub-down deposit is outboxed and reflected locally -- never lost")
  t.eq(e.status().msg, "HUB OFFLINE", "and says so")
end

-- ---- refund follows the DEBITED id, not the live card ----
do
  reset()
  stubCard._disk = { id = "alice", score = 500 }
  stubWallet._query = { balance = 500 }
  local e = ce.new{}
  stubWallet._debit = { ok = true, balance = 400 }
  t.eq(e.tryDebit(100), "ok", "precondition: alice paid")

  stubCard._disk = { id = "bob", score = 20 }     -- alice ejected mid-shower, bob inserted
  stubWallet._query = { balance = 20 }
  e.onEvent({ "disk", "left" })
  t.eq(e.status().player, "bob", "precondition: bob's card is in the drive now")

  stubWallet._credit = { ok = true, balance = 450 }
  e.refund(50)
  t.eq(stubWallet._lastCredit.id, "alice", "the refund goes to whoever PAID, not the live card")
  t.eq(e.status().balance, 20, "and bob's displayed balance is untouched")
end

t.done()
