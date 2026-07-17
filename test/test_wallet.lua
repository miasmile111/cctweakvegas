package.path = "src/lib/?.lua;src/slot/?.lua;src/pong/?.lua;test/?.lua;" .. package.path
local t = require("runner")
local W = require("wallet")

-- _enqueue appends {id, delta}
do
  local box = {}
  W._enqueue(box, "Alice", 50)
  t.eq(#box, 1, "enqueue grows list")
  t.eq(box[1].id, "Alice", "enqueue stores id")
  t.eq(box[1].delta, 50, "enqueue stores delta")
  W._enqueue(box, "Bob", 30)
  t.eq(#box, 2, "enqueue appends")
end

-- _drop removes the first matching entry, returns true; miss returns false
do
  local box = {}
  W._enqueue(box, "Alice", 50)
  W._enqueue(box, "Bob", 30)
  t.ok(W._drop(box, "Alice", 50), "drop match -> true")
  t.eq(#box, 1, "drop shrinks list")
  t.eq(box[1].id, "Bob", "drop removed the right one")
  t.ok(not W._drop(box, "Nobody", 5), "drop miss -> false")
  t.eq(#box, 1, "drop miss leaves list unchanged")
end

-- _drop removes only ONE of duplicate entries
do
  local box = {}
  W._enqueue(box, "Cat", 10)
  W._enqueue(box, "Cat", 10)
  t.ok(W._drop(box, "Cat", 10), "drop duplicate -> true")
  t.eq(#box, 1, "drop removes only one duplicate")
end

-- ---- _creditResult: the F2 fix (unknown id must NOT read as acked) --------
t.eq(W._creditResult(nil), "queue", "no reply (hub down) -> outbox it")
t.eq(W._creditResult({ kind = "balance", id = "alice", balance = 240 }), "ok", "balance reply -> ok")
t.eq(W._creditResult({ kind = "credit_deny", id = "ghost", reason = "unknown" }), "deny",
     "credit_deny -> deny, never queued (retry can never succeed)")

-- ---- _wholeAmount: the only door to a permanent ledger write ----------------
-- `ledger.apply` is `t[id] = t[id] + delta` with NO validation, so whatever gets past here is what
-- the hub persists forever. Each refusal below is a real hazard, not hypothetical tidiness.
t.eq(W._wholeAmount("500"), 500, "a plain amount passes")
t.eq(W._wholeAmount("-50"), -50, "negatives pass (the caller routes them to debit)")
t.eq(W._wholeAmount("0"), 0, "zero parses (the CALLER rejects it, not this)")
t.eq(W._wholeAmount(" 500 "), 500, "tonumber's surrounding space is fine")
t.eq(W._wholeAmount("5e2"), 500, "exponent form is a whole number")
t.eq(W._wholeAmount("0x10"), 16, "hex is a whole number")

t.eq(W._wholeAmount("abc"), nil, "not a number -> refused")
t.eq(W._wholeAmount(""), nil, "empty -> refused")
t.eq(W._wholeAmount(nil), nil, "nil (missing arg) -> refused, never an error")
t.eq(W._wholeAmount("1.5"), nil,
     "fractional -> refused: ('%d'):format(1.5) SILENTLY prints '1', so the ledger and the screens "
     .. "would disagree forever")

-- THE one that nearly shipped. inf PASSES an integrality test (math.floor(inf) == inf), so without
-- an explicit finite check `issue add inf` sends delta=inf, the hub persists balance+inf = inf, and
-- that card is poisoned beyond repair — printing as -9223372036854775808.
t.eq(W._wholeAmount("inf"), nil, "inf -> refused (it would poison a balance PERMANENTLY)")
t.eq(W._wholeAmount("-inf"), nil, "-inf -> refused")
t.eq(W._wholeAmount("1e400"), nil, "an overflowing literal is inf too -> refused")
t.eq(W._wholeAmount("nan"), nil, "nan -> refused (do not rely on nan ~= nan doing it by accident)")
t.eq(W._wholeAmount("2e9"), nil, "past MAX_AMOUNT -> refused")
t.eq(W._wholeAmount("9007199254740993"), nil,
     "past 2^53 a double can't hold consecutive integers -> refused before it can drift")
t.eq(W._wholeAmount(tostring(W.MAX_AMOUNT)), W.MAX_AMOUNT, "MAX_AMOUNT itself is allowed")

-- ---- creditNow: the ADMIN credit — fails closed, NEVER outboxes -------------
-- `credit` is guaranteed because a player earned that win. `issue add` is different: it's a one-shot
-- admin program, nothing on an admin box ever calls flush(), so a queued credit would sit in the
-- outbox forever AND a re-run would double-credit if anything ever did flush it. These tests exist to
-- pin the "nothing enqueued" half — that is the entire reason the function exists.
local HUB, PROTO = 7, "ccvegas"
local queue, opened

-- the smallest fake CraftOS that `request()` needs. Fields are ADDED to the real `os` (never replace
-- it — runner.lua needs os.exit).
_G.rednet = { lookup = function() return HUB end, send = function() end }
os.startTimer = function() return 99 end
os.queueEvent = function() end
os.pullEvent  = function()
  local e = table.remove(queue, 1)
  if not e then error("test: pullEvent with an empty script", 0) end
  return unpack(e)
end
_G.textutils = { serialize = function() return "" end, unserialize = function() return {} end }
-- `opened` records every fs.open MODE, so a write to the outbox file cannot happen unnoticed
_G.fs = {
  exists = function() return false end,
  open   = function(path, mode)
    opened[#opened + 1] = mode .. ":" .. path
    return { write = function() end, close = function() end, readAll = function() return "" end }
  end,
}

local function scripted(events)
  queue, opened = events, {}
end
local function wroteOutbox()
  for i = 1, #opened do if opened[i]:find("^w:") then return true end end
  return false
end

-- hub applies it
do
  scripted{ { "rednet_message", HUB, { kind = "balance", id = "alice", balance = 600 }, PROTO } }
  local ok, bal, reason = W.creditNow("alice", 500)
  t.ok(ok, "creditNow: hub acked -> ok")
  t.eq(bal, 600, "creditNow returns the hub's new balance")
  t.eq(reason, nil, "no reason on success")
  t.ok(not wroteOutbox(), "a successful creditNow never touches the outbox")
end

-- hub is unreachable: HARD failure, and nothing queued. This is the whole point.
do
  scripted{ { "timer", 99 } }                       -- our own TIMEOUT fires: no reply
  local ok, bal, reason = W.creditNow("alice", 500)
  t.ok(not ok, "creditNow: hub offline -> fails CLOSED (never 'queued')")
  t.eq(reason, "timeout", "and says so plainly, so the caller can promise a re-run is safe")
  t.eq(bal, nil, "no balance to report")
  t.ok(not wroteOutbox(), "NOTHING is enqueued on timeout -- re-running must not double-credit")
end

-- unknown id: terminal deny, also never queued
do
  scripted{ { "rednet_message", HUB, { kind = "credit_deny", id = "ghost", reason = "unknown" }, PROTO } }
  local ok, _, reason = W.creditNow("ghost", 500)
  t.ok(not ok, "creditNow: unknown id -> deny")
  t.eq(reason, "unknown", "reason passed through, so issue can say the card is stale")
  t.ok(not wroteOutbox(), "a denied creditNow never touches the outbox")
end

-- ...and the GUARANTEE that games depend on is untouched: credit STILL outboxes on timeout
do
  scripted{ { "timer", 99 } }
  local ok, _, reason = W.credit("alice", 500)
  t.ok(not ok, "credit: hub offline -> not ok")
  t.eq(reason, "queued", "credit still QUEUES -- a win is never lost")
  t.ok(wroteOutbox(), "credit still persists the outbox (creditNow did not break the guarantee)")
end

-- ---- _pumpSafe: the floppy-swap freeze ------------------------------------
-- rednet.lookup pulls with a bare os.pullEvent() and DISCARDS what it doesn't recognise, so a
-- lookup fired from inside slot.lua's tick loop eats the game's timer and the machine freezes.
-- _pumpSafe drives such a function and hands every foreign event back. See
-- docs/superpowers/specs/2026-07-17-hub-lookup-pump-freeze-design.md

-- install a fake CraftOS event queue; returns a restore fn
local function fakeOS(incoming)
  local realPull, realQueue = os.pullEvent, os.queueEvent
  local queued = {}
  local i = 0
  -- Model CraftOS faithfully: os.pullEvent YIELDS when called inside a coroutine (that is the whole
  -- mechanism _pumpSafe stands on). Only the driver, on the main thread, pops a canned event.
  os.pullEvent = function()
    if coroutine.running() then return coroutine.yield() end
    i = i + 1
    if not incoming[i] then error("fake event queue exhausted", 0) end
    return unpack(incoming[i])
  end
  os.queueEvent = function(...) queued[#queued + 1] = { ... } end
  return function() os.pullEvent, os.queueEvent = realPull, realQueue end, queued
end

-- A faithful stand-in for rednet.lookup: pulls with no filter and discards everything that is not
-- its own dns reply -- exactly the loop in rom/apis/rednet.lua that causes the freeze.
local function dnsLookup()
  return function()
    while true do
      local ev = { os.pullEvent() }
      if ev[1] == "rednet_message" and ev[4] == "dns" then return "found" end
    end
  end
end

-- 1. THE FREEZE, REPRODUCED: a foreign timer swallowed by the inner fn must come back out
do
  local restore, queued = fakeOS({ { "timer", 42 }, { "rednet_message", 3, {}, "dns" } })
  local r = W._pumpSafe(dnsLookup())
  restore()
  t.eq(r, "found", "_pumpSafe returns the inner fn's value")
  t.eq(#queued, 1, "_pumpSafe re-queues the foreign timer the inner fn discarded")
  t.eq(queued[1][1], "timer", "re-queued event is the timer")
  t.eq(queued[1][2], 42, "re-queued timer keeps its id")
end

-- 2. foreign events come back in arrival order
do
  local restore, queued = fakeOS({
    { "timer", 1 }, { "disk", "left" }, { "monitor_touch", "m", 2, 3 },
    { "rednet_message", 3, {}, "dns" },
  })
  W._pumpSafe(dnsLookup())
  restore()
  t.eq(#queued, 3, "all three foreign events handed back")
  t.eq(queued[1][1], "timer", "order preserved: timer first")
  t.eq(queued[2][1], "disk", "order preserved: disk second")
  t.eq(queued[3][1], "monitor_touch", "order preserved: touch third")
end

-- 3. the coroutine's OWN dns traffic is not handed back (nothing else in the repo speaks dns)
do
  local restore, queued = fakeOS({ { "rednet_message", 3, {}, "dns" } })
  W._pumpSafe(dnsLookup())
  restore()
  t.eq(#queued, 0, "dns messages are the lookup's own business, not re-queued")
end

-- 4. a non-dns rednet_message IS foreign and must be handed back. This is the one that matters for
-- the economy: an in-flight ccvegas reply must not be eaten by a lookup racing alongside it.
do
  local restore, queued = fakeOS({ { "rednet_message", 3, {}, "ccvegas" }, { "rednet_message", 3, {}, "dns" } })
  W._pumpSafe(dnsLookup())
  restore()
  t.eq(#queued, 1, "a ccvegas message is foreign to the lookup")
  t.eq(queued[1][4], "ccvegas", "re-queued with its protocol intact")
end

-- 5. an inner fn that returns immediately pumps nothing
do
  local restore, queued = fakeOS({})
  local r = W._pumpSafe(function() return "instant" end)
  restore()
  t.eq(r, "instant", "no-pump fn returns straight through")
  t.eq(#queued, 0, "nothing queued when nothing was pulled")
end

-- 6. nil return (lookup found no hub) survives the round trip
do
  local restore = fakeOS({ { "timer", 1 } })
  local r = W._pumpSafe(function() os.pullEvent(); return nil end)
  restore()
  t.eq(r, nil, "_pumpSafe passes a nil return through (hub not found)")
end

-- 7. args are forwarded to the inner fn
do
  local restore = fakeOS({})
  local got
  W._pumpSafe(function(a, b) got = a .. b end, "cc", "vegas")
  restore()
  t.eq(got, "ccvegas", "_pumpSafe forwards its varargs")
end

-- 8. an error inside the coroutine propagates instead of hanging
do
  local restore = fakeOS({})
  local ok = pcall(W._pumpSafe, function() error("boom", 0) end)
  restore()
  t.ok(not ok, "_pumpSafe propagates an error raised inside the coroutine")
end

t.done()
