# Hub Economy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the hub a canonical `id → score` ledger and make the slot a bet-and-risk gamble — a pull debits a stake, a win pays a per-symbol paytable (triple-seven jackpot) — all through a shared economy gateway thin games plug into.

**Architecture:** Three layers. **Core** (`ledger.lua` on the hub; `card.lua` + `wallet.lua` on stations) is single/multiplayer-agnostic. A **single-player gateway** (`sp_econ.lua`) composes card + wallet into a bet-gate/settle API. **Games** supply only a tiny payout module (`slot_pay.lua`) and call the gateway from their existing `idle_runner` `play()` loop. `idle_runner` is untouched.

**Tech Stack:** CC:Tweaked / CraftOS Lua 5.1 (in-game), luajit (local unit tests), rednet protocol `ccvegas`, floppy disks as membership cards.

## Global Constraints

- Lua 5.1 only; CraftOS APIs in-game, no external libs. Pure logic modules use **no CC globals** so they run under luajit.
- One program per file; **filename = in-game program name**; deploy flattens by `name`, so `require("<name>")` never encodes a folder. New shared modules live in `src/lib/`.
- Rednet protocol constant is `"ccvegas"`; the hub is reached via `rednet.lookup("ccvegas", "hub")`. Stations **must not** re-open the modem — `idle_runner` already `rednet.open`s it before `play()`. `issue` is standalone and opens its own modem.
- Card file on a floppy: `/<mount>/ccvegas_card` = `textutils.serialize{ id=<string>, score=<number> }`. `score` is a **display mirror**; the hub is authoritative.
- Approved payout numbers (tunable): stake **10**; triple cherry **3×**, bell **5×**, bar **8×**, seven **25×** (jackpot). Symbol indices: **1=seven, 2=cherry, 3=bell, 4=bar**.
- Unit tests run with `luajit test/test_xxx.lua`; first line sets `package.path = "src/lib/?.lua;src/slot/?.lua;src/pong/?.lua;test/?.lua;" .. package.path`. Syntax check I/O modules with `luajit -bl <file> > /dev/null` (parses without running; CC globals are fine).
- Commit after every task. No `--no-verify`.

---

### Task 1: `ledger.lua` — pure hub-side score ledger

**Files:**
- Create: `src/lib/ledger.lua`
- Test: `test/test_ledger.lua`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `ledger.mint(t, name, balance) → id | nil,"exists"` (creates `t[name]=balance`; rejects duplicate)
  - `ledger.balance(t, id) → score | nil`
  - `ledger.apply(t, id, delta) → newBalance | nil` (unknown id → nil)
  - `ledger.debit(t, id, stake) → true,newBalance | false,balance` (unknown → `false,nil`; short → `false,balance` no change)

- [ ] **Step 1: Write the failing test**

Create `test/test_ledger.lua`:
```lua
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `luajit test/test_ledger.lua`
Expected: FAIL — `module 'ledger' not found` (or nil index).

- [ ] **Step 3: Write minimal implementation**

Create `src/lib/ledger.lua`:
```lua
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `luajit test/test_ledger.lua`
Expected: PASS — `N passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add src/lib/ledger.lua test/test_ledger.lua
git commit -m "feat(ledger): pure hub score ledger (mint/balance/apply/debit)"
```

---

### Task 2: `slot_pay.lua` — the slot's payout module

**Files:**
- Create: `src/slot/slot_pay.lua`
- Test: `test/test_slot_pay.lua`

**Interfaces:**
- Consumes: nothing.
- Produces: a module table `{ STAKE = 10, eval = function(result) → payout:int }` where `result` is a 3-element array of symbol indices (1=seven,2=cherry,3=bell,4=bar). Non-triple → 0.

- [ ] **Step 1: Write the failing test**

