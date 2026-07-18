-- test_mp_econ.lua — the pot engine: N seats, N cards, ante -> pot -> payout.
--
-- The money rules under test, in order of how much they would cost to get wrong:
--   1. the ante is ALL-OR-NOTHING (a partial pot pays out money that was never all there)
--   2. the payout follows the ANTED id, never the live card (pull yours mid-match, still get paid)
--   3. an anonymous seat can win the MATCH but never the POT (it never paid in)
package.path = "src/lib/?.lua;test/?.lua;" .. package.path
local t = require("runner")

-- ---- stubs -----------------------------------------------------------------
local stubCard = { _disks = {}, _mirrors = {}, _drives = {} }
function stubCard.drives() return stubCard._drives end
function stubCard.read(drive) return stubCard._disks[drive] end
function stubCard.writeMirror(b, drive) stubCard._mirrors[drive] = b end
function stubCard.isCardEvent(ev) return ev[1] == "disk" or ev[1] == "disk_eject" end

local stubWallet = { _balances = {}, _debit = {}, _credit = {}, _flushes = 0 }
function stubWallet.flush() stubWallet._flushes = stubWallet._flushes + 1 end
function stubWallet.query(id) return stubWallet._balances[id], nil end

-- per-id scripted debit outcomes: _debit[id] = { ok=, balance=, reason= }; default ok.
function stubWallet.debit(id, amt)
  local r = stubWallet._debit[id] or { ok = true, balance = (stubWallet._balances[id] or 0) - amt }
  stubWallet._calls[#stubWallet._calls + 1] = { op = "debit", id = id, amount = amt }
  return r.ok, r.balance, r.reason
end
function stubWallet.credit(id, delta)
  local r = stubWallet._credit[id] or { ok = true, balance = (stubWallet._balances[id] or 0) + delta }
  stubWallet._calls[#stubWallet._calls + 1] = { op = "credit", id = id, delta = delta }
  return r.ok, r.balance, r.reason
end

package.loaded["card"]   = stubCard
package.loaded["wallet"] = stubWallet
local mp = require("mp_econ")

local function reset()
  stubCard._disks, stubCard._mirrors, stubCard._drives = {}, {}, {}
  stubWallet._balances, stubWallet._debit, stubWallet._credit = {}, {}, {}
  stubWallet._calls, stubWallet._flushes = {}, 0
end

-- seat the given cards on drive_0..drive_(n-1). `nil` in the list = an empty drive (anon seat).
local function seat(cards)
  for i, c in ipairs(cards) do
    local d = "drive_" .. (i - 1)
    stubCard._drives[i] = d
    if c ~= "anon" then
      stubCard._disks[d] = { id = c, score = 500 }
      stubWallet._balances[c] = 500
    end
  end
end

local function creditsTo(id)
  local total = 0
  for _, c in ipairs(stubWallet._calls) do
    if c.op == "credit" and c.id == id then total = total + c.delta end
  end
  return total
end

-- ---- seats come from the drives, cards or not ----
do
  reset(); seat{ "alice", "anon" }
  local e = mp.new{ ante = 10 }
  t.eq(#e.seats, 2, "a drive is a seat, disk or not -- an empty seat is an anonymous player")
  t.eq(e.seats[1].session.player, "alice", "seat 1 reads drive_0")
  t.eq(e.seats[2].session.player, nil, "seat 2 is anonymous")
  t.eq(e.cardedCount(), 1, "cardedCount counts readable cards")
  t.eq(e.phase, "lobby", "starts in the lobby")
end

do
  reset(); seat{ "a", "b", "c", "d", "e" }
  local e = mp.new{ ante = 10, maxSeats = 4 }
  t.eq(#e.seats, 4, "maxSeats caps the seats created from drives")
end

do
  reset(); seat{ "alice", "bob" }
  local e = mp.new{ ante = 10, drives = { "drive_1", "drive_0" } }
  t.eq(e.seats[1].session.player, "bob", "cfg drives= overrides discovery AND sets seat order")
end

-- ---- the station flushes ONCE, not once per seat ----
do
  reset(); seat{ "alice", "bob", "carol", "dave" }
  mp.new{ ante = 10 }
  t.eq(stubWallet._flushes, 1, "4 seats flush the outbox ONCE, not four times")
end

-- ---- staked needs >= minSeats CARDED seats ----
do
  reset(); seat{ "alice", "anon" }
  local e = mp.new{ ante = 10 }
  t.ok(not e.canStake(), "1 carded seat cannot make a pot")
  t.eq(e.start(), "free", "1 carded seat -> a FREE match (it would ante and win its own ante back)")
  t.eq(e.pot, 0, "no pot")
  t.eq(#stubWallet._calls, 0, "and NOBODY is debited")
  t.eq(e.phase, "playing", "a free match still starts")
end

do
  reset(); seat{ "anon", "anon" }
  local e = mp.new{ ante = 10 }
  t.eq(e.start(), "free", "0 carded seats -> free (today's pong)")
  t.eq(#stubWallet._calls, 0, "nobody is debited")
end

-- ---- the happy path ----
do
  reset(); seat{ "alice", "bob" }
  local e = mp.new{ ante = 10 }
  t.ok(e.canStake(), "2 carded seats can stake")
  t.eq(e.start(), "staked", "2 carded seats -> staked")
  t.eq(e.pot, 20, "pot = ante * carded seats")
  t.eq(e.phase, "playing", "phase moves to playing")
  t.eq(e.seats[1].antedId, "alice", "seat 1 locked to the id that paid")
  t.eq(e.seats[2].antedId, "bob", "seat 2 locked to the id that paid")
  t.eq(e.seats[1].session.balance, 490, "and the balance reflects the debit")
  t.eq(stubCard._mirrors["drive_0"], 490, "and the card mirror is written")
end

-- ---- THE ALL-OR-NOTHING ANTE: seat 2 broke -> seat 1 refunded ----
do
  reset(); seat{ "alice", "bob" }
  stubWallet._debit["bob"] = { ok = false, balance = 5, reason = "insufficient" }
  local e = mp.new{ ante = 10 }
  local res, reason, seatIdx = e.start()
  t.eq(res, "deny", "one seat short denies the whole match")
  t.eq(reason, "insufficient", "and names the reason")
  t.eq(seatIdx, 2, "and names the seat")
  t.eq(creditsTo("alice"), 10, "ALICE IS REFUNDED IN FULL -- a partial pot is never left standing")
  t.eq(e.pot, 0, "no pot")
  t.eq(e.phase, "lobby", "back to the lobby")
  t.eq(e.seats[1].antedId, nil, "and seat 1 is unlocked")
end

do
  reset(); seat{ "alice", "bob", "carol" }
  stubWallet._debit["carol"] = { ok = false, balance = nil, reason = "timeout" }
  local e = mp.new{ ante = 10 }
  local res, reason, seatIdx = e.start()
  t.eq(res, "deny", "a hub timeout mid-ante denies the match")
  t.eq(reason, "timeout", "and reports the timeout")
  t.eq(seatIdx, 3, "at the seat that failed")
  t.eq(creditsTo("alice"), 10, "alice refunded")
  t.eq(creditsTo("bob"), 10, "bob refunded -- BOTH earlier seats, not just the last one")
  t.ok(e.seats[3].session.offline, "and the failing seat is marked offline, not broke")
end

-- ---- the payout ----
do
  reset(); seat{ "alice", "bob" }
  local e = mp.new{ ante = 10 }
  e.start()
  local r = e.finish{ [1] = 5, [2] = 3 }
  t.eq(r.matchWinner, 1, "highest score takes the match")
  t.eq(r.potWinner, 1, "and the pot")
  t.eq(r.pot, 20, "the pot was 20")
  t.eq(r.potShare[1], 20, "the winner is credited the whole pot")
  t.eq(creditsTo("alice"), 20, "alice got the money")
  t.eq(creditsTo("bob"), 0, "bob got nothing")
  t.eq(e.phase, "done", "match is done")
  t.eq(e.pot, 0, "and the pot is cleared")
end

-- ---- AN ANON CAN WIN THE MATCH BUT NOT THE POT ----
do
  reset(); seat{ "alice", "bob", "anon" }
  local e = mp.new{ ante = 10 }
  t.eq(e.start(), "staked", "2 carded + 1 anon is a staked match")
  t.eq(e.pot, 20, "the anon contributes nothing to the pot")
  local r = e.finish{ [1] = 3, [2] = 1, [3] = 9 }
  t.eq(r.matchWinner, 3, "the anon takes the MATCH -- glory is free")
  t.eq(r.potWinner, 1, "but the best CARDED seat takes the money")
  t.eq(creditsTo("alice"), 20, "alice gets the pot she paid into")
  t.eq(r.potShare[3], nil, "the anon is credited nothing")
end

-- ---- ties: split, remainder to the lowest seat, shares sum to the pot EXACTLY ----
do
  reset(); seat{ "alice", "bob" }
  local e = mp.new{ ante = 10 }
  e.start()
  local r = e.finish{ [1] = 4, [2] = 4 }
  t.eq(r.potShare[1] + r.potShare[2], 20, "an even tie splits the pot exactly")
  t.eq(r.potShare[1], 10, "10 each")
  t.eq(r.potShare[2], 10, "10 each")
end

do
  reset(); seat{ "alice", "bob", "carol" }
  local e = mp.new{ ante = 5 }
  e.start()                                     -- pot = 15
  local r = e.finish{ [1] = 4, [2] = 4, [3] = 4 }
  t.eq(r.potShare[1] + r.potShare[2] + r.potShare[3], 15, "a 3-way tie sums to the pot exactly")
end

do
  reset(); seat{ "alice", "bob", "carol" }
  local e = mp.new{ ante = 10 }
  e.start()                                     -- pot = 30
  local r = e.finish{ [1] = 4, [2] = 4, [3] = 0 }
  t.eq(r.potShare[1], 15, "a 2-way tie of a 30 pot splits 15/15")
  t.eq(r.potShare[2], 15, "15")
  t.eq(r.potShare[3], nil, "the loser gets nothing")
end

do
  reset(); seat{ "alice", "bob" }
  local e = mp.new{ ante = 5 }
  e.start()                                     -- pot = 10... make it odd:
  e.pot = 11                                    -- force an odd pot to pin the remainder rule
  local r = e.finish{ [1] = 2, [2] = 2 }
  t.eq(r.potShare[1] + r.potShare[2], 11, "an ODD pot still sums exactly -- no $ evaporates")
  t.eq(r.potShare[1], 6, "the remainder goes to the LOWEST seat index")
  t.eq(r.potShare[2], 5, "the other tied seat gets the floor")
end

-- ---- THE HEADLINE: the payout follows the ANTED id, not the live card ----
do
  reset(); seat{ "alice", "bob" }
  local e = mp.new{ ante = 10 }
  e.start()
  stubCard._disks["drive_0"] = nil                 -- alice pulls her card mid-match
  e.onEvent({ "disk_eject", "drive_0" })
  t.eq(e.seats[1].session.player, nil, "precondition: seat 1's drive is empty now")
  t.eq(e.seats[1].antedId, "alice", "but the seat is still locked to the id that paid")
  local r = e.finish{ [1] = 5, [2] = 1 }
  t.eq(creditsTo("alice"), 20, "ALICE IS PAID even though her card is gone")
  t.eq(r.potWinner, 1, "her seat won")
end

do
  reset(); seat{ "alice", "bob" }
  local e = mp.new{ ante = 10 }
  e.start()
  stubCard._disks["drive_0"] = { id = "carol", score = 0 }   -- a STRANGER takes the seat
  stubWallet._balances["carol"] = 0
  e.onEvent({ "disk", "drive_0" })
  t.eq(e.seats[1].session.player, "carol", "precondition: carol's card is in seat 1's drive")
  t.eq(e.seats[1].antedId, "alice", "the seat is STILL alice's -- carol is a spectator")
  e.finish{ [1] = 5, [2] = 1 }
  t.eq(creditsTo("alice"), 20, "alice is paid")
  t.eq(creditsTo("carol"), 0, "the spectator gets NOTHING -- she never paid in")
end

-- ---- a free match pays nobody ----
do
  reset(); seat{ "alice", "anon" }
  local e = mp.new{ ante = 10 }
  e.start()                                     -- free: only 1 carded
  local r = e.finish{ [1] = 5, [2] = 1 }
  t.eq(r.pot, 0, "a free match has no pot")
  t.eq(r.matchWinner, 1, "but it still has a winner -- glory")
  t.eq(r.potWinner, nil, "nobody wins money")
  t.eq(#stubWallet._calls, 0, "and no hub write ever happened")
end

-- ---- a second match clears the seats ----
do
  reset(); seat{ "alice", "bob" }
  local e = mp.new{ ante = 10 }
  e.start()
  e.finish{ [1] = 5, [2] = 1 }
  t.eq(e.start(), "staked", "a new match can start after one finishes")
  t.eq(e.pot, 20, "with a fresh pot")
  t.eq(e.seats[1].antedId, "alice", "and freshly locked seats")
end

do
  reset(); seat{ "alice", "bob" }
  local e = mp.new{ ante = 10 }
  e.start()
  local res = e.start()
  t.eq(res, "deny", "GO during a live match is refused -- it must not double-ante")
  t.eq(e.pot, 20, "and the pot is untouched")
end

-- ---- reset(): "done" must not be terminal -----------------------------------
-- finish() parks the instance in "done". Without reset() a station can play exactly ONE match and
-- then refuses every GO forever ("already playing" / a dead phase) -- the in-world reset bug.
do
  reset(); seat{ "alice", "bob" }
  local e = mp.new{ ante = 10 }
  t.eq(e.start(), "staked", "first match antes")
  e.finish{ [1] = 5, [2] = 3 }
  t.eq(e.phase, "done", "finish parks in done")

  e.reset()
  t.eq(e.phase, "lobby", "reset returns the phase to lobby")
  t.eq(e.pot, 0, "reset zeroes the pot")
  t.eq(e.seats[1].antedId, nil, "reset clears seat 1's anted id")
  t.eq(e.seats[2].antedId, nil, "reset clears seat 2's anted id")
  t.eq(e.seats[1].anted, 0, "reset zeroes seat 1's anted amount")

  t.eq(e.start(), "staked", "and a SECOND match can start on the same instance")
  t.eq(e.pot, 20, "the second pot is a full pot, not a leftover")
end

-- reset() mid-match must not silently eat a live pot: it is a lobby-return, not a resolver.
-- match.lua always finish()es before reset()ing; this asserts reset is not doing money work.
do
  reset(); seat{ "alice", "bob" }
  local e = mp.new{ ante = 10 }
  e.start()
  local creditsBefore = creditsTo("alice") + creditsTo("bob")
  e.reset()
  t.eq(creditsTo("alice") + creditsTo("bob"), creditsBefore, "reset pays nobody -- it is not finish()")
  t.eq(e.pot, 0, "reset zeroes a LIVE pot -- the only call where finish() has not already done it")
  t.eq(e.phase, "lobby", "and it still returns to lobby")
end

t.done()
