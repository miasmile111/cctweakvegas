# The Cage (diegetic sink) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the `cage` station — a kiosk where a member card's `$` becomes real Minecraft metal (droppers spitting ingots on the floor) and metal becomes `$`.

**Architecture:** A new station folder `src/cage/` on the existing `idle_runner` framework, plus a new gateway `lib/cage_econ.lua` (sibling of `sp_econ`) composing the unchanged `card` + `wallet` core. All item logic is pure and unit-tested (`cage_vault`); peripheral I/O is quarantined in a thin `cage_hw`. Three small core additions — `wallet.debit`, `credit_deny`, `pixelfont` scale + `$` — pay forward to `mp_econ`.

**Tech Stack:** CC:Tweaked / CraftOS Lua 5.1 · `luajit` for unit tests + `luajit -bl` syntax check · rednet protocol `ccvegas` · advanced monitor 2×2 @0.5 (36×24 cells).

**Spec:** `docs/superpowers/specs/2026-07-16-diegetic-sink-cage-design.md` — read it before Task 1.

## Global Constraints

- **Lua 5.1 / CraftOS only.** No `goto`, no integer division `//`, no bitwise operators. Use `table.unpack or unpack`.
- **Pure modules must not touch CC globals** (`fs`, `rednet`, `peripheral`, `os.pullEvent`) — they run under bare `luajit` in tests. This applies to: `cage_rates`, `cage_vault`, `pixelfont`, `cage_symbols`.
- **Currency is `$`.** Display `$<n>`, never `MB` or `M-Bucks` (retired 2026-07-16).
- **Header comment on every program:** what it does, how to run it, wiring notes. Project convention.
- **Rates (exact):** copper_ingot 25 · iron_ingot 100 · gold_ingot 250 · diamond 1000. Flat both directions.
- **Qty ladder (exact):** `{1, 5, 20}`, default 1, resets to 1 on wake.
- **Ordering invariant, never violate:** stock check → debit → move → refund-if-short.
- **Never block the event pump.** No `sleep()` loops in `play()`; the shower is tick-driven. See `[[event-pump-reentrancy]]` in the cc-lua KB.
- **Test command:** `luajit test/test_<name>.lua` from repo root. Runner: `test/runner.lua` (`t.eq(actual, expected, msg)`, `t.ok(cond, msg)`, `t.done()`).
- **Test files start with:** `package.path = "src/lib/?.lua;src/cage/?.lua;test/?.lua;" .. package.path`
- **Syntax check:** `luajit -bl <file> > /dev/null` must pass on every `.lua` file touched.
- **Commit after every task.**

---

## ⚠️ PRE-EXECUTION GATE (owner-set)

**Do not start Task 7, 8, or 9 until `tools/cage-preview.html` has been built and the owner has signed off on the layout.** Tasks 1–6 are logic and have no layout dependency — they may proceed. The preview is built between plan approval and execution (see "UI review gate" in the spec); the **owner-approved** preview is the source of truth for every layout constant in Tasks 7–9. If the owner's redline changes the bands, Tasks 7–9 change with it — that is the entire point of the gate.

---

## File Structure

| File | Responsibility | Pure? |
| --- | --- | --- |
| `src/lib/pixelfont.lua` | **Modify** — add `scale` param + `$` glyph | ✅ |
| `src/lib/wallet.lua` | **Modify** — add `debit()`, `_creditResult()`, handle `credit_deny` | partly |
| `src/hub/hub.lua` | **Modify** — handle `debit`, reply `credit_deny` | ✗ |
| `src/lib/cage_econ.lua` | **Create** — card session + hub debit/credit gateway | ✗ |
| `src/cage/cage_rates.lua` | **Create** — DENOMS + QTYS + lookups | ✅ |
| `src/cage/cage_vault.lua` | **Create** — valuation, withdraw check, dropper load/pulse math | ✅ |
| `src/cage/cage_hw.lua` | **Create** — chests, droppers, redstone pulse | ✗ |
| `src/cage/cage_symbols.lua` | **Create** — ingot sprites | ✅ |
| `src/cage/cage_advert.lua` | **Create** — idle face, `draw(mon)` | ✗ |
| `src/cage/cage.lua` | **Create** — `play(mon, pres)` loop + UI | ✗ |
| `src/packages.lua` | **Modify** — `cage` package entry | ✗ |
| `test/test_pixelfont.lua` | **Modify** — scale + `$` cases | — |
| `test/test_wallet.lua` | **Modify** — `_creditResult` cases | — |
| `test/test_cage_rates.lua` | **Create** | — |
| `test/test_cage_vault.lua` | **Create** | — |

---

### Task 1: pixelfont — `scale` parameter + `$` glyph

**Files:**
- Modify: `src/lib/pixelfont.lua`
- Test: `test/test_pixelfont.lua`

**Interfaces:**
- Consumes: nothing.
- Produces: `M.textWidth(font, str, gap, scale) -> number` · `M.drawGlyph(cv, font, ch, x, y, color, scale)` · `M.drawText(cv, font, str, x, y, color, gap, scale)` · `M.drawCentered(cv, font, str, y, color, gap, scale)` · `M.BIG["$"]` (4×6). **`scale` defaults to 1 and `gap` keeps its existing default of 1 — every existing slot.lua call site must behave identically.** At `scale = s`, each glyph pixel becomes an `s × s` block; a BIG glyph is `4s` wide, `6s` tall; `gap` is in **subpixels, not scaled**.

- [ ] **Step 1: Write the failing tests**

Append to `test/test_pixelfont.lua` (keep the existing cases; `t.done()` must remain last):

