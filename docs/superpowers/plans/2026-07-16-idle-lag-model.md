# Idle / Lag Model Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make idle game stations cost ~zero server ticks by deep-sleeping them until a hub-owned Player Detector reports a player is near, waking them into an attract animation and an armed round.

**Architecture:** The chunk-loaded hub runs the *only* forever-loop: it polls one Advanced Peripherals Player Detector and edge-broadcasts a `presence` message over the existing `ccvegas` rednet protocol. Each station blocks on a single `os.pullEvent()` while asleep (no timer), waking on that presence message or a local lever redstone edge, then runs its existing 0.05s timer loop only while occupied. Pure decision logic is extracted into a unit-tested `idle_logic.lua`; the peripheral/rednet/redstone glue in `slot.lua` and `hub.lua` is verified in-game.

**Tech Stack:** CC:Tweaked (CraftOS, Lua 5.1), Advanced Peripherals 0.7 Player Detector, rednet over a wired modem. Local unit tests run under `luajit` against `test/runner.lua`.

## Global Constraints

- **Lua 5.1 / CraftOS only** — no `goto`, no `//`, no bitops operators; `idle_logic.lua` must be pure (no CC APIs) so `luajit` can run its tests.
- **Player Detector block name is `player_detector`** (MC 1.21.1+); obtain with `peripheral.find("player_detector")`; verify the live name in-world before trusting it.
- **rednet requires an open wired modem** — call `rednet.open(peripheral.getName(modem))` before send/receive on both hub and station.
- **Presence message shape is EXACT:** `{ kind = "presence", zone = "all", present = <boolean> }` broadcast on protocol `"ccvegas"`.
- **Station `ZONE` defaults to `"all"`** and reacts to a presence message iff `msg.zone == "all" or msg.zone == ZONE`.
- **A spin always finishes before sleeping** — never cut a round mid-flight.
- **Hub runs `parallel.waitForAll(registrar, presenceLoop)`** so a hub with no detector still serves as the registrar (presence loop just returns).
- **Deploy loop:** edit files under `src/` → `git push` → in-game run `update hub` and `update slot` (cache-busted pull), then run the program. Local `.lua` is a snapshot; nothing lands in-game until `update` runs.

---

### Task 1: `idle_logic` — pure decision helpers (unit-tested)

Extract every branch-able decision of the idle model into a pure module so it is testable without CraftOS. `slot.lua` and `hub.lua` will call these instead of inlining the logic.

**Files:**
- Create: `src/idle_logic.lua`
- Test: `test/test_idle_logic.lua`

**Interfaces:**
- Consumes: nothing (pure Lua).
- Produces:
  - `presenceFor(msg, myZone) -> boolean | nil` — given a received rednet value and this station's zone, returns `true`/`false` (the presence value) if it's a presence message for this zone, or `nil` if the message is not a presence update for us (ignore it).
  - `occupancyChanged(lastOcc, occ) -> boolean` — true iff the boolean-coerced occupancy differs (hub broadcasts only on the edge).
  - `shouldSleep(present, state) -> boolean` — true iff `not present and state == "attract"` (a round always finishes first).
  - `leverRose(prev, now, threshold) -> boolean` — analog rising-edge test: `prev < threshold and now >= threshold`.

- [ ] **Step 1: Write the failing test**

Create `test/test_idle_logic.lua`:

