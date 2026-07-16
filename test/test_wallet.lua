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

t.done()