```lua
-- ---- scale + $ (cage) ----------------------------------------------------
t.ok(P.BIG["$"] ~= nil, "BIG has a $ glyph")
t.eq(#P.BIG["$"], 6, "$ is 6 rows tall")
t.eq(#P.BIG["$"][1], 4, "$ is 4 px wide")

-- textWidth: scale multiplies glyph width, gap is NOT scaled
t.eq(P.textWidth(P.BIG, "8", 1, 1), 4, "one BIG digit @1x = 4")
t.eq(P.textWidth(P.BIG, "8", 1, 2), 8, "one BIG digit @2x = 8")
t.eq(P.textWidth(P.BIG, "88", 1, 2), 17, "two BIG digits @2x = 8+1+8")
t.eq(P.textWidth(P.BIG, "$123456", 1, 2), 62, "$ + 6 digits @2x = 7*8 + 6*1 = 62 (fits 72)")
-- default scale is 1 (back-compat with slot.lua call sites)
t.eq(P.textWidth(P.BIG, "88", 1), 9, "omitted scale = 1x")
t.eq(P.textWidth(P.WIN, "WIN:", 1), 16, "WIN: unchanged at 16")

-- drawGlyph @2x: each on-pixel becomes a 2x2 block
local cv = { w = 20, px = {} }
function cv:setPixel(x, y, c) self.px[y .. "," .. x] = c end
P.drawGlyph(cv, P.BIG, "1", 1, 1, 7, 2)
-- "1" row 1 is ".##." -> @2x cols 3,4,5,6 on rows 1,2
t.eq(cv.px["1,3"], 7, "@2x glyph fills x=3 y=1")
t.eq(cv.px["1,4"], 7, "@2x glyph fills x=4 y=1")
t.eq(cv.px["2,3"], 7, "@2x glyph doubles vertically (y=2)")
t.eq(cv.px["1,1"], nil, "@2x leaves off-pixels clear")

-- drawCentered @2x centers on the SCALED width
local cv2 = { w = 20, px = {} }
function cv2:setPixel(x, y, c) self.px[y .. "," .. x] = c end
P.drawCentered(cv2, P.BIG, "8", 1, 7, 1, 2)
-- scaled width 8 -> x = floor((20-8)/2)+1 = 7
t.eq(cv2.px["1,7"], 7, "@2x centered starts at x=7")
```

- [ ] **Step 2: Run to verify it fails**

Run: `luajit test/test_pixelfont.lua`
Expected: FAIL — `BIG has a $ glyph` (expected `true`, actual `false`) and the scale width cases.

- [ ] **Step 3: Implement**

Add the `$` glyph to `M.BIG` in `src/lib/pixelfont.lua` (after the `["9"]` line, matching the slashed style):

```lua
  ["$"] = { ".##.", "###.", ".##.", "..##", "###.", ".##." },
```

Replace `textWidth`, `drawGlyph`, `drawText`, `drawCentered` with the scale-aware versions:

```lua
-- total pixel width of a string in `font`: glyphs scaled by `scale`, `gap` blank subpixels between
-- (gap is NOT scaled — it is raw subpixels). scale defaults to 1, gap to 1.
function M.textWidth(font, str, gap, scale)
  gap, scale = gap or 1, scale or 1
  local w = 0
  for i = 1, #str do w = w + glyphW(font, str:sub(i, i)) * scale + gap end
  return w - gap
end

-- at scale s, each glyph pixel becomes an s x s block (nearest-neighbour, no smoothing)
function M.drawGlyph(cv, font, ch, x, y, color, scale)
  scale = scale or 1
  local g = font[ch]
  if not g then return end
  for r = 1, #g do
    local row = g[r]
    for c = 1, #row do
      if row:sub(c, c) == "#" then
        for dy = 0, scale - 1 do
          for dx = 0, scale - 1 do
            cv:setPixel(x + (c - 1) * scale + dx, y + (r - 1) * scale + dy, color)
          end
        end
      end
    end
  end
end

function M.drawText(cv, font, str, x, y, color, gap, scale)
  gap, scale = gap or 1, scale or 1
  local cx = x
  for i = 1, #str do
    local ch = str:sub(i, i)
    M.drawGlyph(cv, font, ch, cx, y, color, scale)
    cx = cx + glyphW(font, ch) * scale + gap
  end
end

-- draw horizontally centered across the whole canvas width (cv.w)
function M.drawCentered(cv, font, str, y, color, gap, scale)
  gap, scale = gap or 1, scale or 1
  local w = M.textWidth(font, str, gap, scale)
  M.drawText(cv, font, str, math.floor((cv.w - w) / 2) + 1, y, color, gap, scale)
end
```

- [ ] **Step 4: Run tests + the slot's tests (back-compat) + syntax**

Run: `luajit test/test_pixelfont.lua && luajit test/test_slot_logic.lua && luajit -bl src/lib/pixelfont.lua > /dev/null && echo SYNTAX_OK`
Expected: both test files print `N passed, 0 failed`, then `SYNTAX_OK`.

- [ ] **Step 5: Commit**

```bash
git add src/lib/pixelfont.lua test/test_pixelfont.lua
git commit -m "feat(pixelfont): scale param + \$ glyph for the cage's big balance"
```

---

### Task 2: `wallet.debit` + hub `debit` handler + `credit_deny`

**Files:**
- Modify: `src/lib/wallet.lua`
- Modify: `src/hub/hub.lua:125-139`
- Test: `test/test_wallet.lua`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `wallet.debit(id, amount) -> ok:boolean, balance:number|nil, reason:string|nil` — fail-closed, exactly mirroring `wallet.bet`'s contract. `reason` is `"unknown"` | `"insufficient"` | `"timeout"`.
  - `wallet._creditResult(r) -> "ok" | "deny" | "queue"` — **pure**, unit-tested. `r` is the reply table or `nil`.
  - `wallet.credit(id, delta) -> ok:boolean, balance:number|nil, reason:string|nil` — now returns `false, nil, "unknown"` on `credit_deny` **without** outboxing (retrying an unknown id forever would never succeed).
  - Hub: `debit{id, amount}` → `debit_ok{id, balance}` | `debit_deny{id, balance, reason}`; `credit{id, delta}` → `balance{id, balance}` | `credit_deny{id, reason="unknown"}`.

- [ ] **Step 1: Write the failing tests**

Append to `test/test_wallet.lua` (before `t.done()`):

```lua
-- ---- _creditResult: the F2 fix (unknown id must NOT read as acked) --------
t.eq(W._creditResult(nil), "queue", "no reply (hub down) -> outbox it")
t.eq(W._creditResult({ kind = "balance", id = "alice", balance = 240 }), "ok", "balance reply -> ok")
t.eq(W._creditResult({ kind = "credit_deny", id = "ghost", reason = "unknown" }), "deny",
     "credit_deny -> deny, never queued (retry can never succeed)")
```

- [ ] **Step 2: Run to verify it fails**

Run: `luajit test/test_wallet.lua`
Expected: FAIL — `attempt to call field '_creditResult' (a nil value)`.

- [ ] **Step 3: Implement — wallet**

In `src/lib/wallet.lua`, add the pure helper directly below `M._drop` (in the "pure outbox helpers" section):

```lua
-- classify a credit reply. "ok" = hub applied it; "deny" = hub refused (unknown id — retrying can
-- never succeed, so do NOT outbox); "queue" = no reply (hub down — outbox it, the win is not lost).
function M._creditResult(r)
  if r == nil then return "queue" end
  if r.kind == "credit_deny" then return "deny" end
  return "ok"
end
```

Replace `M.credit` (currently lines 93-100) with:

```lua
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
```

Add `M.debit` directly below `M.bet`:

