-- wallet.lua — the station-side hub client. Wraps the ccvegas economy protocol with a
-- timeout and owns the PERSISTED CREDIT OUTBOX so a win is never lost when the hub is down.
-- Reuses the modem idle_runner already opened; it never opens rednet itself (except callers
-- like `issue` that open their own before calling mint). Pure queue helpers are unit-tested;
-- the rednet round-trips are verified in-world.
local M = {}
local PROTO   = "ccvegas"
local OUTBOX  = "ccvegas_outbox.tbl"
local TIMEOUT = 1.5   -- seconds to wait for a hub reply

-- ---- pure outbox helpers (unit-tested) -------------------------------------
function M._enqueue(list, id, delta)
  list[#list + 1] = { id = id, delta = delta }
  return list
end

-- remove the first entry matching id&delta; returns true if one was removed.
function M._drop(list, id, delta)
  for i = 1, #list do
    if list[i].id == id and list[i].delta == delta then
      table.remove(list, i)
      return true
    end
  end
  return false
end

-- classify a credit reply. "ok" = hub applied it; "deny" = hub refused (unknown id — retrying can
-- never succeed, so do NOT outbox); "queue" = no reply (hub down — outbox it, the win is not lost).
function M._creditResult(r)
  if r == nil then return "queue" end
  if r.kind == "credit_deny" then return "deny" end
  return "ok"
end

-- ---- outbox persistence (I/O) ----------------------------------------------
local function loadOutbox()
  if not fs.exists(OUTBOX) then return {} end
  local f = fs.open(OUTBOX, "r"); local d = f.readAll(); f.close()
  local ok, t = pcall(textutils.unserialize, d)
  return (ok and type(t) == "table") and t or {}
end

local function saveOutbox(list)
  local f = fs.open(OUTBOX, "w"); f.write(textutils.serialize(list)); f.close()
end

-- ---- hub round-trip (I/O) --------------------------------------------------
local unpack = table.unpack or unpack   -- Lua 5.1 (CraftOS) safety

-- rednet.lookup is ITSELF a blocking event pump, so cache the hub id and only look it up when we
-- don't have one (or after a timeout, in case the hub restarted with a new id). Keeps the hot path
-- (a mid-round balance refresh) from pumping — and eating — the caller's own events during lookup.
local hubId
local function getHub()
  if hubId == nil then hubId = rednet.lookup(PROTO, "hub") end
  return hubId
end

-- send msg to the hub, wait TIMEOUT for a reply whose .kind is in `kinds`. Returns the reply table
-- or nil (timeout). This runs its own os.pullEvent loop, so it necessarily consumes events meant for
-- the CALLER's loop — a `request` fired from inside slot.lua's tick loop (on a card insert) would
-- otherwise swallow the game's pending tick timer and FREEZE the machine. So every non-matching event
-- is STASHED and RE-QUEUED before returning: the caller's loop still receives its timer/presence/disk/key.
local function request(msg, kinds)
  local hub = getHub()
  if not hub then return nil end
  rednet.send(hub, msg, PROTO)
  local timer = os.startTimer(TIMEOUT)
  local stash, result = {}, nil
  while true do
    local ev = { os.pullEvent() }
    if ev[1] == "rednet_message" and ev[2] == hub and ev[4] == PROTO
       and type(ev[3]) == "table" and kinds[ev[3].kind] then
      result = ev[3]; break
    elseif ev[1] == "timer" and ev[2] == timer then
      result = nil; break                 -- our own timeout fired: treat as hub-unreachable
    else
      stash[#stash + 1] = ev              -- foreign event: hand it back to the caller's loop
    end
  end
  if result == nil then hubId = nil end   -- timed out: re-lookup next time (hub may have moved id)
  for _, e in ipairs(stash) do os.queueEvent(unpack(e)) end
  return result
end

function M.query(id)
  local r = request({ kind = "query", id = id }, { balance = true })
  return r and r.balance or nil
end

-- fail closed: deny or timeout both return a falsey ok so the caller does not spin for stakes.
function M.bet(id, stake)
  local r = request({ kind = "bet", id = id, stake = stake }, { bet_ok = true, bet_deny = true })
  if not r then return false, nil, "timeout" end
  if r.kind == "bet_ok" then return true, r.balance end
  return false, r.balance, r.reason
end

-- fail closed, exactly like bet. `bet` stays the slot's wager-round special case; `debit` is the
-- honest, game-agnostic withdrawal primitive (the cage today; mp_econ pots + the trading station next).
function M.debit(id, amount)
  local r = request({ kind = "debit", id = id, amount = amount },
                    { debit_ok = true, debit_deny = true })
  if not r then return false, nil, "timeout" end
  if r.kind == "debit_ok" then return true, r.balance end
  return false, r.balance, r.reason
end

-- guaranteed: on timeout the credit is queued to the outbox and returned false (win not lost).
-- An explicit credit_deny (unknown id) is NOT queued — it would retry forever. Returns
-- ok, balance, reason.
function M.credit(id, delta)
  local r = request({ kind = "credit", id = id, delta = delta },
                    { balance = true, credit_deny = true })
  local res = M._creditResult(r)
  if res == "ok"   then return true, r.balance end
  if res == "deny" then return false, nil, r.reason end
  local box = loadOutbox()
  M._enqueue(box, id, delta)
  saveOutbox(box)
  return false, nil, "queued"
end

-- try to bank every queued credit; drop each one the hub acks, keep the rest.
function M.flush()
  local box = loadOutbox()
  if #box == 0 then return end
  local i = 1
  while i <= #box do
    local item = box[i]
    local r = request({ kind = "credit", id = item.id, delta = item.delta },
                      { balance = true, credit_deny = true })
    local res = M._creditResult(r)
    if res == "ok" or res == "deny" then
      M._drop(box, item.id, item.delta)   -- acked (or unbankable): remove; list shrank, don't advance i
      saveOutbox(box)                      -- persist after EACH ack so an interruption mid-pass can
                                           -- never resend an already-credited win (double-credit guard)
    else
      i = i + 1                            -- still unreachable: keep it, move on
    end
  end
end

-- admin: mint a new ledger id. Returns id, or nil,reason ("exists" / "hub offline").
function M.mint(name, balance)
  local r = request({ kind = "mint", name = name, balance = balance }, { minted = true, mint_deny = true })
  if not r then return nil, "hub offline" end
  if r.kind == "minted" then return r.id end
  return nil, r.reason
end

return M