Create `test/test_slot_pay.lua`:
```lua
package.path = "src/lib/?.lua;src/slot/?.lua;src/pong/?.lua;test/?.lua;" .. package.path
local t = require("runner")
local P = require("slot_pay")

t.eq(P.STAKE, 10, "stake is 10")

t.eq(P.eval({ 2, 3, 4 }), 0, "no triple -> 0")
t.eq(P.eval({ 1, 1, 2 }), 0, "two of a kind -> 0")

t.eq(P.eval({ 2, 2, 2 }), 30, "triple cherry -> stake*3")
t.eq(P.eval({ 3, 3, 3 }), 50, "triple bell -> stake*5")
t.eq(P.eval({ 4, 4, 4 }), 80, "triple bar -> stake*8")
t.eq(P.eval({ 1, 1, 1 }), 250, "triple seven -> jackpot stake*25")

t.done()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `luajit test/test_slot_pay.lua`
Expected: FAIL — `module 'slot_pay' not found`.

- [ ] **Step 3: Write minimal implementation**

Create `src/slot/slot_pay.lua`:
```lua
-- slot_pay.lua — the slot's payout script (pure; unit-tested). The single tiny per-game
-- piece the economy gateway needs: a fixed STAKE and eval(result) -> payout.
-- result = { r1, r2, r3 } symbol indices: 1=seven 2=cherry 3=bell 4=bar.
local STAKE = 10
local MULT  = { [1] = 25, [2] = 3, [3] = 5, [4] = 8 }   -- seven(jackpot) cherry bell bar