```lua
-- fail closed, exactly like bet. `bet` stays the slot's wager-round special case; `debit` is the
-- honest, game-agnostic withdrawal primitive (the cage today; mp_econ pots + the trading station next).
function M.debit(id, amount)
  local r = request({ kind = "debit", id = id, amount = amount },
                    { debit_ok = true, debit_deny = true })
  if not r then return false, nil, "timeout" end
  if r.kind == "debit_ok" then return true, r.balance end
  return false, r.balance, r.reason
end
```

In `M.flush`, an unbankable entry must be dropped rather than retried forever. Replace the `if r then` block (currently lines 110-116) with:

```lua
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
```

- [ ] **Step 4: Implement — hub**

In `src/hub/hub.lua`, add the `debit` branch immediately after the `bet` branch (after line 134's `end`). It shares `ledger.debit` + `persistLedger` with `bet` — same truth, honest name:

```lua
    elseif type(msg) == "table" and msg.kind == "debit"
           and type(msg.id) == "string" and type(msg.amount) == "number" then
      local ok, bal = ledger.debit(scores, msg.id, msg.amount)
      if ok then
        persistLedger()
        rednet.send(sender, { kind = "debit_ok", id = msg.id, balance = bal }, PROTO)
      else
        rednet.send(sender, { kind = "debit_deny", id = msg.id, balance = bal,
                              reason = (bal == nil) and "unknown" or "insufficient" }, PROTO)
      end
```

Replace the `credit` branch (currently lines 135-139) so an unknown id is denied, not silently acked (**closes F2**):

```lua
    elseif type(msg) == "table" and msg.kind == "credit"
           and type(msg.id) == "string" and type(msg.delta) == "number" then
      local bal = ledger.apply(scores, msg.id, msg.delta)
      if bal then
        persistLedger()
        rednet.send(sender, { kind = "balance", id = msg.id, balance = bal }, PROTO)
      else
        rednet.send(sender, { kind = "credit_deny", id = msg.id, reason = "unknown" }, PROTO)
      end
```

- [ ] **Step 5: Run tests + syntax**

Run: `luajit test/test_wallet.lua && luajit test/test_ledger.lua && luajit -bl src/lib/wallet.lua > /dev/null && luajit -bl src/hub/hub.lua > /dev/null && echo SYNTAX_OK`
Expected: both test files `N passed, 0 failed`, then `SYNTAX_OK`.

- [ ] **Step 6: Commit**

```bash
git add src/lib/wallet.lua src/hub/hub.lua test/test_wallet.lua
git commit -m "feat(econ): wallet.debit primitive + credit_deny (closes latent F2)"
```

---

### Task 3: `cage_rates` — denominations + qty ladder

**Files:**
- Create: `src/cage/cage_rates.lua`
- Test: `test/test_cage_rates.lua`

**Interfaces:**
- Consumes: nothing.
- Produces: `M.DENOMS` — an **ordered array** (cheapest → dearest; UI renders left→right in this order) of `{ key, item, value, label }`. `M.QTYS = {1, 5, 20}`. `M.byItem(item) -> denom|nil` · `M.byKey(key) -> denom|nil`.

- [ ] **Step 1: Write the failing test**

Create `test/test_cage_rates.lua`:

```lua
package.path = "src/lib/?.lua;src/cage/?.lua;test/?.lua;" .. package.path
local t = require("runner")
local R = require("cage_rates")

t.eq(#R.DENOMS, 4, "four denominations")

-- ordered cheapest -> dearest (the UI renders them left to right in this order)
t.eq(R.DENOMS[1].key, "copper",  "1st = copper")
t.eq(R.DENOMS[2].key, "iron",    "2nd = iron")
t.eq(R.DENOMS[3].key, "gold",    "3rd = gold")
t.eq(R.DENOMS[4].key, "diamond", "4th = diamond")

t.eq(R.DENOMS[1].value, 25,   "copper = $25")
t.eq(R.DENOMS[2].value, 100,  "iron = $100")
t.eq(R.DENOMS[3].value, 250,  "gold = $250")
t.eq(R.DENOMS[4].value, 1000, "diamond = $1000")

t.eq(R.DENOMS[2].item, "minecraft:iron_ingot", "iron item id")
t.eq(R.DENOMS[4].item, "minecraft:diamond",    "diamond item id")

t.eq(R.byItem("minecraft:gold_ingot").value, 250, "byItem finds gold")
t.eq(R.byItem("minecraft:cobblestone"), nil, "byItem: junk is unknown")
t.eq(R.byKey("diamond").item, "minecraft:diamond", "byKey finds diamond")
t.eq(R.byKey("nope"), nil, "byKey: unknown key")

t.eq(R.QTYS[1], 1,  "qty ladder 1x")
t.eq(R.QTYS[2], 5,  "qty ladder 5x")
t.eq(R.QTYS[3], 20, "qty ladder 20x")

t.done()
```

- [ ] **Step 2: Run to verify it fails**

Run: `luajit test/test_cage_rates.lua`
Expected: FAIL — `module 'cage_rates' not found`.

- [ ] **Step 3: Implement**

Create `src/cage/cage_rates.lua`:

```lua
-- cage_rates.lua — the cage's denomination table + qty ladder. Data + lookups, nothing else:
-- this is the ONE file to edit to reprice the floor or add a metal (the slot_pay idiom).
-- Rates are FLAT and symmetric: a deposit and a withdrawal of the same item move the same $.
-- Pure (no CC globals) so it unit-tests under luajit.
local M = {}

-- ordered cheapest -> dearest; the UI renders them left to right in this order.
M.DENOMS = {
  { key = "copper",  item = "minecraft:copper_ingot", value = 25,   label = "COPPER"  },
  { key = "iron",    item = "minecraft:iron_ingot",   value = 100,  label = "IRON"    },
  { key = "gold",    item = "minecraft:gold_ingot",   value = 250,  label = "GOLD"    },
  { key = "diamond", item = "minecraft:diamond",      value = 1000, label = "DIAMOND" },
}

-- how many of a metal one tap withdraws. Default 1x; resets to 1x on wake.
M.QTYS = { 1, 5, 20 }

function M.byItem(item)
  for i = 1, #M.DENOMS do
    if M.DENOMS[i].item == item then return M.DENOMS[i] end
  end
  return nil
end

function M.byKey(key)
  for i = 1, #M.DENOMS do
    if M.DENOMS[i].key == key then return M.DENOMS[i] end
  end
  return nil
end

return M
```

- [ ] **Step 4: Run + syntax**

Run: `luajit test/test_cage_rates.lua && luajit -bl src/cage/cage_rates.lua > /dev/null && echo SYNTAX_OK`
Expected: `18 passed, 0 failed` then `SYNTAX_OK`.

- [ ] **Step 5: Commit**

```bash
git add src/cage/cage_rates.lua test/test_cage_rates.lua
git commit -m "feat(cage): denomination table + qty ladder"
```

---

### Task 4: `cage_vault` — pure item math

**Files:**
- Create: `src/cage/cage_vault.lua`
- Test: `test/test_cage_vault.lua`

**Interfaces:**
- Consumes: `cage_rates` (`M.byItem`).
- Produces:
  - `M.valueListing(list, rates) -> total:number, moves:table, ignored:number` — `list` is a `chest.list()` result (`{ [slot] = { name, count } }`, **sparse**). `moves` = `{ { slot = n, count = n }, ... }` **sorted ascending by slot** (determinism for tests + review). `ignored` = count of *item stacks* (not items) left alone.
  - `M.countItem(list, item) -> number` — total count of `item` across all slots.
  - `M.addLoad(loads, count, nextIdx) -> loads, nextIdx` — round-robin `count` items across `#loads` droppers starting at `nextIdx`; **mutates and returns `loads`**, returns the next index to start from. Wraps 1..#loads.
  - `M.pulseLoads(loads) -> loads, ejected:number` — one redstone pulse: every non-empty dropper ejects exactly 1. Mutates and returns `loads`; `ejected` = how many actually flew.
  - `M.anyLoaded(loads) -> boolean` — is the shower still owed anything?

**Why this file is pure:** it carries all the logic worth being wrong about, so it must be testable under bare `luajit`. Peripheral calls live in `cage_hw` (Task 6).

- [ ] **Step 1: Write the failing test**

Create `test/test_cage_vault.lua`:

```lua
package.path = "src/lib/?.lua;src/cage/?.lua;test/?.lua;" .. package.path
local t = require("runner")
local V = require("cage_vault")
local R = require("cage_rates")

-- ---- valueListing --------------------------------------------------------
local list = {
  [1] = { name = "minecraft:iron_ingot",   count = 5 },   -- 500
  [3] = { name = "minecraft:cobblestone",  count = 64 },  -- junk, ignored
  [4] = { name = "minecraft:diamond",      count = 2 },   -- 2000
  [7] = { name = "minecraft:copper_ingot", count = 4 },   -- 100
}
local total, moves, ignored = V.valueListing(list, R)
t.eq(total, 2600, "5 iron + 2 diamond + 4 copper = $2600")
t.eq(ignored, 1, "one junk stack ignored")
t.eq(#moves, 3, "three stacks to move")
t.eq(moves[1].slot, 1, "moves sorted by slot: first is slot 1")
t.eq(moves[1].count, 5, "moves carry the count")
t.eq(moves[2].slot, 4, "second is slot 4 (junk slot 3 skipped)")
t.eq(moves[3].slot, 7, "third is slot 7")

local zt, zm, zi = V.valueListing({}, R)
t.eq(zt, 0, "empty chest = $0")
t.eq(#zm, 0, "empty chest = no moves")
t.eq(zi, 0, "empty chest = nothing ignored")

local jt, jm, ji = V.valueListing({ [2] = { name = "minecraft:stick", count = 1 } }, R)
t.eq(jt, 0, "junk only = $0")
t.eq(#jm, 0, "junk only = no moves (never eats tools)")
t.eq(ji, 1, "junk only = 1 ignored")

-- ---- countItem -----------------------------------------------------------
local stock = {
  [1] = { name = "minecraft:iron_ingot", count = 64 },
  [2] = { name = "minecraft:diamond",    count = 3 },
  [5] = { name = "minecraft:iron_ingot", count = 12 },
}
t.eq(V.countItem(stock, "minecraft:iron_ingot"), 76, "iron summed across slots")
t.eq(V.countItem(stock, "minecraft:diamond"), 3, "diamond counted")
t.eq(V.countItem(stock, "minecraft:gold_ingot"), 0, "absent item = 0")
t.eq(V.countItem({}, "minecraft:iron_ingot"), 0, "empty vault = 0")

-- ---- addLoad (round-robin across droppers) -------------------------------
local loads, nxt = V.addLoad({ 0, 0, 0 }, 7, 1)
t.eq(loads[1], 3, "7 across 3 droppers: d1 gets 3")
t.eq(loads[2], 2, "d2 gets 2")
t.eq(loads[3], 2, "d3 gets 2")
t.eq(nxt, 2, "next start index wraps to 2")

-- a second tap CONTINUES the rotation and ADDS to existing loads (spam-tap overlap)
local loads2, nxt2 = V.addLoad(loads, 2, nxt)
t.eq(loads2[2], 3, "second tap adds to d2")
t.eq(loads2[3], 3, "second tap adds to d3")
t.eq(loads2[1], 3, "d1 untouched by the 2-item tap")
t.eq(nxt2, 1, "index wrapped back to 1")

t.eq(V.addLoad({ 0, 0, 0 }, 0, 1)[1], 0, "zero items loads nothing")
local one, oneNxt = V.addLoad({ 0, 0, 0 }, 1, 3)
t.eq(one[3], 1, "start index respected")
t.eq(oneNxt, 1, "wrap from 3 -> 1")

-- ---- pulseLoads ----------------------------------------------------------
local p, ejected = V.pulseLoads({ 3, 1, 0 })
t.eq(ejected, 2, "one pulse: only the 2 non-empty droppers eject")
t.eq(p[1], 2, "d1 3->2")
t.eq(p[2], 0, "d2 1->0")
t.eq(p[3], 0, "d3 stays 0 (never negative)")

local _, none = V.pulseLoads({ 0, 0, 0 })
t.eq(none, 0, "pulsing empty droppers ejects nothing")

-- ---- anyLoaded -----------------------------------------------------------
t.ok(V.anyLoaded({ 0, 1, 0 }), "still owed items")
t.ok(not V.anyLoaded({ 0, 0, 0 }), "shower done")

t.done()
```

- [ ] **Step 2: Run to verify it fails**

Run: `luajit test/test_cage_vault.lua`
Expected: FAIL — `module 'cage_vault' not found`.

- [ ] **Step 3: Implement**

Create `src/cage/cage_vault.lua`:

```lua
-- cage_vault.lua — the cage's item math: what a chest of metal is worth, and how items are
-- spread across the droppers and flung out one pulse at a time. PURE (no CC globals) so it
-- unit-tests under luajit; every peripheral call lives in cage_hw.lua.
--
-- Dropper model: all droppers sit on ONE redstone line, so a single pulse fires all of them at
-- once and every non-empty dropper ejects exactly one item. `loads` is a per-dropper count of
-- items still to fling; the shower is that table draining one pulse per tick.
local M = {}

-- Value a deposit chest listing. Returns total $, the stacks worth moving to the vault (sorted by
-- slot), and how many stacks were ignored. Unknown items are valued at 0 and NEVER moved — a
-- player's tools stay exactly where they left them.
function M.valueListing(list, rates)
  local total, moves, ignored = 0, {}, 0
  local slots = {}
  for slot in pairs(list) do slots[#slots + 1] = slot end
  table.sort(slots)                       -- deterministic order: tests and review depend on it
  for i = 1, #slots do
    local slot = slots[i]
    local it = list[slot]
    local d = rates.byItem(it.name)
    if d then
      total = total + d.value * it.count
      moves[#moves + 1] = { slot = slot, count = it.count }
    else
      ignored = ignored + 1
    end
  end
  return total, moves, ignored
end

-- total count of `item` across every slot of a listing
function M.countItem(list, item)
  local n = 0
  for _, it in pairs(list) do
    if it.name == item then n = n + it.count end
  end
  return n
end

-- spread `count` items round-robin across the droppers, starting at `nextIdx`. Mutates and returns
-- `loads` plus the index to start the NEXT tap from — so spam-tapping keeps the rotation even
-- instead of always reloading dropper 1.
function M.addLoad(loads, count, nextIdx)
  local n = #loads
  local i = nextIdx
  for _ = 1, count do
    loads[i] = loads[i] + 1
    i = i % n + 1
  end
  return loads, i
end

-- one redstone pulse: every non-empty dropper ejects exactly one item.
function M.pulseLoads(loads)
  local ejected = 0
  for i = 1, #loads do
    if loads[i] > 0 then
      loads[i] = loads[i] - 1
      ejected = ejected + 1
    end
  end
  return loads, ejected
end

function M.anyLoaded(loads)
  for i = 1, #loads do
    if loads[i] > 0 then return true end
  end
  return false
end

return M
```

- [ ] **Step 4: Run + syntax**

Run: `luajit test/test_cage_vault.lua && luajit -bl src/cage/cage_vault.lua > /dev/null && echo SYNTAX_OK`
Expected: `31 passed, 0 failed` then `SYNTAX_OK`.

- [ ] **Step 5: Commit**

```bash
git add src/cage/cage_vault.lua test/test_cage_vault.lua
git commit -m "feat(cage): pure item math — valuation, dropper round-robin, pulse drain"
```

---

### Task 5: `cage_econ` — the card-session gateway

**Files:**
- Create: `src/lib/cage_econ.lua`

**Interfaces:**
- Consumes: `card` (`read`, `writeMirror`, `isCardEvent`), `wallet` (`flush`, `query`, `debit`, `credit`) — from Task 2.
- Produces:
  - `M.new(cfg) -> self` — `cfg = { zone = string? }` (accepted for symmetry with `sp_econ`; unused today). Calls `wallet.flush()` then reads the card at construction.
  - `self.player` (id string | nil) · `self.balance` (number | nil) · `self.denied` (boolean) · `self.msg` (string | nil — the status line: `HUB OFFLINE`, `NEED $2000`, …) · `self.debitedId` (id string | nil — **the id the last successful `tryDebit` charged**)
  - `self.onEvent(ev)` — call for **every** event in the play loop; re-reads the card on disk events.
  - `self.tryDebit(amount) -> "ok" | "deny" | "nocard"` — fail-closed. Sets `self.msg` on failure. On success records `self.debitedId`.
  - `self.deposit(amount) -> newBalance:number|nil`
  - `self.refund(amount)` — credit back after a short move. **Refunds `self.debitedId`, not the live card** — the player can eject mid-shower, and the money must go back to whoever paid.
  - `self.status() -> { player, balance, denied, msg }`

**No unit test:** every method is a `card`/`wallet` I/O round-trip; the repo's convention (`sp_econ`, `wallet`'s rednet half) is to verify these in-world. The logic worth testing is already pure in `cage_vault`.

