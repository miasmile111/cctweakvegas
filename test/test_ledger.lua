package.path = "src/lib/?.lua;src/slot/?.lua;src/pong/?.lua;test/?.lua;" .. package.path
local t = require("runner")
local L = require("ledger")

-- mint
do
  local s = {}
  t.eq(L.mint(s, "Alice", 100), "Alice", "mint returns id")
  t.eq(s.Alice, 100, "mint sets balance")
  local id, err = L.mint(s, "Alice", 50)
  t.eq(id, nil, "mint duplicate -> nil")
  t.eq(err, "exists", "mint duplicate -> reason exists")
  t.eq(s.Alice, 100, "mint duplicate leaves balance untouched")
end

-- balance
do
  local s = { Bob = 42 }
  t.eq(L.balance(s, "Bob"), 42, "balance known")
  t.eq(L.balance(s, "Nobody"), nil, "balance unknown -> nil")
end

-- apply
do
  local s = { Cat = 10 }
  t.eq(L.apply(s, "Cat", 5), 15, "apply positive")
  t.eq(L.apply(s, "Cat", -8), 7, "apply negative")
  t.eq(s.Cat, 7, "apply mutates table")
  t.eq(L.apply(s, "Ghost", 5), nil, "apply unknown -> nil")
end

-- debit
do
  local s = { Dan = 30 }
  local ok, bal = L.debit(s, "Dan", 10)
  t.ok(ok, "debit funded -> true")
  t.eq(bal, 20, "debit funded -> new balance")
  t.eq(s.Dan, 20, "debit funded mutates")
  local ok2, bal2 = L.debit(s, "Dan", 999)
  t.ok(not ok2, "debit short -> false")
  t.eq(bal2, 20, "debit short -> current balance")
  t.eq(s.Dan, 20, "debit short leaves balance unchanged")
  local ok3, bal3 = L.debit(s, "Ghost", 5)
  t.ok(not ok3, "debit unknown -> false")
  t.eq(bal3, nil, "debit unknown -> nil balance")
  -- exact-funds boundary
  local s2 = { Eve = 10 }
  local okE, balE = L.debit(s2, "Eve", 10)
  t.ok(okE, "debit exact funds -> true")
  t.eq(balE, 0, "debit exact funds -> 0")
end

t.done()