return {
  STAKE = STAKE,
  eval = function(result)
    local a, b, c = result[1], result[2], result[3]
    if not (a == b and b == c) then return 0 end
    return STAKE * (MULT[a] or 0)
  end,
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `luajit test/test_slot_pay.lua`
Expected: PASS — `N passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add src/slot/slot_pay.lua test/test_slot_pay.lua
git commit -m "feat(slot): slot_pay payout module (per-symbol paytable, seven jackpot)"
```

---

### Task 3: `wallet.lua` — station hub client + persisted credit outbox

The pure outbox helpers are unit-tested; the rednet I/O (`query`/`bet`/`credit`/`flush`/`mint`) is syntax-checked here and verified in-world in Task 8.

**Files:**
- Create: `src/lib/wallet.lua`
- Test: `test/test_wallet.lua`

**Interfaces:**
- Consumes: rednet (in-game), the hub's protocol from the spec.
- Produces:
  - `wallet._enqueue(list, id, delta) → list` (appends `{id,delta}`)
  - `wallet._drop(list, id, delta) → bool` (removes first match; returns whether one was removed)
  - `wallet.query(id) → balance | nil`
  - `wallet.bet(id, stake) → true,balance | false,balance,reason` (timeout → `false,nil,"timeout"`, fail closed)
  - `wallet.credit(id, delta) → true,balance | false` (timeout → enqueue to outbox, returns `false`)
  - `wallet.flush()` (sends every queued credit the hub acks; keeps the rest)
  - `wallet.mint(name, balance) → id | nil,reason` (used by `issue`)

- [ ] **Step 1: Write the failing test (pure helpers only)**

Create `test/test_wallet.lua`:
```lua
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

t.done()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `luajit test/test_wallet.lua`
Expected: FAIL — `module 'wallet' not found`.

- [ ] **Step 3: Write the implementation (pure helpers + I/O)**

Create `src/lib/wallet.lua`:
```lua
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
-- table or nil. NOTE: pumps os events during the wait (brief, on bet/credit only).
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
    if r then M._drop(box, item.id, item.delta)  -- acked: remove; list shrank, don't advance i
    else i = i + 1                                -- still unreachable: keep it, move on
    end
  end
  saveOutbox(box)
end

-- admin: mint a new ledger id. Returns id, or nil,reason ("exists" / "hub offline").
function M.mint(name, balance)
  local r = request({ kind = "mint", name = name, balance = balance }, { minted = true, mint_deny = true })
  if not r then return nil, "hub offline" end
  if r.kind == "minted" then return r.id end
  return nil, r.reason
end

return M
```

- [ ] **Step 4: Run test to verify it passes**

Run: `luajit test/test_wallet.lua`
Expected: PASS — `N passed, 0 failed`.

- [ ] **Step 5: Syntax-check the whole file (I/O code parses)**

Run: `luajit -bl src/lib/wallet.lua > /dev/null && echo OK`
Expected: `OK` (bytecode dump discarded; CC globals like `fs`/`rednet` are unresolved names, which is fine — the file only needs to parse).

- [ ] **Step 6: Commit**

```bash
git add src/lib/wallet.lua test/test_wallet.lua
git commit -m "feat(wallet): station hub client + persisted credit outbox"
```

---

### Task 4: `card.lua` — membership floppy read/write

I/O module (CC `peripheral`/`fs`/`disk`); no luajit unit test — syntax-checked here, exercised in-world in Task 8.

**Files:**
- Create: `src/lib/card.lua`

**Interfaces:**
- Consumes: `peripheral`, `fs`, `textutils`, `disk` events.
- Produces:
  - `card.read() → { id=<string>, score=<number> } | nil`
  - `card.write(id, score) → true | false,reason`
  - `card.writeMirror(score) → true | false,reason` (id preserved)
  - `card.isCardEvent(ev) → bool` (true for `disk` / `disk_eject`)

- [ ] **Step 1: Write the implementation**

Create `src/lib/card.lua`:
```lua
-- card.lua — membership floppy read/write. A card = a mounted disk holding the file
-- /<mount>/ccvegas_card = serialize{ id=<string>, score=<number> }. No file => anonymous.
-- `score` is a display mirror only; the hub is authoritative (see wallet + hub).
local M = {}
local FILE = "ccvegas_card"

-- find a disk drive with a disk in it; return its mount path (e.g. "/disk") or nil.
local function mountPath()
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "drive" then
      local d = peripheral.wrap(name)
      if d.isDiskPresent() and d.getMountPath() then
        return d.getMountPath()
      end
    end
  end
  return nil
end

-- read the card in the drive; returns { id, score } or nil (no disk / blank / unreadable).
function M.read()
  local mp = mountPath(); if not mp then return nil end
  local path = mp .. "/" .. FILE
  if not fs.exists(path) then return nil end
  local f = fs.open(path, "r"); local d = f.readAll(); f.close()
  local ok, t = pcall(textutils.unserialize, d)
  if ok and type(t) == "table" and type(t.id) == "string" then
    return { id = t.id, score = t.score }
  end
  return nil
end

-- write id + score to the card in the drive. Returns true, or false,reason.
function M.write(id, score)
  local mp = mountPath(); if not mp then return false, "no disk" end
  local f = fs.open(mp .. "/" .. FILE, "w")
  if not f then return false, "cannot open" end
  f.write(textutils.serialize({ id = id, score = score })); f.close()
  return true
end

-- update just the score mirror on the current card (id preserved). Best-effort.
function M.writeMirror(score)
  local c = M.read(); if not c then return false, "no card" end
  return M.write(c.id, score)
end

-- true for events that change disk state, so a play loop knows to re-read the card.
function M.isCardEvent(ev)
  return type(ev) == "table" and (ev[1] == "disk" or ev[1] == "disk_eject")
end

return M
```

- [ ] **Step 2: Syntax-check**

Run: `luajit -bl src/lib/card.lua > /dev/null && echo OK`
Expected: `OK`.

- [ ] **Step 3: Commit**

```bash
git add src/lib/card.lua
git commit -m "feat(card): membership floppy read/write (ccvegas_card, score mirror)"
```

---

### Task 5: Hub ledger store + protocol handlers

Extend the always-on hub with a second persisted store and the `bet`/`credit`/`query`/`mint` handlers, and add `ledger` to the hub package. Logic is already covered by Task 1's tests; this wires it to rednet. Verified in-world in Task 8.

**Files:**
- Modify: `src/hub/hub.lua`
- Modify: `src/packages.lua`

**Interfaces:**
- Consumes: `ledger` (Task 1) — `mint/balance/apply/debit`.
- Produces: hub replies per spec — `bet_ok{id,balance}` / `bet_deny{id,balance,reason}` / `balance{id,balance}` / `minted{id}` / `mint_deny{reason}`.

- [ ] **Step 1: Add the ledger store (load + persist) after the registry block**

In `src/hub/hub.lua`, immediately after the `persist()` function for the registry (the `local function persist() ... end` block ending at the line with `end` before `local function assign`), add:
```lua
-- ---- score ledger (the economy) --------------------------------------------
local ledger      = require("ledger")
local LEDGER_STORE = "ledger.tbl"
local scores = {}
if fs.exists(LEDGER_STORE) then
  local f = fs.open(LEDGER_STORE, "r"); local d = f.readAll(); f.close()
  local ok, t = pcall(textutils.unserialize, d)
  if ok and type(t) == "table" then scores = t end
end
local function persistLedger()
  local f = fs.open(LEDGER_STORE, "w"); f.write(textutils.serialize(scores)); f.close()
end
```

- [ ] **Step 2: Add the economy handlers to the registrar loop**

In `src/hub/hub.lua`, in `local function registrar()`, the loop currently has a `register` branch then an `elseif idle.isPresenceQuery(msg)` branch. Insert these four `elseif` branches **between** the register branch and the `elseif idle.isPresenceQuery(msg)` branch:
```lua
    elseif type(msg) == "table" and msg.kind == "mint" and type(msg.name) == "string" then
      local id, err = ledger.mint(scores, msg.name, tonumber(msg.balance) or 0)
      if id then
        persistLedger()
        rednet.send(sender, { kind = "minted", id = id }, PROTO)
        print(("  mint %s = %d"):format(id, scores[id]))
      else
        rednet.send(sender, { kind = "mint_deny", reason = err }, PROTO)
      end
    elseif type(msg) == "table" and msg.kind == "bet"
           and type(msg.id) == "string" and type(msg.stake) == "number" then
      local ok, bal = ledger.debit(scores, msg.id, msg.stake)
      if ok then
        persistLedger()
        rednet.send(sender, { kind = "bet_ok", id = msg.id, balance = bal }, PROTO)
      else
        rednet.send(sender, { kind = "bet_deny", id = msg.id, balance = bal,
                              reason = (bal == nil) and "unknown" or "insufficient" }, PROTO)
      end
    elseif type(msg) == "table" and msg.kind == "credit"
           and type(msg.id) == "string" and type(msg.delta) == "number" then
      local bal = ledger.apply(scores, msg.id, msg.delta)
      if bal then persistLedger() end
      rednet.send(sender, { kind = "balance", id = msg.id, balance = bal }, PROTO)
    elseif type(msg) == "table" and msg.kind == "query" and type(msg.id) == "string" then
      rednet.send(sender, { kind = "balance", id = msg.id, balance = ledger.balance(scores, msg.id) }, PROTO)
```

- [ ] **Step 3: Add `ledger` to the hub package**

In `src/packages.lua`, in the `hub` entry's `files` list, add before the `{ name = "hub", ... }` line:
```lua
      { name = "ledger",     path = "lib/ledger.lua" },
```
So `hub.files` reads:
```lua
  hub = {
    station = false,
    files = {
      { name = "idle_logic", path = "lib/idle_logic.lua" },
      { name = "ledger",     path = "lib/ledger.lua" },
      { name = "hub",        path = "hub/hub.lua" },
    },
  },
```

- [ ] **Step 4: Syntax-check the hub**

Run: `luajit -bl src/hub/hub.lua > /dev/null && echo OK`
Expected: `OK`.

- [ ] **Step 5: Commit**

```bash
git add src/hub/hub.lua src/packages.lua
git commit -m "feat(hub): score ledger store + bet/credit/query/mint handlers"
```

---

### Task 6: `issue.lua` — admin card-mint program

**Files:**
- Create: `src/issue.lua`
- Modify: `src/packages.lua`

**Interfaces:**
- Consumes: `wallet.mint` (Task 3), `card.write` (Task 4).
- Produces: an `issue <name> [balance]` program (standalone; opens its own modem).

- [ ] **Step 1: Write the program**

Create `src/issue.lua`:
```lua
-- issue.lua — admin: mint a membership card. Run on the hub box (advanced computer: a second
-- multishell tab) or any computer with a disk drive + modem wired to the hub network.
--   issue <name> [balance]     (balance defaults to 100)
-- Asks the hub to mint the id, then writes { id, score } onto a blank floppy in the drive.
-- Standalone (not under idle_runner), so it opens its own modem.
local card   = require("card")
local wallet = require("wallet")

local args    = { ... }
local name    = args[1]
local balance = tonumber(args[2]) or 100
if not name then
  print("usage: issue <name> [balance]")
  return
end

local m = peripheral.find("modem", function(_, mm) return not mm.isWireless() end)
         or peripheral.find("modem")
if not m then
  print("issue needs a MODEM wired to the hub network.")
  return
end
rednet.open(peripheral.getName(m))

local id, err = wallet.mint(name, balance)
if not id then
  print("MINT FAILED: " .. tostring(err))
  if err == "exists" then print(("The ledger already has a '%s'."):format(name)) end
  return
end

local ok, werr = card.write(id, balance)
if not ok then
  print(("Ledger minted '%s' = %d, but writing the CARD failed: %s"):format(id, balance, tostring(werr)))
  print("Put a blank floppy in the drive; the ledger entry already exists, so re-mint is not needed —")
  print("write it manually or issue under a new name.")
  return
end
print(("Issued card '%s' with balance %d."):format(id, balance))
```

- [ ] **Step 2: Add the `issue` package**

In `src/packages.lua`, add a new top-level entry (after the `hub` entry, before the closing `}`):
```lua
  -- Admin tool, not a player station.
  issue = {
    station = false,
    files = {
      { name = "card",   path = "lib/card.lua" },
      { name = "wallet", path = "lib/wallet.lua" },
      { name = "issue",  path = "issue.lua" },
    },
  },