- [ ] **Step 1: Implement**

Create `src/lib/cage_econ.lua`:

```lua
-- cage_econ.lua — the cage's economy gateway: a card session plus hub debit/credit, driven from
-- the station's play() loop. Sibling of sp_econ, on the same card+wallet core.
--
-- Why not sp_econ? That gateway is bet/settle-shaped (a wager round with a paytable). The cage has
-- no round, no result and no house evaluation — it debits and it credits. Both gateways need the
-- same card-session machinery (re-read on disk events, mirror writes, outbox flush, capture the id
-- at commit), so they share the core, not each other. When mp_econ becomes the third instance,
-- THAT is when lib/card_session.lua gets extracted — three callers prove the shape, two guess it.
--
-- Reuses the modem idle_runner already opened; never opens rednet itself.
local card   = require("card")
local wallet = require("wallet")

local M = {}

-- cfg.zone is accepted for symmetry with the station's zone (unused today; MP will use it).
function M.new(cfg)
  cfg = cfg or {}
  local self = {
    player  = nil,   -- id string, or nil (anonymous — buttons inert, never a gate)
    balance = nil,   -- last known hub balance for player
    denied  = false,
    msg     = nil,   -- status line for the UI
    debitedId = nil, -- id the last successful tryDebit charged; refund() credits THIS, not the
                     -- live card. The player can eject mid-shower — the money owed goes back to
                     -- whoever paid it. (sp_econ's stakedId lesson, kb/economy.md.)
  }

  wallet.flush()     -- bank any deposits queued while the hub was down, on entry

  local function refreshCard()
    self.denied, self.msg = false, nil
    local c = card.read()
    if c then
      self.player = c.id
      local b = wallet.query(c.id)     -- hub is truth; fall back to the card mirror if offline
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

  -- Take `amount` off the card. Fail-closed: anything but "ok" means NO items may move.
  -- The caller must have already confirmed vault stock — ordering invariant is
  -- stock check -> debit -> move.
  function self.tryDebit(amount)
    self.denied, self.msg = false, nil
    if not self.player then self.msg = "INSERT CARD"; return "nocard" end
    local ok, bal, reason = wallet.debit(self.player, amount)
    if ok then
      self.balance = bal
      self.debitedId = self.player     -- capture at commit: refund() must not follow the live card
      card.writeMirror(bal)
      return "ok"
    end
    if bal ~= nil then self.balance = bal end   -- deny reply carries current balance
    self.denied = true
    self.msg = (reason == "timeout") and "HUB OFFLINE" or ("NEED $" .. amount)
    return "deny"
  end

  -- Put `amount` on the card. Guaranteed: if the hub is down the credit is outboxed and the
  -- balance is reflected locally, so a deposit is never lost (wallet.credit's contract).
  function self.deposit(amount)
    self.denied, self.msg = false, nil
    if not self.player then self.msg = "INSERT CARD"; return nil end
    local ok, bal, reason = wallet.credit(self.player, amount)
    if ok and bal then
      self.balance = bal
      card.writeMirror(bal)
    elseif reason == "unknown" then          -- credit_deny: this card's id is gone from the ledger
      self.denied, self.msg = true, "BAD CARD"
      return nil
    else
      self.balance = (self.balance or 0) + amount   -- queued to outbox; reflect locally
      self.msg = "HUB OFFLINE"
    end
    return self.balance
  end

  -- Give money back after a move came up short. Credits the id that was DEBITED, not whoever is in
  -- the drive now: the player may have ejected mid-shower, and a refund must never follow the card.
  -- Only touches the displayed balance / mirror when the debited id is still the one on screen.
  function self.refund(amount)
    if amount <= 0 or not self.debitedId then return end
    local ok, bal = wallet.credit(self.debitedId, amount)
    local live = (self.debitedId == self.player)
    if ok and bal then
      if live then self.balance = bal; card.writeMirror(bal) end
    elseif live then
      self.balance = (self.balance or 0) + amount   -- outboxed; reflect locally
    end
    self.msg = "REFUNDED $" .. amount
  end

  function self.status()
    return {
      player  = self.player,
      balance = self.balance,
      denied  = self.denied,
      msg     = self.msg,
    }
  end

  return self
end

return M
```

