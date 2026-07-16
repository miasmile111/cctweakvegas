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
-- send msg to the hub, wait TIMEOUT for a reply whose .kind is in `kinds`. Returns the reply
-- table or nil. NOTE: this is a BLOCKING event pump — it runs its own os.pullEvent loop and
-- DISCARDS every non-matching event (presence, disk, key) pulled during the wait. Cheap while the
-- hub is up (<50ms round-trip); on a hub-down bet it blocks ~TIMEOUT and drops those events for that
-- window (presence/card state resync on the next event; a swallowed Q is briefly unresponsive).
local function request(msg, kinds)
  local hub = rednet.lookup(PROTO, "hub")
  if not hub then return nil end
  rednet.send(hub, msg, PROTO)
  local timer = os.startTimer(TIMEOUT)
  while true do
    local ev = { os.pullEvent() }
    if ev[1] == "rednet_message" and ev[2] == hub and ev[4] == PROTO
       and type(ev[3]) == "table" and kinds[ev[3].kind] then
      return ev[3]
    elseif ev[1] == "timer" and ev[2] == timer then
      return nil
    end
  end
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

-- guaranteed: on timeout the credit is queued to the outbox and returned false (win not lost).
function M.credit(id, delta)
  local r = request({ kind = "credit", id = id, delta = delta }, { balance = true })
  if r then return true, r.balance end
  local box = loadOutbox()
  M._enqueue(box, id, delta)
  saveOutbox(box)
  return false
end

-- try to bank every queued credit; drop each one the hub acks, keep the rest.
function M.flush()
  local box = loadOutbox()
  if #box == 0 then return end
  local i = 1
  while i <= #box do
    local item = box[i]
    local r = request({ kind = "credit", id = item.id, delta = item.delta }, { balance = true })
    if r then
      M._drop(box, item.id, item.delta)   -- acked: remove; list shrank, don't advance i
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