```

- [ ] **Step 3: Syntax-check**

Run: `luajit -bl src/issue.lua > /dev/null && echo OK`
Expected: `OK`.

- [ ] **Step 4: Commit**

```bash
git add src/issue.lua src/packages.lua
git commit -m "feat(issue): admin card-mint program (hub mint + floppy write)"
```

---

### Task 7: `sp_econ.lua` — single-player economy gateway

Composes `card` + `wallet` into the bet-gate / settle API a game drives. I/O module; syntax-checked here, exercised in-world in Task 8.

**Files:**
- Create: `src/lib/sp_econ.lua`

**Interfaces:**
- Consumes: `card` (Task 4), `wallet` (Task 3), a payout module `cfg.pay = { STAKE, eval }` (Task 2).
- Produces: `sp_econ.new{ zone, pay } → econ` with:
  - `econ.onEvent(ev)` — fold a raw os event (re-reads card on `disk`/`disk_eject`)
  - `econ.tryBet() → "staked" | "free" | "deny"`
  - `econ.settle(result) → payoutPaid:int`
  - `econ.status() → { player, balance, stake, lastWin, denied }`
  - `sp_econ.drawHeader(mon, status)` — default plain-text header (games may render their own)

- [ ] **Step 1: Write the implementation**

Create `src/lib/sp_econ.lua`:
```lua
-- sp_econ.lua — single-player economy gateway. Composes card + wallet into the bet-gate,
-- settle/credit, and card lifecycle a game drives from its play() loop. Owns economy STATE;
-- the game renders it (status()). Reuses the modem idle_runner already opened; never opens
-- rednet itself. A future mp_econ.lua sits beside this on the same card/wallet core.
local card   = require("card")
local wallet = require("wallet")