```lua
package.path = "src/?.lua;test/?.lua;" .. package.path
local t = require("runner")
local I = require("idle_logic")

-- presenceFor: matches my zone, "all", ignores others / non-presence
t.eq(I.presenceFor({ kind = "presence", zone = "all", present = true }, "slot1"), true,
  "zone 'all' present=true -> true")
t.eq(I.presenceFor({ kind = "presence", zone = "all", present = false }, "slot1"), false,
  "zone 'all' present=false -> false")
t.eq(I.presenceFor({ kind = "presence", zone = "slot1", present = true }, "slot1"), true,
  "my zone -> true")
t.eq(I.presenceFor({ kind = "presence", zone = "slot2", present = true }, "slot1"), nil,
  "other zone -> nil (ignore)")
t.eq(I.presenceFor({ kind = "register" }, "slot1"), nil, "non-presence msg -> nil")
t.eq(I.presenceFor("hello", "slot1"), nil, "non-table msg -> nil")

-- occupancyChanged: edge detection with bool coercion
t.ok(I.occupancyChanged(false, true), "empty->occupied changed")
t.ok(I.occupancyChanged(true, false), "occupied->empty changed")
t.ok(not I.occupancyChanged(false, false), "empty->empty no change")
t.ok(not I.occupancyChanged(true, true), "occupied->occupied no change")
t.ok(not I.occupancyChanged(nil, false), "nil treated as false -> no change")

-- shouldSleep: only from attract, only when absent
t.ok(I.shouldSleep(false, "attract"), "absent + attract -> sleep")
t.ok(not I.shouldSleep(true, "attract"), "present + attract -> stay")
t.ok(not I.shouldSleep(false, "spinning"), "absent mid-spin -> do NOT sleep (finish round)")
t.ok(not I.shouldSleep(false, "result"), "absent on result -> do NOT sleep yet")

-- leverRose: rising edge across the threshold only
t.ok(I.leverRose(0, 13, 13), "0 -> 13 (thr 13) rose")
t.ok(not I.leverRose(13, 15, 13), "already high -> no new edge")
t.ok(not I.leverRose(0, 12, 13), "below threshold -> no edge")
t.ok(not I.leverRose(15, 0, 13), "falling -> no edge")

t.done()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `luajit test/test_idle_logic.lua`
Expected: FAIL — `module 'idle_logic' not found` (or a load error).

- [ ] **Step 3: Write minimal implementation**

Create `src/idle_logic.lua`:

```lua
-- idle_logic.lua — pure decision helpers for the 3-tier idle model.
-- No CC APIs: unit-testable under luajit. See docs/superpowers/specs/2026-07-16-idle-lag-model-design.md.
local M = {}

-- Is this rednet value a presence update for my zone? Returns the present boolean, or nil to ignore.
function M.presenceFor(msg, myZone)
  if type(msg) ~= "table" or msg.kind ~= "presence" then return nil end
  if msg.zone == "all" or msg.zone == myZone then
    return msg.present and true or false
  end
  return nil
end

-- Hub: broadcast only when occupancy crosses an edge (booleans coerced so nil == false).
function M.occupancyChanged(lastOcc, occ)
  return (lastOcc and true or false) ~= (occ and true or false)
end

-- Station: drop from ACTIVE to DEEP SLEEP only when the zone is empty AND we're idle in attract
-- (a spin/result always finishes first).
function M.shouldSleep(present, state)
  return (not present) and state == "attract"
end

-- Analog rising edge across a threshold (lever pull): was below, now at/above.
function M.leverRose(prev, now, threshold)
  return prev < threshold and now >= threshold
end

return M
```

- [ ] **Step 4: Run test to verify it passes**

Run: `luajit test/test_idle_logic.lua`
Expected: PASS — `19 passed, 0 failed`.

- [ ] **Step 5: Run the existing suite to confirm no regression**

Run: `luajit test/test_slot_logic.lua && luajit test/test_subpixel.lua`
Expected: both print `N passed, 0 failed`.

- [ ] **Step 6: Commit**

```bash
git add src/idle_logic.lua test/test_idle_logic.lua
git commit -m "feat(idle): pure decision helpers for the 3-tier idle model

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Hub presence loop + detector test mode

Add the hub's presence poll as a second coroutine beside the existing registrar, plus a `hub test` mode to verify the detector block name and range in-world. Register `idle_logic` in the hub package so it deploys.

**Files:**
- Modify: `src/hub.lua`
- Modify: `src/packages.lua` (add `idle_logic` to the `hub` package)

**Interfaces:**
- Consumes: `idle_logic.occupancyChanged` (Task 1); the existing `PROTO = "ccvegas"` and the `rednet`-opened modem in `hub.lua`.
- Produces: broadcasts `{ kind = "presence", zone = "all", present = <boolean> }` on `PROTO` (consumed by Task 3).

- [ ] **Step 1: Add `idle_logic` to the hub package manifest**

In `src/packages.lua`, change the `hub` package's `files` from:

```lua
  hub = {
    station = false,
    files = {
      { name = "hub" },
    },
  },
```

to:

```lua
  hub = {
    station = false,
    files = {
      { name = "idle_logic" },
      { name = "hub" },
    },
  },
```

- [ ] **Step 2: Add config + capture program args at the top of `hub.lua`**

In `src/hub.lua`, directly after the existing `local STORE = "registry.tbl"` line, add:

```lua
local DET_RANGE = 8      -- blocks: how near a player must be for the hub to wake stations (v1: one range)
local POLL      = 0.3    -- seconds between detector polls (the hub's one forever-loop)
local idle      = require("idle_logic")
local args      = { ... }
```

- [ ] **Step 3: Add a `hub test` mode (before the registry is loaded)**

In `src/hub.lua`, immediately after the modem is opened (`rednet.host(PROTO, "hub")` line), insert:

```lua
if args[1] == "test" then
  local det = peripheral.find("player_detector")
  if not det then
    print("No 'player_detector' found. Check the block is on the wired network.")
    print("Attached peripherals:")
    for _, n in ipairs(peripheral.getNames()) do print(("  %s (%s)"):format(n, peripheral.getType(n))) end
    return
  end
  print(("Player detector OK. Live isPlayersInRange(%d) — walk in/out; Q quits:"):format(DET_RANGE))
  local timer = os.startTimer(0.25)
  while true do
    local ev = { os.pullEvent() }
    if ev[1] == "timer" and ev[2] == timer then
      local _, row = term.getCursorPos()
      term.setCursorPos(1, row); term.clearLine()
      io.write("in range: " .. tostring(det.isPlayersInRange(DET_RANGE)))
      term.setCursorPos(1, row)
      timer = os.startTimer(0.25)
    elseif ev[1] == "key" and ev[2] == keys.q then
      print(""); return
    end
  end
end
```

- [ ] **Step 4: Wrap the existing registration loop in a `registrar()` function**

In `src/hub.lua`, the current bottom-of-file loop:

```lua
while true do
  local sender, msg = rednet.receive(PROTO)
  if type(msg) == "table" and msg.kind == "register"
     and type(msg.computerID) == "number" and type(msg.package) == "string" then
    local n = assign(msg.computerID, msg.package)
    rednet.send(sender, { kind = "assigned", package = msg.package, instance = n }, PROTO)
    print(("  #%d  %s -> %s%d"):format(msg.computerID, msg.package, msg.package, n))
  end
end
```

becomes a named function (change only the `while true do` wrapper — body unchanged):

```lua
local function registrar()
  while true do
    local sender, msg = rednet.receive(PROTO)
    if type(msg) == "table" and msg.kind == "register"
       and type(msg.computerID) == "number" and type(msg.package) == "string" then
      local n = assign(msg.computerID, msg.package)
      rednet.send(sender, { kind = "assigned", package = msg.package, instance = n }, PROTO)
      print(("  #%d  %s -> %s%d"):format(msg.computerID, msg.package, msg.package, n))
    end
  end
end
```

- [ ] **Step 5: Add the `presenceLoop()` function directly after `registrar()`**

```lua
local function presenceLoop()
  local det = peripheral.find("player_detector")
  if not det then
    print("No player detector attached — presence disabled (registrar only).")
    return
  end
  print(("Presence loop online: isPlayersInRange(%d) every %.2fs."):format(DET_RANGE, POLL))
  local last = false
  local timer = os.startTimer(POLL)
  while true do
    local ev = { os.pullEvent() }
    if ev[1] == "timer" and ev[2] == timer then
      local occ = det.isPlayersInRange(DET_RANGE) and true or false
      if idle.occupancyChanged(last, occ) then
        rednet.broadcast({ kind = "presence", zone = "all", present = occ }, PROTO)
        print(occ and "[presence] occupied -> WAKE" or "[presence] empty -> SLEEP")
        last = occ
      end
      timer = os.startTimer(POLL)
    end
  end
end
```

- [ ] **Step 6: Replace the old inline loop invocation with `parallel`**