- [ ] **Step 2: Syntax check**

Run: `luajit -bl src/lib/cage_econ.lua > /dev/null && echo SYNTAX_OK`
Expected: `SYNTAX_OK`.

- [ ] **Step 3: Commit**

```bash
git add src/lib/cage_econ.lua
git commit -m "feat(cage): cage_econ gateway — card session + hub debit/credit"
```

---

### Task 6: `cage_hw` — peripheral I/O

**Files:**
- Create: `src/cage/cage_hw.lua`

**Interfaces:**
- Consumes: nothing (wraps CC peripherals directly).
- Produces:
  - `M.new(cfg) -> self|nil, err:string` — `cfg = { deposit = name, vault = name, droppers = {name,...}, side = string }`. Returns `nil, "no deposit chest: <name>"` etc. when a peripheral is missing — **fail loud**, the project's preflight convention.
  - `self.nDroppers -> number`
  - `self.depositList() -> table` — the deposit chest's `list()`.
  - `self.vaultList() -> table` — the vault's `list()`.
  - `self.sweepToVault(moves) -> moved:number` — push each `{slot, count}` from the deposit chest to the vault; returns items actually moved.
  - `self.loadDroppers(item, perDropper) -> loadedPer:table, total:number` — push `perDropper[i]` of `item` from the vault into dropper `i`. Returns the **per-dropper counts actually loaded** (parallel to `perDropper`) and their total. Both **may be less than asked** if the vault ran dry or a dropper filled — the caller refunds the difference and must track the shower from `loadedPer`, not from what it hoped for.
  - `self.pulse()` — one redstone pulse on `cfg.side`: all droppers fire together.