local M = {}

-- cfg.pay = { STAKE = <int>, eval = function(result) -> payout:int }
-- cfg.zone is accepted for symmetry with the station's zone (unused today; MP will use it).
function M.new(cfg)
  local self = {
    pay     = cfg.pay,
    player  = nil,   -- id string, or nil (anonymous)
    balance = nil,   -- last known hub balance for player
    lastWin = 0,
    denied  = false,
    round   = nil,   -- "staked" | "free" | nil : current round's bet outcome
  }

  wallet.flush()     -- bank any wins queued while the hub was down, on entry

  local function refreshCard()
    self.denied = false
    local c = card.read()
    if c then
      self.player = c.id
      local b = wallet.query(c.id)      -- hub is truth; fall back to the card mirror if offline
      self.balance = b or c.score
      if b then card.writeMirror(b) end
    else
      self.player, self.balance = nil, nil
    end
  end
  refreshCard()

  -- fold a raw os event into state. Call for EVERY event in the play loop.
  function self.onEvent(ev)
    if card.isCardEvent(ev) then refreshCard() end
  end

  -- called on the arm edge. "staked" = stake debited, run the round for real;
  -- "free" = anonymous, run the round but it pays nothing; "deny" = insufficient/offline, do NOT run.
  function self.tryBet()
    self.denied = false
    if not self.player then self.round = "free"; return "free" end
    local ok, bal = wallet.bet(self.player, self.pay.STAKE)
    if ok then
      self.balance = bal; card.writeMirror(bal)
      self.round = "staked"; return "staked"
    end
    if bal ~= nil then self.balance = bal end   -- deny reply carries current balance
    self.denied = true; self.round = nil
    return "deny"
  end

  -- called at round resolution. Credits a win for a staked round; returns the payout paid (0 else).
  function self.settle(result)
    local won = 0
    if self.round == "staked" then
      local payout = self.pay.eval(result)
      if payout > 0 then
        local ok, bal = wallet.credit(self.player, payout)
        if ok and bal then
          self.balance = bal; card.writeMirror(bal)
        else
          self.balance = (self.balance or 0) + payout   -- queued to outbox; reflect locally
        end
        won = payout
      end
    end
    self.lastWin = won
    self.round = nil
    return won
  end

  function self.status()
    return {
      player  = self.player,
      balance = self.balance,
      stake   = self.pay.STAKE,
      lastWin = self.lastWin,
      denied  = self.denied,
    }
  end

  return self