At the very bottom of `src/hub.lua` (where the old `while true do ... end` used to be, now that it's inside `registrar()`), add:

```lua
parallel.waitForAll(registrar, presenceLoop)
```

- [ ] **Step 7: Syntax-check both changed files**

Run: `luajit -bl src/hub.lua >/dev/null && luajit -bl src/packages.lua >/dev/null && echo OK`
Expected: `OK` (compiles; `-bl` only parses — CC globals are never executed).

- [ ] **Step 8: Commit**

```bash
git add src/hub.lua src/packages.lua
git commit -m "feat(hub): player-detector presence loop beside the registrar

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

- [ ] **Step 9: In-game verification (deploy loop)**

```bash
git push
```
Then in-game on the hub computer:
1. Run `update hub` (pulls `idle_logic` + `hub`).
2. Run `hub test` — walk in and out of range; confirm `in range:` flips `true`/`false` at your intended distance. If the block isn't found, note the real name from the printed peripheral list and adjust `peripheral.find` accordingly, then re-deploy.
3. Run `hub` — confirm it prints `Presence loop online` and, as you walk in/out, logs `[presence] occupied -> WAKE` / `empty -> SLEEP` **once per edge** (not every poll).

Expected: registrations still work (a station running `update` still gets its label) AND presence edges log correctly.

---

### Task 3: Slot deep-sleep / attract / armed states

Wrap `slot.lua`'s play logic in the DEEP SLEEP ↔ ACTIVE macro-states: block with no timer while empty, wake on hub presence or a cold lever pull, run the existing timer loop while occupied, and add the attract banner. Register `idle_logic` in the slot package.

**Files:**
- Modify: `src/slot.lua`
- Modify: `src/packages.lua` (add `idle_logic` to the `slot` package)

**Interfaces:**
- Consumes: `idle_logic.presenceFor`, `idle_logic.shouldSleep`, `idle_logic.leverRose` (Task 1); the hub's `presence` broadcast (Task 2).
- Produces: end-user behavior only (no downstream code consumers).

- [ ] **Step 1: Add `idle_logic` to the slot package manifest**

In `src/packages.lua`, change the `slot` package's `files` to include `idle_logic` (order before `slot`):

```lua
  slot = {
    station = true,
    files = {
      { name = "subpixel", path = "lib/subpixel.lua" },
      { name = "idle_logic" },
      { name = "slot_logic" },
      { name = "slot_symbols" },
      { name = "slot" },
    },
  },
```

- [ ] **Step 2: Add the `ZONE` config knob**

In `src/slot.lua`, inside the `---- config ----` block (after the `SPIN_LEVEL` line), add:

```lua
local ZONE = "all"  -- proximity zone this station answers to. "all" = any player in the hub's range.
                    -- (Per-station zones arrive with GPS; then set e.g. ZONE = "slot1".)
```

- [ ] **Step 3: Require `idle_logic` and open rednet in the PLAY section**

In `src/slot.lua`, in the `-- ===== PLAY =====` section, after the `local rng = ...` line add:

```lua
local idle = require("idle_logic")

-- open rednet so the hub can wake/sleep us (the wired modem also carries the monitor)
local function findModem()
  local wired = peripheral.find("modem", function(_, m) return not m.isWireless() end)
  return wired or peripheral.find("modem")
end
do local m = findModem(); if m then rednet.open(peripheral.getName(m)) end end
```

- [ ] **Step 4: Add the attract banner to `drawTopFrame`**

In `src/slot.lua`, replace the whole `drawTopFrame` function with this version (adds a fourth `attract` param and a "COME PLAY" banner):

```lua
-- draw one full top-monitor frame (subpixel graphics + banner text overlay), flushed at once
local function drawTopFrame(reels, bulbTick, result, attract)
  topWin.setVisible(false)
  drawTop(topCv, reels, bulbTick, result)
  if result == "win" or result == "lose" then
    local label = (result == "win") and "WIN!" or "LOSE"
    topWin.setTextColor(WHITE)
    topWin.setBackgroundColor(result == "win" and GREEN or RED)
    topWin.setCursorPos(math.floor((tw - #label) / 2) + 1, th)
    topWin.write(label)
  elseif attract then
    local label = "COME PLAY"
    topWin.setTextColor(YELLOW)
    topWin.setBackgroundColor(BLACK)
    topWin.setCursorPos(math.floor((tw - #label) / 2) + 1, th)
    topWin.write(label)
  end
  topWin.setVisible(true)
end
```

- [ ] **Step 5: Replace the whole play state machine (from `local state = "idle"` to end of file)**

In `src/slot.lua`, delete everything from the line `local state = "idle"        -- idle | spinning | result` through the final `print("Thanks for playing Slots!")`, and replace it with:

```lua
-- Monitor helpers ------------------------------------------------------------
local function restorePalette()
  for i = 1, #GRAD do
    local o = gradOrig[i]
    topMon.setPaletteColour(GRAD[i], o[1], o[2], o[3])
  end
end

local function clearMonitor()
  restorePalette()
  topMon.setBackgroundColor(colors.black); topMon.clear()
end

-- DEEP SLEEP: no timer. Block until a player is present (hub) or the lever is pulled cold.
-- Returns true to wake into ACTIVE, or false if the operator quit (Q).
local function deepSleep()
  clearMonitor()
  local prevLvl = redstone.getAnalogInput(SPIN_SIDE)
  while true do
    local ev = { os.pullEvent() }
    if ev[1] == "rednet_message" then
      local p = idle.presenceFor(ev[3], ZONE)   -- ev = { "rednet_message", sender, message, protocol }
      if p == true then return true end
      -- p == false or nil: still empty, keep sleeping
    elseif ev[1] == "redstone" then
      local lvl = redstone.getAnalogInput(SPIN_SIDE)
      if idle.leverRose(prevLvl, lvl, SPIN_LEVEL) then return true end
      prevLvl = lvl
    elseif ev[1] == "key" and ev[2] == keys.q then
      return false
    end
  end
end

-- ACTIVE: the 0.05s timer loop (attract -> spinning -> result). Returns true when the zone
-- empties and we should sleep, or false if the operator quit (Q).
local function runActive()
  local state = "attract"
  local reels = newSpin(); for _, r in ipairs(reels) do r.stopped = true end
  local tick, spinTick, resultAt, result = 0, 0, nil, nil
  local armed = true       -- rising-edge guard so a held lever doesn't auto-respin
  local present = true     -- we entered ACTIVE because someone is here

  updateGradient(0)
  drawTopFrame(reels, 0, nil, true)
  local timer = os.startTimer(TICK)

  while true do
    local ev = { os.pullEvent() }
    if ev[1] == "timer" and ev[2] == timer then
      tick = tick + 1
      updateGradient(tick * 0.05)

      local lvl = redstone.getAnalogInput(SPIN_SIDE)
      if state == "attract" and armed and lvl >= SPIN_LEVEL then
        reels = newSpin()
        state, spinTick, armed = "spinning", 0, false
      end
      if lvl < SPIN_LEVEL then armed = true end

      if state == "spinning" then
        spinTick = spinTick + 1
        local allStopped = true
        for _, r in ipairs(reels) do
          if not logic.stepReel(r, spinTick, SYMBOL_PX) then allStopped = false end
        end
        drawTopFrame(reels, tick, nil, false)
        if allStopped then
          result = logic.isWin(reels[1].final, reels[2].final, reels[3].final) and "win" or "lose"
          drawTopFrame(reels, tick, result, false)
          state, resultAt = "result", tick
        end
      elseif state == "result" then
        drawTopFrame(reels, tick, result, false)
        if tick - resultAt > 40 then           -- ~2s banner, then back to attract
          result = nil
          state = "attract"
          drawTopFrame(reels, tick, nil, true)
        end
      else -- attract
        drawTopFrame(reels, tick, nil, true)
        if idle.shouldSleep(present, state) then return true end   -- zone emptied while idle
      end

      timer = os.startTimer(TICK)
    elseif ev[1] == "rednet_message" then
      local p = idle.presenceFor(ev[3], ZONE)
      if p ~= nil then present = p end          -- update presence; sleep decision happens in attract
    elseif ev[1] == "key" and ev[2] == keys.q then
      return false
    end
  end
end

-- Top-level: sleep <-> active until the operator quits.
while true do
  local woke = deepSleep()
  if not woke then break end
  local alive = runActive()
  if not alive then break end
end

clearMonitor(); topMon.setCursorPos(1, 1); topMon.setTextScale(1)
print("Thanks for playing Slots!")
```

- [ ] **Step 6: Syntax-check the changed files**

Run: `luajit -bl src/slot.lua >/dev/null && luajit -bl src/packages.lua >/dev/null && echo OK`
Expected: `OK`.

- [ ] **Step 7: Run the full local suite (no regression in pure logic)**

Run: `luajit test/test_idle_logic.lua && luajit test/test_slot_logic.lua && luajit test/test_subpixel.lua`
Expected: all three print `N passed, 0 failed`.

- [ ] **Step 8: Commit**

```bash
git add src/slot.lua src/packages.lua
git commit -m "feat(slot): deep-sleep/attract/armed idle states, hub-woken

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: In-game integration verification + tick-cost findings

Deploy the full system and verify the four behaviors from the spec, then measure and record the idle tick-cost drop that justifies the whole feature.

**Files:**
- Modify: `kb/advanced-peripherals.md` (append measured findings)

**Interfaces:**
- Consumes: Tasks 1–3 deployed in-game (hub + at least one slot station).

- [ ] **Step 1: Deploy**

```bash
git push
```
In-game: on the hub run `update hub` then `hub`; on the slot station run `update slot` then let auto-run (or run `slot`) start it.

- [ ] **Step 2: Verify wake/sleep by proximity**

With the hub running and the zone empty, confirm the slot monitor is **cleared/black** (deep sleep). Walk into range → within ~`POLL`s the slot wakes to the attract animation with the "COME PLAY" banner. Walk out → within ~`POLL`s the monitor clears and sleeps again.
Expected: hub logs `WAKE` on entry and `SLEEP` on exit; slot follows.

- [ ] **Step 3: Verify the local cold-lever fallback**

Stop the hub (Ctrl+T). With the slot asleep, pull the lever. The slot should self-wake (redstone edge) and immediately spin one round.
Expected: playable with the hub down; restart the hub afterward.

- [ ] **Step 4: Verify the mid-round safety rule**

With the hub running, start a spin, then walk out of range while the reels are still spinning. The round must finish (reels stop, WIN/LOSE banner shows) and only *then* the station sleeps.
Expected: no round is ever cut mid-spin.

- [ ] **Step 5: Measure the idle tick-cost drop**

Use the server's profiler (`/spark tps` / `/spark profiler`, or `/forge tps`) or `os.clock` sampling. Baseline: with the pre-idle `slot` (a booted station's continuous loop) note the load; then with the idle model, confirm asleep stations hold **no** `os` timer and register ~no per-tick cost. If multiple stations are available, compare N booted stations idle-asleep vs the old always-animating loop.

- [ ] **Step 6: Record findings in `kb/`**

Append a dated section to `kb/advanced-peripherals.md` under a new heading `## Measured: idle model tick cost (<date>)` with: the detector's confirmed block name + working `DET_RANGE`, the observed wake latency, and the before/after tick/load numbers. Replace the `## Open questions` checkboxes that are now answered (block name, range) with the confirmed values.

- [ ] **Step 7: Commit**

```bash
git add kb/advanced-peripherals.md
git commit -m "docs(kb): measured idle-model tick cost + confirmed detector facts

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

- [ ] **Step 8: Update project status docs**

Mark the idle/lag model done: in `README.md` set the **Idle / lag model** row to ✓, and in `todo.md` move Option A to a DONE section (mirroring the existing "Deploy & identity" DONE block). Commit:

```bash
git add README.md todo.md
git commit -m "docs: idle/lag model complete

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Notes for the implementer

- **`ev[3]` is the message** in a `rednet_message` event: `{ "rednet_message", senderId, message, protocol }`. `presenceFor` is given `ev[3]`.
- **Why `parallel.waitForAll` (not `waitForAny`):** `presenceLoop` returns early when no detector is attached; `waitForAll` keeps the hub alive on `registrar` alone. `waitForAny` would exit the whole hub the moment `presenceLoop` returned.
- **The station must `rednet.open` its modem** even though it never sends — `rednet.receive`/event delivery requires an open modem. The wired modem is the same one carrying the monitor; opening it for rednet does not disturb peripheral access.
- **`luajit -bl <file>`** parses/byte-compiles without running, so CC globals (`peripheral`, `rednet`, `redstone`, `term`, `window`, `colors`, `parallel`) never execute — it only catches syntax errors. It is not a behavior test; that's what Task 4's in-game steps are for.