**No unit test:** pure peripheral I/O, verified in-world. All the math it drives is already tested in `cage_vault`.

- [ ] **Step 1: Implement**

Create `src/cage/cage_hw.lua`:

```lua
-- cage_hw.lua — every peripheral the cage touches, and nothing else. Chests, droppers, one
-- redstone line. All the math lives in cage_vault (pure, tested); this file is the hands.
--
-- Wiring: deposit chest, vault chest and EVERY dropper need a wired modem (pushItems only works
-- across the wired network). All droppers additionally share ONE redstone line from `cfg.side` —
-- a single pulse fires all of them, so a pulse ejects one item per non-empty dropper.
local M = {}

function M.new(cfg)
  local self = { nDroppers = #cfg.droppers }

  local deposit = peripheral.wrap(cfg.deposit)
  if not deposit then return nil, "no deposit chest: " .. tostring(cfg.deposit) end
  local vault = peripheral.wrap(cfg.vault)
  if not vault then return nil, "no vault chest: " .. tostring(cfg.vault) end

  local droppers = {}
  for i = 1, #cfg.droppers do
    local d = peripheral.wrap(cfg.droppers[i])
    if not d then return nil, "no dropper: " .. tostring(cfg.droppers[i]) end
    droppers[i] = d
  end

  function self.depositList() return deposit.list() end
  function self.vaultList()   return vault.list()   end

  -- move valued stacks from the deposit chest into the vault. Junk slots are simply not in `moves`,
  -- so they are never touched.
  function self.sweepToVault(moves)
    local moved = 0
    for i = 1, #moves do
      moved = moved + deposit.pushItems(cfg.vault, moves[i].slot, moves[i].count)
    end
    return moved
  end

  -- push `perDropper[i]` of `item` from the vault into dropper i. Walks the vault's slots because
  -- pushItems is slot-addressed; stops early when the vault runs dry or a dropper fills. Reports
  -- the PER-DROPPER counts it managed (not just a total) so the caller can drive the shower from
  -- what actually landed, and refund the shortfall.
  function self.loadDroppers(item, perDropper)
    local loadedPer, total = {}, 0
    for i = 1, #perDropper do
      loadedPer[i] = 0
      local want = perDropper[i]
      while want > 0 do
        local moved, found = 0, false
        for slot, it in pairs(vault.list()) do
          if it.name == item then
            found = true
            moved = vault.pushItems(cfg.droppers[i], slot, want)
            if moved > 0 then break end
          end
        end
        if not found or moved == 0 then want = 0        -- vault dry (or dropper full): give up
        else
          want         = want - moved
          loadedPer[i] = loadedPer[i] + moved
          total        = total + moved
        end
      end
    end
    return loadedPer, total
  end

  -- one pulse on the shared line: every non-empty dropper spits one item onto the floor.
  function self.pulse()
    redstone.setOutput(cfg.side, true)
    redstone.setOutput(cfg.side, false)
  end

  return self
end

return M
```

- [ ] **Step 2: Syntax check**

Run: `luajit -bl src/cage/cage_hw.lua > /dev/null && echo SYNTAX_OK`
Expected: `SYNTAX_OK`.

- [ ] **Step 3: Commit**

```bash
git add src/cage/cage_hw.lua
git commit -m "feat(cage): peripheral I/O — chests, droppers, shared redstone line"
```

---

> **STOP — the pre-execution gate applies from here.** Tasks 7, 8 and 9 encode layout. Do not start them until `tools/cage-preview.html` exists and the owner has approved it. Every geometry constant below marked `<from preview>` is filled in **from the approved preview**, not invented.

---

### Task 7: `cage_symbols` — ingot sprites

**Files:**
- Create: `src/cage/cage_symbols.lua`