end

-- default plain-text header for games that don't render their own.
function M.drawHeader(mon, s)
  mon.setCursorPos(1, 1)
  if s.denied then
    mon.write("INSUFFICIENT")
  elseif s.player then
    mon.write(("%s  $%d  stake %d"):format(s.player, s.balance or 0, s.stake))
  else
    mon.write("FREE PLAY - insert card to bet")
  end
end

return M
```

- [ ] **Step 2: Syntax-check**

Run: `luajit -bl src/lib/sp_econ.lua > /dev/null && echo OK`
Expected: `OK`.

- [ ] **Step 3: Commit**

```bash
git add src/lib/sp_econ.lua
git commit -m "feat(sp_econ): single-player economy gateway (bet-gate/settle/status)"
```

---

### Task 8: Wire the economy into `slot.lua`

Add the gateway to the slot's `play()` loop: bet-gate the lever, settle at the result, forward disk events, and draw the balance header. Add the new files to the slot package.

**Files:**
- Modify: `src/slot/slot.lua`
- Modify: `src/packages.lua`

**Interfaces:**
- Consumes: `sp_econ.new` (Task 7), `slot_pay` (Task 2).
- Produces: a slot station that bets/pays through the hub ledger.

- [ ] **Step 1: Give `drawTopFrame` an economy header**

In `src/slot/slot.lua`, change `drawTopFrame` (currently `local function drawTopFrame(reels, bulbTick, result, attract)`) to accept a `status` argument and draw the header while the window is hidden. Replace the function with:
```lua
local function drawTopFrame(reels, bulbTick, result, attract, status)
  topWin.setVisible(false)
  drawTop(topCv, reels, bulbTick, result)
  -- economy header in the reserved top rows (plain text over the gradient)
  if status then
    topWin.setTextColor(WHITE); topWin.setBackgroundColor(BLACK)
    topWin.setCursorPos(1, 1)
    if status.denied then
      topWin.write("INSUFFICIENT")
    elseif status.player then
      topWin.write(("%s $%d"):format(status.player, status.balance or 0))
      topWin.setCursorPos(1, 2); topWin.write(("stake %d  win %d"):format(status.stake, status.lastWin))
    else
      topWin.setCursorPos(1, 1); topWin.write("FREE PLAY")
      topWin.setCursorPos(1, 2); topWin.write("insert card to bet")
    end
  end
  if result == "win" or result == "lose" then
    local label = (result == "win") and "WIN!" or "LOSE"
    topWin.setTextColor(WHITE)
    topWin.setBackgroundColor(result == "win" and GREEN or RED)
    topWin.setCursorPos(math.floor((tw - #label) / 2) + 1, th)
    topWin.write(label)
  end
  topWin.setVisible(true)
end
```

- [ ] **Step 2: Build the gateway at the top of `play()`**

In `src/slot/slot.lua`, in `local function play(mon, pres)`, immediately after the line `local state = "attract"`, add:
```lua
  local econ = require("sp_econ").new{ zone = ZONE, pay = require("slot_pay") }
```

- [ ] **Step 3: Bet-gate the lever pull**

In `play()`, replace the arm-edge block:
```lua
      if state == "attract" and armed and lvl >= SPIN_LEVEL then
        reels = newSpin()
        state, spinTick, armed = "spinning", 0, false
      end
```
with:
```lua
      if state == "attract" and armed and lvl >= SPIN_LEVEL then
        local mode = econ.tryBet()               -- "staked" | "free" | "deny"
        if mode == "deny" then
          armed = false                          -- consume the pull; header shows INSUFFICIENT
        else
          reels = newSpin()
          state, spinTick, armed = "spinning", 0, false
        end
      end
```

- [ ] **Step 4: Settle at the result and pass status to every frame**

In `play()`, the spinning branch resolves the round. Replace:
```lua
        if allStopped then
          result = logic.isWin(reels[1].final, reels[2].final, reels[3].final) and "win" or "lose"
          drawTopFrame(reels, tick, result, false)
          state, resultAt = "result", tick
        end
```
with:
```lua
        if allStopped then
          result = logic.isWin(reels[1].final, reels[2].final, reels[3].final) and "win" or "lose"
          econ.settle({ reels[1].final, reels[2].final, reels[3].final })
          drawTopFrame(reels, tick, result, false, econ.status())
          state, resultAt = "result", tick
        end
```
Then add `, econ.status()` as the final argument to the **other four** `drawTopFrame(...)` calls in `play()`:
- `drawTopFrame(reels, 0, nil, true)` → `drawTopFrame(reels, 0, nil, true, econ.status())`
- `drawTopFrame(reels, tick, nil, false)` (spinning, inside the loop) → `drawTopFrame(reels, tick, nil, false, econ.status())`
- `drawTopFrame(reels, tick, result, false)` (result branch) → `drawTopFrame(reels, tick, result, false, econ.status())`
- `drawTopFrame(reels, tick, nil, true)` (result→attract reset) → `drawTopFrame(reels, tick, nil, true, econ.status())`

- [ ] **Step 5: Forward card + rednet events to the gateway**

In `play()`, the event dispatch currently reads:
```lua
    elseif ev[1] == "rednet_message" then
      pres.fromEvent(ev)                        -- update presence; sleep decision happens in attract
    elseif ev[1] == "key" and ev[2] == keys.q then
      restorePalette()
      return "quit"
    end
```
Replace with:
```lua
    elseif ev[1] == "rednet_message" then
      pres.fromEvent(ev)                        -- update presence; sleep decision happens in attract
      econ.onEvent(ev)
    elseif ev[1] == "disk" or ev[1] == "disk_eject" then
      econ.onEvent(ev)                          -- card inserted/removed: re-read balance
    elseif ev[1] == "key" and ev[2] == keys.q then
      restorePalette()
      return "quit"
    end
```

- [ ] **Step 6: Add the economy files to the slot package**

In `src/packages.lua`, in the `slot` entry's `files` list, add after the `{ name = "slot_advert", ... }` line (before `{ name = "slot", ... }`):
```lua
      { name = "card",     path = "lib/card.lua" },
      { name = "wallet",   path = "lib/wallet.lua" },
      { name = "sp_econ",  path = "lib/sp_econ.lua" },
      { name = "slot_pay", path = "slot/slot_pay.lua" },
```

- [ ] **Step 7: Syntax-check the slot**

Run: `luajit -bl src/slot/slot.lua > /dev/null && echo OK`
Expected: `OK`.

- [ ] **Step 8: Run the full unit suite (nothing regressed)**

Run: `luajit test/test_ledger.lua && luajit test/test_slot_pay.lua && luajit test/test_wallet.lua && luajit test/test_slot_logic.lua && luajit test/test_idle_logic.lua && luajit test/test_subpixel.lua`
Expected: every file prints `N passed, 0 failed`.

- [ ] **Step 9: Commit**

```bash
git add src/slot/slot.lua src/packages.lua
git commit -m "feat(slot): bet-and-pay via sp_econ (stake gate, settle, balance header)"
```

---

### Task 9: In-world verification (user-run)

Deploy and exercise the whole loop in-game. This is a manual checklist — no code — run by the user; the plan is complete once these pass. Requires: the hub computer with a **disk drive** added; the slot computer with a **disk drive** added; one blank floppy.

**Files:** none (verification only).

- [ ] **Step 1: Deploy.** In-game: `update hub`, `update slot`, and (on the hub box or a kiosk) `update issue`. Restart the hub program.
- [ ] **Step 2: Mint a card.** Put a blank floppy in the issuing drive; run `issue Alice 100`. Expect `Issued card 'Alice' with balance 100.`
- [ ] **Step 3: Insert + read.** Put Alice's card in the slot's drive. The header shows `Alice $100`.
- [ ] **Step 4: Bet + lose.** Pull the lever on a non-triple. Balance drops by 10 on both monitor and card (re-read confirms mirror).
- [ ] **Step 5: Bet + win.** Keep pulling until a triple lands. Balance = previous − 10 + payout (per paytable; a triple-seven adds 250).
- [ ] **Step 6: Insufficient.** Spend down below 10; pull the lever. No spin; header shows `INSUFFICIENT`.
- [ ] **Step 7: Anonymous.** Eject the card. Header shows `FREE PLAY`; the lever spins and a triple pays nothing (no debit, no credit).
- [ ] **Step 8: Outbox (win never lost).** Re-insert a funded card. Stop the hub program. Win a round (credit goes to the outbox; balance reflects locally). Restart the hub. Trigger any interaction (re-insert card / next pull) → `wallet.flush` banks the queued credit; the hub's `ledger.tbl` and the card mirror agree.
- [ ] **Step 9: Update `todo.md`.** Mark Option B's core loop done; note the payout knobs (stake 10 / cherry 3× / bell 5× / bar 8× / seven 25×) beside the existing slot tuning knobs; leave scoreboards + diegetic sink + `mp_econ` listed as parked follow-ons.

---

## Notes for the implementer

- **Fail-loud house style:** missing drive / modem / blank disk → a clear printed message, never a silent partial state (see `hub.lua`'s modem guard for the tone).
- **`request()` pumps events:** `wallet.request` runs `os.pullEvent` for up to 1.5 s on bet/credit. It briefly swallows presence/disk events during that window; this is acceptable (the next `query`/`onEvent` resyncs) and only happens on a lever pull or a win, not every tick.
- **Deploy flattens by `name`:** never `require` a folder path. The `path` fields in `packages.lua` are the only place folders appear.
