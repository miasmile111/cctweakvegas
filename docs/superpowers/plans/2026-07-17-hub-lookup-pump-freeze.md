# Hub-Lookup Pump Freeze — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop stations freezing on a card swap when the hub is unreachable, and make the slot say `HUB OFFLINE` instead of lying with `INSUFFICIENT`.

**Architecture:** `rednet.lookup` pulls events with a bare `os.pullEvent()` and silently discards everything it does not recognise — including the play loop's tick timer. Wrap it in a `pumpSafe` helper that drives it as a coroutine and re-queues every event it dropped, back off when the hub is down so we stop pumping at all, then thread the already-existing `"timeout"` reason from `wallet.bet`/`wallet.query` through `sp_econ` to the slot's header.

**Tech Stack:** Lua 5.1 (CraftOS / CC:Tweaked), `luajit` for offline unit tests, existing `test/runner.lua` assert harness.

**Spec:** `docs/superpowers/specs/2026-07-17-hub-lookup-pump-freeze-design.md` — read it first. It carries the rom-source evidence and the failure chain.

## Global Constraints

- **Lua 5.1 only.** No `goto`, no integer division, no `#!`-isms. Use the file's existing
  `local unpack = table.unpack or unpack` (`src/lib/wallet.lua:75`) — **never** bare `table.unpack`.
- **No new files in `src/`.** `pumpSafe` stays local to `wallet.lua`. A new `lib/` module would force
  a `src/packages.lua` manifest change on every package and drag in the CDN-lag deploy trap
  (`CLAUDE.md`). No manifest change is needed for this work — keep it that way.
- **Do NOT touch `src/lib/idle_runner.lua:55`.** Its `rednet.lookup` is deliberately unstashed and
  lines 51-53 document why (boot-only, no caller loop, lever pre-sampled at lines 80-84). "Fixing" it
  risks the lever-wake regression that cost the proximity build a cycle.
- **Do NOT touch `src/update.lua:221`.** One-shot admin program, no play loop.
- **Fail-closed on money does not change.** `tryBet` still returns `"deny"` on a hub timeout. Only
  what the player is *told* changes.
- **Repo test convention** (`src/lib/wallet.lua:4`): pure helpers are unit-tested with an `_` prefix;
  rednet round-trips are verified in-world. Follow it — do not build a rednet mock framework.
- Run tests with `luajit test/<file>.lua` from the repo root. Syntax-check with `luajit -bl <file>`.

---

### Task 1: `pumpSafe` — give back the events you didn't consume

**Files:**
- Modify: `src/lib/wallet.lua` (add helper below line 75, near the existing `unpack` local)
- Test: `test/test_wallet.lua` (append)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `M._pumpSafe(fn, ...)` — drives `fn(...)` as a coroutine, pulling events on its behalf,
  stashing every event **except** `rednet_message` on the `dns` protocol, and re-queuing the stash via
  `os.queueEvent` before returning `fn`'s return values. Errors inside `fn` propagate. Task 2 calls it.

- [ ] **Step 1: Write the failing tests**

Append to `test/test_wallet.lua`. These fake the CraftOS `os` event API, which is legitimate here —
`wallet.lua` performs no `os.*` calls at load time, so `require`ing it under `luajit` is safe.