**Interfaces:**
- Consumes: nothing.
- Produces: `M.SPRITES` — keyed by denom `key` (`copper`/`iron`/`gold`/`diamond`), each a sprite in the **`slot_symbols` shape**: `{ w = n, h = n, px = { <row-major colors, 0/nil = transparent> } }`. Drawn with `subpixel`'s `Canvas:drawSprite(x, y, sprite)`.

**Read `src/slot/slot_symbols.lua` first and match its shape exactly** — same table layout, same palette-constant idiom, same comment style. Sprite dimensions come from the approved preview `<from preview>`.

- [ ] **Step 1: Implement**

Create `src/cage/cage_symbols.lua` mirroring `slot_symbols.lua`'s structure: a header comment (what it is, that it's pure, the sprite shape), local colour constants, then `M.SPRITES` with one entry per denom key. Sprite art + dimensions: `<from preview>`.

- [ ] **Step 2: Syntax check**

Run: `luajit -bl src/cage/cage_symbols.lua > /dev/null && echo SYNTAX_OK`
Expected: `SYNTAX_OK`.

- [ ] **Step 3: Commit**

```bash
git add src/cage/cage_symbols.lua
git commit -m "feat(cage): ingot sprites"
```

---

### Task 8: `cage_advert` — the idle face

**Files:**
- Create: `src/cage/cage_advert.lua`

**Interfaces:**
- Consumes: nothing (may `require("subpixel")` / `require("pixelfont")`).
- Produces: `M.draw(mon)` — the **exact** contract `idle_runner` requires (it calls `require(cfg.name .. "_advert")` then `advert.draw(mon)`).

**Read `src/slot/slot_advert.lua` first and match it.** Drawn **once** on entering deep sleep — it must be static and cost nothing (core principle: idle = truly asleep). Content: the cage's face — the green↔gold identity, "CASH OUT" / the rate table. Layout `<from preview>`.

- [ ] **Step 1: Implement**

Create `src/cage/cage_advert.lua` following `slot_advert.lua`'s structure and the approved preview's idle screen.

- [ ] **Step 2: Syntax check**

Run: `luajit -bl src/cage/cage_advert.lua > /dev/null && echo SYNTAX_OK`
Expected: `SYNTAX_OK`.

- [ ] **Step 3: Commit**

```bash
git add src/cage/cage_advert.lua
git commit -m "feat(cage): idle advert screen"
```

---

### Task 9: `cage.lua` — the play loop + UI

**Files:**
- Create: `src/cage/cage.lua`

**Interfaces:**
- Consumes: `idle_runner` (`run{name, monitor, zone, play}`), `subpixel`, `pixelfont` (Task 1), `cage_econ` (Task 5), `cage_rates` (Task 3), `cage_vault` (Task 4), `cage_hw` (Task 6), `cage_symbols` (Task 7).
- Produces: the station entry point. `play(mon, pres) -> "sleep" | "quit"`.

**Read `src/slot/slot.lua` in full first.** This file is deliberately its sibling: same `Rl(row)` band helper, same `GRAD` palette machinery + `restorePalette()` discipline, same `bulb()`, same cell-space band-first touch hit-testing, same `topWin.setVisible(false/true)` wrap around native text, same `pres`/`onEvent` handling. Differences: green↔gold gradient, no reels, and the tick-driven shower.

**Structure:**

1. **Header comment** — what it is, how to run, full wiring notes (monitor 2×2 @0.5, disk drive, wired modem, deposit chest, vault chest, 2–3 droppers each with a modem + a shared redstone line, `cage.cfg`).
2. **Config** — read `cage.cfg` (project convention: rewire without re-importing) with these defaults:
   ```lua
   local CFG = { deposit = "minecraft:chest_0", vault = "minecraft:chest_1",
                 droppers = { "minecraft:dropper_0", "minecraft:dropper_1", "minecraft:dropper_2" },
                 side = "back", monitor = nil, zone = "all" }
   ```
3. **Layout** — `topLayout()` returning the bands, using `Rl(row) = (row - 1) * 3 + 1`. Band rows `<from preview>`; the spec's starting point is header 1-2, BIG `$` 3-8, bar 9-10, materials 11-18, qty 19-20, bar 21-22, deposit 23-24, side bulb lanes cols 1 & 36 rows 9-22.
4. **Balance count-up/down** — reuse slot's easing shape exactly, but signed so it works in both directions:
   ```lua
   -- dispBal eases toward the real balance: UP on a deposit, DOWN as the droppers empty.
   -- Same ~24-frame ramp as the slot's win count-up (slot.lua's `result` state).
   local function easeToward(cur, target)
     if cur == target then return cur end
     local step = math.max(1, math.ceil(math.abs(target - cur) / 24))
     if cur < target then return math.min(target, cur + step) end
     return math.max(target, cur - step)
   end
   ```
5. **The shower** — tick-driven, never blocking:
   ```lua
   -- loads[i] = items dropper i still owes the floor. Each tick: one pulse, every non-empty
   -- dropper spits one item. Taps ADD to loads mid-shower, so bursts overlap and spamming
   -- compounds. A blocking `for ... sleep()` here would swallow the tick timer and touch
   -- events — the exact freeze from [[event-pump-reentrancy]].
   ```
   Per tick: `if vault.anyLoaded(loads) then loads = vault.pulseLoads(loads); hw.pulse() end`
6. **Withdraw (a material tap)** — the ordering invariant, in this exact order:
   ```lua
   -- `loads` and `nextDropper` are play()-locals: loads[i] = items dropper i still owes the floor,
   -- nextDropper = where the next tap's round-robin starts (so consecutive taps stay even).
   local function withdraw(denom, qty)
     local have = vault.countItem(hw.vaultList(), denom.item)      -- 1. stock check
     if have < qty then econ.msg = "VAULT: " .. have .. " " .. denom.label; return end
     local cost = denom.value * qty
     if econ.tryDebit(cost) ~= "ok" then return end                 -- 2. debit (fail closed)

     local perDropper = {}
     for i = 1, hw.nDroppers do perDropper[i] = 0 end
     local _, nxt = vault.addLoad(perDropper, qty, nextDropper)     -- plan the spread
     nextDropper = nxt                                              -- advance the rotation

     local loadedPer, loaded = hw.loadDroppers(denom.item, perDropper)   -- 3. move
     for i = 1, #loadedPer do loads[i] = loads[i] + loadedPer[i] end     -- shower what LANDED
     if loaded < qty then econ.refund((qty - loaded) * denom.value) end  -- 4. refund the shortfall
   end
   ```
   **Reviewer note:** `loads` is fed from `loadedPer` — what actually reached each dropper — never from `qty`. Pulsing for items that were never loaded would drain the counter against empty droppers and desync the count-down from the metal on the floor.
