-- ledger.lua — pure hub-side score ledger. No CC APIs (unit-tested under luajit).
-- The ledger table is { id -> score }. Every function takes it explicitly; the hub owns
-- load/persist. `id` is the player's chosen name (README: cards key on a chosen name;
-- close-friends trust model, no anti-cheat).
local M = {}

-- create id=name with starting balance. Returns id, or nil,"exists" on a duplicate name.
function M.mint(t, name, balance)
  if t[name] ~= nil then return nil, "exists" end
  t[name] = balance
  return name
end

-- returns score for id, or nil if unknown.
function M.balance(t, id)
  return t[id]
end

-- add delta (may be negative). Returns new balance, or nil for an unknown id.
function M.apply(t, id, delta)
  if t[id] == nil then return nil end
  t[id] = t[id] + delta
  return t[id]
end

-- if balance >= stake: subtract, return true,newBalance. Else false,balance (no change).
-- unknown id -> false,nil.
function M.debit(t, id, stake)
  local bal = t[id]
  if bal == nil then return false, nil end
  if bal >= stake then
    t[id] = bal - stake
    return true, t[id]
  end
  return false, bal
end

return M