```lua
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
  -- In Lua 5.1/LuaJIT coroutine.running() is nil on the main thread and the coroutine otherwise.
  -- A fake that returns flatly instead of yielding does NOT model CraftOS: the pumped fn would then
  -- consume every canned event inside a single resume() and never hand control back to the driver.
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `luajit test/test_wallet.lua`
Expected: FAIL — `attempt to call field '_pumpSafe' (a nil value)`.

- [ ] **Step 3: Write the implementation**

In `src/lib/wallet.lua`, directly below the existing `local unpack = table.unpack or unpack` line
(currently line 75), add:

```lua
-- Drive a blocking rom function that pumps events, WITHOUT losing the caller's events.
-- rednet.lookup pulls with a bare os.pullEvent() and silently discards everything it does not
-- recognise (verified in CC:Tweaked rom/apis/rednet.lua) -- including a play loop's pending tick
-- timer. That is the floppy-swap freeze: the timer never comes back, the loop's next pullEvent
-- blocks forever, the monitor stops and only a reboot clears it ([[event-pump-reentrancy]]).
-- os.pullEvent IS coroutine.yield(filter), so we can stand in for the CraftOS scheduler: resume the
-- function ourselves, feed it every event, and re-queue the ones it dropped on the way out.
function M._pumpSafe(fn, ...)
  local co = coroutine.create(fn)
  local stash = {}
  local res = { coroutine.resume(co, ...) }
  while coroutine.status(co) ~= "dead" do
    if not res[1] then error(res[2], 0) end
    local ev = { os.pullEvent() }
    -- the coroutine's OWN dns traffic is its business; everything else belongs to the caller
    if not (ev[1] == "rednet_message" and ev[4] == "dns") then stash[#stash + 1] = ev end
    res = { coroutine.resume(co, unpack(ev)) }
  end
  if not res[1] then error(res[2], 0) end
  for _, e in ipairs(stash) do os.queueEvent(unpack(e)) end
  return unpack(res, 2)
end
```

Note: `M._pumpSafe` is defined with `function M.` (not `local function`) so the tests can reach it,
matching the file's existing `_`-prefixed helper convention.

**Do NOT mutate `os.pullEvent` inside `_pumpSafe`.** It is unnecessary — inside a coroutine
`os.pullEvent` already *is* `coroutine.yield(filter)`, which yields to whoever resumed it (us). It is
the same pattern CC's own `rom/apis/parallel.lua` uses. Mutating it would also silently break Ctrl+T,
because the real `os.pullEvent` turns a `terminate` event into `error("Terminated", 0)` and bare
`coroutine.yield` does not. If a test appears to require the mutation, **the test's fake is wrong**,
not this function.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `luajit test/test_wallet.lua`
Expected: PASS — all previously-passing assertions plus the new ones, `0 failed`.

- [ ] **Step 5: Syntax check**

Run: `luajit -bl src/lib/wallet.lua > /dev/null && echo OK`
Expected: `OK`

- [ ] **Step 6: Commit**

```bash
git add src/lib/wallet.lua test/test_wallet.lua
git commit -m "fix(wallet): _pumpSafe hands back the events rednet.lookup discards

The floppy-swap freeze. rednet.lookup pulls with a bare os.pullEvent() and
drops every event it does not recognise, so a lookup fired from inside a play
loop eats that loop's tick timer and the station hangs until reboot. Drive it
as a coroutine and re-queue what it dropped. Test 1 reproduces the freeze."
```

---

### Task 2: `getHub` — stop pumping when the hub is down

**Files:**
- Modify: `src/lib/wallet.lua:77-84` (replace the `hubId` / `getHub` block)
- Test: `test/test_wallet.lua` (append)

**Interfaces:**
- Consumes: `M._pumpSafe(fn, ...)` from Task 1.
- Produces: `M._lookupDue(lastFail, now, backoff)` → boolean — pure predicate, true when a lookup
  should be attempted. `getHub` stays local; its wiring is verified in-world per the file's contract
  (`src/lib/wallet.lua:4`). Nothing downstream calls `_lookupDue`.

- [ ] **Step 1: Write the failing tests**

Append to `test/test_wallet.lua`:

```lua
-- ---- _lookupDue: don't re-pump a hub that just failed to answer ------------
-- A failed lookup burns the full TIMEOUT pumping events. Without a backoff that happens on EVERY
-- call while the hub is down. This is the pure decision; the getHub wiring is verified in-world.
t.ok(W._lookupDue(nil, 100, 5), "never looked up before -> due")
t.ok(not W._lookupDue(100, 100, 5), "just failed -> not due")
t.ok(not W._lookupDue(100, 104.9, 5), "inside the backoff window -> not due")
t.ok(W._lookupDue(100, 105, 5), "backoff window elapsed exactly -> due")
t.ok(W._lookupDue(100, 200, 5), "long past the window -> due")
t.ok(W._lookupDue(100, 99, 5), "clock went backwards -> due (never wedge)")
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `luajit test/test_wallet.lua`
Expected: FAIL — `attempt to call field '_lookupDue' (a nil value)`.

- [ ] **Step 3: Write the implementation**

In `src/lib/wallet.lua`, replace the whole existing block at lines 77-84 (the comment, `local hubId`,
and `local function getHub`) with:

```lua
-- rednet.lookup is ITSELF a blocking event pump AND it discards what it pulls, so:
--   1. cache the hub id, so the hot path (a mid-round balance refresh) never looks up at all;
--   2. run it through _pumpSafe, so when we DO look up, the caller's timer survives;
--   3. back off after a failure -- a cache only helps when the hub ANSWERS. When it does not,
--      hubId stays nil and without this we would burn TIMEOUT pumping on every single call.
-- Together these turn "hub down = frozen station" into "hub down = one brief hitch per BACKOFF".
local LOOKUP_BACKOFF = 5   -- seconds to trust a failed lookup before trying again

-- pure: should we spend a lookup right now? `lastFail` is nil until one fails.
function M._lookupDue(lastFail, now, backoff)
  if lastFail == nil then return true end
  if now < lastFail then return true end          -- clock moved backwards: never wedge
  return (now - lastFail) >= backoff
end

local hubId, lastFail
local function getHub()
  if hubId then return hubId end
  if not M._lookupDue(lastFail, os.clock(), LOOKUP_BACKOFF) then return nil end
  hubId = M._pumpSafe(rednet.lookup, PROTO, "hub", TIMEOUT)
  if hubId then lastFail = nil else lastFail = os.clock() end
  return hubId
end
```

Two deliberate choices, both from the spec:
- **Reuses the existing `TIMEOUT` (1.5s)** instead of `rednet.lookup`'s 2s default and instead of
  adding a knob. One number, already proven in-world by `request`.
- **Line 108's `if result == nil then hubId = nil end` STAYS as-is.** The hub genuinely may come back
  with a new computer id. It is safe now: the re-lookup is stash-safe (Task 1) and backoff-limited.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `luajit test/test_wallet.lua`
Expected: PASS, `0 failed`.

- [ ] **Step 5: Syntax check**

Run: `luajit -bl src/lib/wallet.lua > /dev/null && echo OK`
Expected: `OK`

- [ ] **Step 6: Commit**

```bash
git add src/lib/wallet.lua test/test_wallet.lua
git commit -m "fix(wallet): back off a failed hub lookup instead of pumping every call

A cache only helps when the hub answers. When it does not, hubId stayed nil and
every call burned a full lookup timeout pumping events. Route the lookup through
_pumpSafe and skip it entirely inside a 5s backoff window."
```

---

### Task 3: thread the offline reason through to `sp_econ`

**Files:**
- Modify: `src/lib/wallet.lua:113-116` (`M.query`)
- Modify: `src/lib/sp_econ.lua:13-22` (state), `:26-37` (`refreshCard`), `:47-60` (`tryBet`), `:82-90` (`status`)
- Create: `test/test_sp_econ.lua`

**Interfaces:**
- Consumes: nothing from Tasks 1-2 (independent of the pump fix).
- Produces: `wallet.query(id)` → `balance, reason` where `reason` is `"timeout"` when the hub did not
  reply and `nil` otherwise. `sp_econ` state and `status()` gain `offline` (boolean). Task 4 reads
  `status().offline`.

- [ ] **Step 1: Write the failing tests**

Create `test/test_sp_econ.lua`. `sp_econ` requires `card` and `wallet`, so stub both via
`package.loaded` **before** requiring it — this is the only way to drive the offline paths offline.

```lua
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

-- ---- a successful bet clears both flags ----
do
  stubCard._disk = { id = "alice", score = 500 }
  stubWallet._query = { balance = 500, reason = nil }
  local e = newEcon()
  stubWallet._bet = { ok = true, balance = 490 }
  t.eq(e.tryBet(10), "staked", "funded bet stakes the round")
  t.ok(not e.status().offline, "successful bet clears offline")
  t.ok(not e.status().denied, "successful bet clears denied")
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `luajit test/test_sp_econ.lua`
Expected: FAIL — the offline assertions fail (`expected: true, actual: nil`), because `status()` has
no `offline` field yet.

- [ ] **Step 3a: Give `wallet.query` its reason**

In `src/lib/wallet.lua`, replace `M.query` (lines 113-116):

```lua
-- Returns balance, reason. `reason` is "timeout" when the hub did not answer -- nil balance alone is
-- ambiguous (hub down vs. unknown id) and callers render those very differently. Additive: every
-- existing single-return caller is unaffected.
function M.query(id)
  local r = request({ kind = "query", id = id }, { balance = true })
  if not r then return nil, "timeout" end
  return r.balance, nil
end
```

- [ ] **Step 3b: Add `offline` to `sp_econ`**

In `src/lib/sp_econ.lua`:

1. Add to the state table (after `denied  = false,` on line 18):

```lua
    offline = false,  -- hub unreachable: the header must say so, not accuse the player of being broke
```

2. Replace `refreshCard` (lines 26-37):

```lua
  local function refreshCard()
    self.denied = false
    local c = card.read()
    if c then
      self.player = c.id
      local b, reason = wallet.query(c.id)   -- hub is truth; fall back to the card mirror if offline
      self.offline = (reason == "timeout")
      self.balance = b or c.score
      if b then card.writeMirror(b) end
    else
      self.player, self.balance = nil, nil
      self.offline = false                   -- no card is anonymous free play, not a hub error
    end
  end
```

3. In `tryBet`, replace lines 47-51 through the deny tail. The full function:

```lua
  function self.tryBet(stake)
    self.denied = false
    if not self.player then self.round = "free"; return "free" end
    local st = stake or self.pay.STAKE
    local ok, bal, reason = wallet.bet(self.player, st)   -- 3rd return was being DROPPED here
    if ok then
      self.offline = false
      self.balance = bal; card.writeMirror(bal)
      self.round = "staked"; self.stakedId = self.player; self.stakedStake = st
      return "staked"
    end
    if bal ~= nil then self.balance = bal end   -- deny reply carries current balance
    -- A hub timeout and a real insufficient-funds deny BOTH fail closed -- that does not change.
    -- But they are not the same thing, and telling a player with $500 that they are INSUFFICIENT is
    -- a lie the machine tells about money. Keep them apart for the header.
    self.offline = (reason == "timeout")
    self.denied = not self.offline
    self.round = nil
    return "deny"
  end
```

4. Add `offline` to `status()` (in the returned table, after `denied  = self.denied,`):

```lua
      offline = self.offline,
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `luajit test/test_sp_econ.lua && luajit test/test_wallet.lua`
Expected: both PASS, `0 failed`.

- [ ] **Step 5: Syntax check**

Run: `luajit -bl src/lib/wallet.lua > /dev/null && luajit -bl src/lib/sp_econ.lua > /dev/null && echo OK`
Expected: `OK`

- [ ] **Step 6: Commit**

```bash
git add src/lib/wallet.lua src/lib/sp_econ.lua test/test_sp_econ.lua
git commit -m "fix(econ): a hub timeout is HUB OFFLINE, not INSUFFICIENT

wallet.bet already returned reason='timeout'; sp_econ dropped the third return
and set denied, so a hub-down slot told a player holding \$500 they were broke.
Thread the reason through to state. Fails closed exactly as before -- only what
the player is told changes. wallet.query gains the same reason (a nil balance
alone cannot distinguish hub-down from unknown-id)."
```

---

### Task 4: the slot says `HUB OFFLINE`

**Files:**
- Modify: `src/slot/slot.lua:207-213` (header block in `drawTopFrame`)

**Interfaces:**
- Consumes: `status().offline` (boolean) from Task 3.
- Produces: nothing downstream.

No unit test: this is a monitor draw, covered by the in-world checklist below. That matches how the
rest of `slot.lua`'s rendering is verified (`kb/monitor-ui-workflow.md`).

- [ ] **Step 1: Make the change**

In `src/slot/slot.lua`, replace the header block (lines 207-211):

```lua
  -- header (row 2): "<id>: $<bal>", or HUB OFFLINE / INSUFFICIENT / FREE PLAY. bg = gradient slot so
  -- it rides it. OFFLINE is checked FIRST: a hub timeout fails closed like a real deny, but the
  -- player is not broke and the machine must not say they are.
  local hdr
  if status.offline then hdr = "HUB OFFLINE"
  elseif status.denied then hdr = "INSUFFICIENT"
  elseif status.player then hdr = ("%s: $%d"):format(status.player, status.balance or 0)
  else hdr = "FREE PLAY" end
```

`"HUB OFFLINE"` is 11 characters in a 15-cell header — it fits the existing centred write on line
213 (`math.max(1, math.floor((tw - #hdr) / 2) + 1)`), so no layout change is needed.

- [ ] **Step 2: Syntax check**

Run: `luajit -bl src/slot/slot.lua > /dev/null && echo OK`
Expected: `OK`

- [ ] **Step 3: Run the full suite**

Run: `for f in test/test_*.lua; do echo "-- $f"; luajit "$f" || exit 1; done`
Expected: every file `0 failed`.

- [ ] **Step 4: Confirm no manifest change is needed**

Run: `grep -n "wallet\|sp_econ\|slot.lua" src/packages.lua`
Expected: all three already listed. **No new files were created in `src/`**, so `src/packages.lua` is
unchanged — and the CDN-lag trap (`CLAUDE.md`) does not apply to this deploy.

- [ ] **Step 5: Commit**

```bash
git add src/slot/slot.lua
git commit -m "fix(slot): header says HUB OFFLINE when the hub is unreachable

Checked before denied: a hub timeout fails closed like an insufficient-funds
deny, but the player is not broke. 11 chars in a 15-cell header, fits centred."
```

---

## In-world verification (after merge + push)

Per the spec. The bug's own repro, now that the trigger is known:

1. `update slot`, reboot. Insert a card → header shows `<id>: $<bal>`.
2. **Break the hub on purpose** — stop `hub.lua` (or unload its chunk). This is the state the
   owner's chunkload fix normally prevents, which is exactly why it must be tested deliberately.
3. Swap the floppy at the slot, repeatedly. **Pre-fix: freeze.** Post-fix: reels keep animating, the
   header reads `HUB OFFLINE`.
4. Pull the lever while offline → denied, header says `HUB OFFLINE`, **not** `INSUFFICIENT`.
5. Bring the hub back. Within ~5s (the backoff) the header returns to `<id>: $<bal>`, no reboot.
6. Regression check: a win banked while the hub was down still lands (the outbox path is untouched).

## KB follow-up (do this at wrap-up, not during implementation)

`[[event-pump-reentrancy]]` predicted this family and even names `rednet.lookup` — but its fix
section says "**cache** anything found via a blocking lookup", and a cache is exactly what `getHub`
had. Update the entry: **a cache only helps on the success path; the failure path needs a backoff,
and the lookup itself still needs the stash.** That is the finding this session adds.