7. **Deposit (the DEPOSIT tap)** — `local total, moves, ignored = vault.valueListing(hw.depositList(), rates)`; if `total == 0` set `econ.msg = "NOTHING TO DEPOSIT"` and stop; else `hw.sweepToVault(moves)` then `econ.deposit(total)` → the big number counts up. (Junk is never in `moves`, so it stays put.)
8. **Touch hit-testing** — cell-space, band-first, slot's `stakeAt` pattern; returns nil on a miss. Bands `<from preview>`:
   ```lua
   -- map a monitor touch (cell col,row) to an action, or nil for a miss
   local function hitTest(tx, ty)   -- -> "qty", n | "denom", n | "deposit" | nil
   ```
9. **Wake reset** — `qtyIdx = 1` on entry to `play()` (spec: qty resets to 1x on wake).
10. **Registration tail**:
    ```lua
    require("idle_runner").run{
      name = "cage", monitor = mon, zone = CFG.zone, play = play,
    }
    ```
    **No `wake` key** — the cage has no lever; hub presence wakes it (`idle_runner`'s `wake` is optional).
11. **`restorePalette()` before EVERY return from `play()`** — both the `"sleep"` and `"quit"` paths, exactly as `slot.lua` does. Forgetting one leaves the monitor's palette wrecked for the next program.

- [ ] **Step 1: Implement**

Write `src/cage/cage.lua` per the structure above, with band constants from the approved preview.

- [ ] **Step 2: Syntax check**

Run: `luajit -bl src/cage/cage.lua > /dev/null && echo SYNTAX_OK`
Expected: `SYNTAX_OK`.

- [ ] **Step 3: Offline PNG render verify**

Per `kb/monitor-ui-workflow.md`: render the subpixel layer to a PNG (the sim reuses the real `subpixel.lua` + `cage_symbols`) and compare against the approved preview. This catches `encodeCell`'s 2-colours-per-cell truth — the edge-straddling bulb lesson (`kb/monitor-ui.md`) — before anything deploys.
Expected: the render matches the approved layout; no squashed art at canvas-edge cells.

- [ ] **Step 4: Commit**

```bash
git add src/cage/cage.lua
git commit -m "feat(cage): the kiosk — play loop, touch UI, tick-driven shower"
```

---

### Task 10: Deploy manifest + docs

**Files:**
- Modify: `src/packages.lua`
- Modify: `todo.md`
- Modify: `kb/economy.md`
- Modify: `README.md:116-126` (the components table)

**Interfaces:**
- Consumes: every file from Tasks 1–9.
- Produces: `update cage` installs a working station.

- [ ] **Step 1: Add the package entry**

In `src/packages.lua`, add after the `slot` entry. **File order matters only for readability — `require` resolves by name, and the deploy flattens folders away.** Miss one file and the station dies at boot with `module not found`:

```lua
  cage = {
    station = true,
    files = {
      { name = "subpixel",     path = "lib/subpixel.lua" },
      { name = "pixelfont",    path = "lib/pixelfont.lua" },
      { name = "idle_logic",   path = "lib/idle_logic.lua" },
      { name = "idle_runner",  path = "lib/idle_runner.lua" },
      { name = "card",         path = "lib/card.lua" },
      { name = "wallet",       path = "lib/wallet.lua" },
      { name = "cage_econ",    path = "lib/cage_econ.lua" },
      { name = "cage_rates",   path = "cage/cage_rates.lua" },
      { name = "cage_vault",   path = "cage/cage_vault.lua" },
      { name = "cage_hw",      path = "cage/cage_hw.lua" },
      { name = "cage_symbols", path = "cage/cage_symbols.lua" },
      { name = "cage_advert",  path = "cage/cage_advert.lua" },
      { name = "cage",         path = "cage/cage.lua" },
    },
  },
```

- [ ] **Step 2: Verify the manifest against the tree**

Run: `for f in $(grep -oE 'path = "[^"]+"' src/packages.lua | sed 's/path = "//;s/"//' | sort -u); do test -f "src/$f" || echo "MISSING: src/$f"; done; echo MANIFEST_CHECKED`
Expected: `MANIFEST_CHECKED` with no `MISSING:` lines.

- [ ] **Step 3: Full test suite + syntax sweep**

Run: `for t in test/test_*.lua; do echo "-- $t"; luajit "$t" || exit 1; done && for f in $(git ls-files 'src/*.lua'); do luajit -bl "$f" > /dev/null || { echo "SYNTAX FAIL: $f"; exit 1; }; done && echo ALL_GREEN`
Expected: every test file `N passed, 0 failed`, then `ALL_GREEN`.

- [ ] **Step 4: Update the docs**

- `todo.md` — a `## Cage (diegetic sink)` section: what shipped, the wiring, the tuning knobs (`cage_rates.DENOMS`, `QTYS`, dropper count, tick rate), and **in-world verification still pending**. Move "Diegetic sink" out of the parked list.
- `kb/economy.md` — add `debit{id,amount} → debit_ok|debit_deny` and `credit_deny` to the protocol table; add `cage_econ` to the architecture diagram; mark **F2 fixed**; note the cage as the `$` exit; record the ordering invariant (stock → debit → move → refund) as a hard-won lesson.
- `README.md` — components table: add **Cage / diegetic sink** as `v1 ✓`.

- [ ] **Step 5: Commit**

```bash
git add src/packages.lua todo.md kb/economy.md README.md
git commit -m "feat(cage): deploy manifest + docs"
```

---

## Post-plan: in-world verification (after merge + push)

Per `CLAUDE.md` the deploy loop pulls from the repo, so this happens **after** merge+push. Mind the raw-CDN lag: wait 2–5 min after pushing, then `update cage` (expect a retry or two on a brand-new package).

Verify, in order:
1. `update hub` first — the hub needs the `debit` + `credit_deny` handlers before any cage can withdraw.
2. Walk up → presence wakes the station → advert → live UI.
3. Insert card → big `$` number fills in.
4. Deposit a mixed chest **including junk** → junk stays, number counts **up**, metal lands in the vault.
5. Withdraw each denom at 1x / 5x / 20x → droppers spit, number counts **down**.
6. **Spam-tap** a material → bursts overlap, machine never freezes (the whole point of the tick-driven queue).
7. Vault-empty deny → `VAULT: n IRON`, no debit taken.
8. Insufficient deny → `NEED $n`, no items move.
9. Hub offline → withdraw denies (`HUB OFFLINE`, fail closed); deposit still works and outboxes; bring the hub back → next contact flushes it.
10. Eject the card mid-shower → the shower completes, nothing is lost.
