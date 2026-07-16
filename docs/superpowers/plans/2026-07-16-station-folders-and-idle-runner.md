# Per-Station Folders + Shared Idle Runner — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reorganize `src/` into per-station folders + a shared `lib/`, and extract the idle lifecycle into one `lib/idle_runner.lua` so every station is just a play file + a `<basename>_advert.lua`.

**Architecture:** `src/` splits into `hub/ slot/ pong/ lib/`. Deploy flattens files by `name`, so `require()` is unchanged — only `packages.lua` `path` fields and the tests' `package.path` move. A shared `idle_runner.run(cfg)` owns modem/rednet, deep sleep (draw advert once, block on `os.pullEvent`), wake on hub presence or a local redstone edge, the `presence?` query, and cleanup; the station supplies a `play(mon, pres)` function and a `<name>_advert.lua`. slot and pong both adopt it.

**Tech Stack:** CC:Tweaked (CraftOS, Lua 5.1), rednet over a wired modem. Local unit tests run under `luajit` against `test/runner.lua`.

## Global Constraints

- **Lua 5.1 / CraftOS only.** `lib/idle_logic.lua` stays pure (unit-testable under luajit); `lib/idle_runner.lua` may use CC APIs but must not call them at module-load time (only inside `run`), so it can still be `require`d without CC present if ever needed.
- **Deploy flattens by name** (`update.lua:172-175`): `packages.lua` `path` = repo location under `src/`; `name` = flat in-game filename. **No `require()` call in any `.lua` changes** — modules are required by bare name.
- **Protocol is `"ccvegas"`.** Presence broadcast shape EXACT: `{ kind = "presence", zone = "all", present = <bool> }`. Presence query shape EXACT: `{ kind = "presence?", zone = <zone> }`.
- **Runner `cfg` contract:** `{ name=<basename str>, monitor=<mon>, zone=<str?> (default "all"), wake=<{side,level}?>, play=<function(mon,pres)->"sleep"|"quit"> }`.
- **`<basename>_advert.lua`** exports `draw(mon)`, draws a STATIC screen using DEFAULT palette colours only (no custom palette slots, no animation, no timer).
- **A station's `play` returns `"sleep"` or `"quit"`.** For slot, a spin ALWAYS finishes before returning `"sleep"` (sleep decision only in the `attract` state).
- **Local tests:** run each with `luajit test/<file>.lua`; every test file's `package.path` must include `src/lib/?.lua;src/slot/?.lua;src/pong/?.lua;test/?.lua`.
- **Deploy loop:** edit `src/` → `git push` → in-game `update <pkg>`; files land flat, programs run by name.

---

### Task 1: Reorganize `src/` into per-station folders + `lib/`

Move files into folders (repo-side only), update `packages.lua` paths and the tests' `package.path`. No file *contents* change except those two path concerns. In-game behavior is identical after this task.

**Files:**
- Move: `src/idle_logic.lua`→`src/lib/idle_logic.lua`; `src/hub.lua`→`src/hub/hub.lua`; `src/slot.lua`→`src/slot/slot.lua`; `src/slot_logic.lua`→`src/slot/slot_logic.lua`; `src/slot_symbols.lua`→`src/slot/slot_symbols.lua`; `src/pong.lua`→`src/pong/pong.lua`. (`src/lib/subpixel.lua` already in place.)
- Modify: `src/packages.lua`, `test/test_idle_logic.lua`, `test/test_slot_logic.lua`, `test/test_subpixel.lua`

**Interfaces:**
- Consumes: nothing.
- Produces: the new folder layout that all later tasks write into.

- [ ] **Step 1: Move the files with git**

```bash
cd /d/KreaFolder/cctweaked
mkdir -p src/hub src/slot src/pong src/lib
git mv src/idle_logic.lua   src/lib/idle_logic.lua
git mv src/hub.lua          src/hub/hub.lua
git mv src/slot.lua         src/slot/slot.lua
git mv src/slot_logic.lua   src/slot/slot_logic.lua
git mv src/slot_symbols.lua src/slot/slot_symbols.lua
git mv src/pong.lua         src/pong/pong.lua
git status --short
```
Expected: six `R` (renamed) entries; nothing else moved.

- [ ] **Step 2: Update every test file's `package.path` (line 1)**

In each of `test/test_idle_logic.lua`, `test/test_slot_logic.lua`, `test/test_subpixel.lua`, replace the entire first line with:

```lua
package.path = "src/lib/?.lua;src/slot/?.lua;src/pong/?.lua;test/?.lua;" .. package.path
```

(The originals are `"src/?.lua;test/?.lua;..."` for the first two and `"src/lib/?.lua;test/?.lua;..."` for the third — replace all three with the identical superset line above.)

- [ ] **Step 3: Update `src/packages.lua` to the new paths**

Replace the three package tables' `files` so every entry has an explicit `path` under `src/` (names unchanged):

```lua
  slot = {
    station = true,
    files = {
      { name = "subpixel",     path = "lib/subpixel.lua" },
      { name = "idle_logic",   path = "lib/idle_logic.lua" },
      { name = "slot_logic",   path = "slot/slot_logic.lua" },
      { name = "slot_symbols", path = "slot/slot_symbols.lua" },
      { name = "slot",         path = "slot/slot.lua" },
    },
  },

  pong = {
    station = true,
    files = {
      { name = "pong", path = "pong/pong.lua" },
    },
  },

  hub = {
    station = false,
    files = {
      { name = "idle_logic", path = "lib/idle_logic.lua" },
      { name = "hub",        path = "hub/hub.lua" },
    },
  },
```

(Tasks 3 and 4 add `idle_runner` / `slot_advert` / `pong_advert` entries when those files exist.)

- [ ] **Step 4: Verify the suite still passes and files parse**

```bash
cd /d/KreaFolder/cctweaked
luajit test/test_idle_logic.lua && luajit test/test_slot_logic.lua && luajit test/test_subpixel.lua
luajit -bl src/hub/hub.lua >/dev/null && luajit -bl src/slot/slot.lua >/dev/null && luajit -bl src/pong/pong.lua >/dev/null && luajit -bl src/lib/idle_logic.lua >/dev/null && luajit -bl src/packages.lua >/dev/null && echo "SYNTAX OK"
```
Expected: `22 passed, 0 failed` / `21 passed, 0 failed` / `25 passed, 0 failed`, then `SYNTAX OK`.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor: reorganize src/ into per-station folders + lib/

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Add pure `newPresence(zone)` factory to `idle_logic`

Add the presence-handle factory the runner hands to each station's `play`. Pure, unit-tested.

**Files:**
- Modify: `src/lib/idle_logic.lua`
- Test: `test/test_idle_logic.lua`

**Interfaces:**
- Consumes: `idle_logic.presenceFor` (existing).
- Produces: `newPresence(zone) -> { present:bool, fromEvent(ev)->bool, gone()->bool }`. Fresh handle has `present == true`; `fromEvent(ev)` updates `present` when `ev` is a `rednet_message` presence for `zone` (else unchanged) and returns `present`; `gone()` returns `not present`.

- [ ] **Step 1: Write the failing test**

In `test/test_idle_logic.lua`, immediately before the final `t.done()` line, add:

```lua
-- newPresence: a handle that tracks presence from incoming rednet events
do
  local pr = I.newPresence("slot1")
  t.ok(pr.present, "newPresence starts present")
  t.ok(not pr.gone(), "not gone initially")
  pr.fromEvent({ "rednet_message", 5, { kind = "presence", zone = "all", present = false }, "ccvegas" })
  t.ok(not pr.present, "present=false msg -> not present")
  t.ok(pr.gone(), "gone() true after leave")
  pr.fromEvent({ "rednet_message", 5, { kind = "presence", zone = "all", present = true }, "ccvegas" })
  t.ok(pr.present, "present=true msg -> present again")
  pr.fromEvent({ "rednet_message", 5, { kind = "presence", zone = "slot2", present = false }, "ccvegas" })
  t.ok(pr.present, "other-zone msg ignored")
  pr.fromEvent({ "timer", 1 })
  t.ok(pr.present, "non-presence event ignored")
end
```

Run: `luajit test/test_idle_logic.lua` → expect FAIL (`newPresence` is nil).

- [ ] **Step 2: Implement `newPresence`**

In `src/lib/idle_logic.lua`, immediately before the final `return M` line, add:

```lua
-- Build a presence handle for a station's active loop. `present` starts true (we entered ACTIVE
-- because someone is here); fromEvent(ev) folds a matching presence message into `present`.
function M.newPresence(zone)
  local p = { present = true }
  function p.fromEvent(ev)
    if type(ev) == "table" and ev[1] == "rednet_message" then
      local v = M.presenceFor(ev[3], zone)
      if v ~= nil then p.present = v end
    end
    return p.present
  end
  function p.gone() return not p.present end
  return p
end
```

- [ ] **Step 3: Verify tests pass**

Run: `luajit test/test_idle_logic.lua`
Expected: `29 passed, 0 failed`.

- [ ] **Step 4: Commit**

```bash
git add src/lib/idle_logic.lua test/test_idle_logic.lua
git commit -m "feat(idle): pure newPresence(zone) handle factory for the runner

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Shared `idle_runner` + `slot_advert` + convert slot

Create the shared runner and slot's advert, then rewire `slot.lua` to use them (removing its private idle loop). Delivers a working slot-on-runner. In-game verified by the user.

**Files:**
- Create: `src/lib/idle_runner.lua`, `src/slot/slot_advert.lua`
- Modify: `src/slot/slot.lua`, `src/packages.lua`

**Interfaces:**
- Consumes: `idle_logic.newPresence` / `presenceFor` / `leverRose` (Tasks 1-2); the hub presence protocol.
- Produces: `idle_runner.run(cfg)` (see Global Constraints); `slot_advert.draw(mon)`.

- [ ] **Step 1: Create `src/lib/idle_runner.lua`**

```lua
-- idle_runner.lua — the shared idle lifecycle for every station. Owns rednet + deep sleep + wake +
-- the presence? query, draws the station's <name>_advert on player-leave, and runs its play() while
-- present. All lag-critical machinery lives here so a station is just a play file + an advert file.
local idle = require("idle_logic")
local PROTO = "ccvegas"

local function findModem()
  local wired = peripheral.find("modem", function(_, m) return not m.isWireless() end)
  return wired or peripheral.find("modem")
end

-- cfg: { name, monitor, zone?, wake={side,level}?, play=function(mon, pres)->"sleep"|"quit" }
local function run(cfg)
  local zone   = cfg.zone or "all"
  local mon    = cfg.monitor
  local advert = require(cfg.name .. "_advert")

  local hasRednet = false
  do local m = findModem(); if m then rednet.open(peripheral.getName(m)); hasRednet = true end end
  local function queryPresence()
    if hasRednet then rednet.broadcast({ kind = "presence?", zone = zone }, PROTO) end
  end

  -- DEEP SLEEP: draw the advert once, then block (no timer). Returns "wake" or "quit".
  local function deepSleep()
    advert.draw(mon)
    queryPresence()                       -- if a player is already here, the hub's reply wakes us
    local prevLvl = cfg.wake and redstone.getAnalogInput(cfg.wake.side) or 0
    while true do
      local ev = { os.pullEvent() }
      if ev[1] == "rednet_message" then
        if idle.presenceFor(ev[3], zone) == true then return "wake" end
      elseif ev[1] == "redstone" and cfg.wake then
        local lvl = redstone.getAnalogInput(cfg.wake.side)
        if idle.leverRose(prevLvl, lvl, cfg.wake.level) then return "wake" end
        prevLvl = lvl
      elseif ev[1] == "key" and ev[2] == keys.q then
        return "quit"
      end
    end
  end

  while true do
    if deepSleep() == "quit" then break end
    local pres = idle.newPresence(zone)
    queryPresence()                       -- sync real presence on active entry
    if cfg.play(mon, pres) == "quit" then break end
    -- "sleep" -> loop back to deepSleep (redraws the advert)
  end

  mon.setBackgroundColor(colors.black); mon.clear(); mon.setCursorPos(1, 1); mon.setTextScale(1)
end

return { run = run }
```

- [ ] **Step 2: Create `src/slot/slot_advert.lua`**

```lua
-- slot_advert.lua — the slot machine's static idle advertisement (COME PLAY / GET MONEY).
-- Drawn ONCE by idle_runner while the zone is empty. Default palette colours only; no animation.
local M = {}

function M.draw(mon)
  local w, h = mon.getSize()
  mon.setBackgroundColor(colors.blue)
  mon.clear()
  local function center(text, y, fg)
    mon.setTextColor(fg)
    mon.setCursorPos(math.floor((w - #text) / 2) + 1, y)
    mon.write(text)
  end
  center("COME PLAY", math.floor(h / 2), colors.yellow)
  center("GET MONEY", math.floor(h / 2) + 1, colors.white)
end

return M
```

- [ ] **Step 3: Remove slot's private rednet block**

In `src/slot/slot.lua`, delete this entire block (leave one blank line where it was):

```lua
local PROTO = "ccvegas"
local idle = require("idle_logic")

-- open rednet so the hub can wake/sleep us (the wired modem also carries the monitor)
local function findModem()
  local wired = peripheral.find("modem", function(_, m) return not m.isWireless() end)
  return wired or peripheral.find("modem")
end
local hasRednet = false
do local m = findModem(); if m then rednet.open(peripheral.getName(m)); hasRednet = true end end

-- Ask the hub for current presence. Its reply is an ordinary presence message, handled by the
-- deep-sleep / active event loops below. Syncs a freshly-woken station to reality: wakes one that
-- booted while a player was already in range, and lets a lever-wake from outside the detector range
-- sleep again after the round. Hub down -> no reply -> the station keeps its current assumption.
local function queryPresence()
  if hasRednet then rednet.broadcast({ kind = "presence?", zone = ZONE }, PROTO) end
end
```

- [ ] **Step 4: Remove slot's `drawIdleSign` and the now-dead `clearMonitor`**

In `src/slot/slot.lua`, delete this entire `drawIdleSign` block (it moved to slot_advert):

```lua
-- IDLE screen: a STATIC "COME PLAY / GET MONEY" advertisement shown while the zone is empty.
-- Drawn ONCE, then deepSleep blocks on os.pullEvent — no timer, zero idle cost (it advertises
-- instead of going black, but costs the same as sleeping).
local function drawIdleSign()
  topWin.setVisible(false)
  updateGradient(0)                       -- freeze the gradient at one phase (static, no drift)
  local bandH = math.ceil(topCv.h / #GRAD)
  for b = 1, #GRAD do
    topCv:fillRect(1, 1 + (b - 1) * bandH, topCv.w, bandH, GRAD[b])
  end
  topCv:render()
  topWin.setTextColor(YELLOW); topWin.setBackgroundColor(BLACK)
  local l1, l2 = "COME PLAY", "GET MONEY"
  topWin.setCursorPos(math.floor((tw - #l1) / 2) + 1, math.floor(th / 2))
  topWin.write(l1)
  topWin.setCursorPos(math.floor((tw - #l2) / 2) + 1, math.floor(th / 2) + 1)
  topWin.write(l2)
  topWin.setVisible(true)
end
```

Also delete the `clearMonitor` function — it becomes unused once the top-level loop and its final
cleanup are removed in Step 5 (the runner now owns the monitor reset; `restorePalette`, called by
`play` on quit, stays):

```lua
local function clearMonitor()
  restorePalette()
  topMon.setBackgroundColor(colors.black); topMon.clear()
end
```

- [ ] **Step 5: Replace `deepSleep` + `runActive` + the top-level loop with `play` + `run`**

In `src/slot/slot.lua`, delete everything from the line:

```lua
-- DEEP SLEEP: no timer. Block until a player is present (hub) or the lever is pulled cold.
```

through the final line:

```lua
print("Thanks for playing Slots!")
```

and replace it all with:

```lua
-- ACTIVE session: the 0.05s timer loop (attract -> spinning -> result), run by idle_runner while a
-- player is present. Returns "sleep" when the zone empties in attract (a spin always finishes first),
-- or "quit" on the operator's Q.
local function play(mon, pres)
  local state = "attract"
  local reels = newSpin(); for _, r in ipairs(reels) do r.stopped = true end
  local tick, spinTick, resultAt, result = 0, 0, nil, nil
  local armed = true       -- rising-edge guard so a held lever doesn't auto-respin

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
        if pres.gone() then return "sleep" end  -- zone emptied while idle
      end

      timer = os.startTimer(TICK)
    elseif ev[1] == "rednet_message" then
      pres.fromEvent(ev)                        -- update presence; sleep decision happens in attract
    elseif ev[1] == "key" and ev[2] == keys.q then
      restorePalette()
      return "quit"
    end
  end
end

require("idle_runner").run{
  name = "slot", monitor = topMon, zone = ZONE,
  wake = { side = SPIN_SIDE, level = SPIN_LEVEL }, play = play,
}
```

- [ ] **Step 6: Add `idle_runner` + `slot_advert` to the slot package**

In `src/packages.lua`, change the `slot` package `files` to:

```lua
    files = {
      { name = "subpixel",     path = "lib/subpixel.lua" },
      { name = "idle_logic",   path = "lib/idle_logic.lua" },
      { name = "idle_runner",  path = "lib/idle_runner.lua" },
      { name = "slot_logic",   path = "slot/slot_logic.lua" },
      { name = "slot_symbols", path = "slot/slot_symbols.lua" },
      { name = "slot_advert",  path = "slot/slot_advert.lua" },
      { name = "slot",         path = "slot/slot.lua" },
    },
```

- [ ] **Step 7: Syntax-check and run the local suite**

```bash
cd /d/KreaFolder/cctweaked
luajit -bl src/lib/idle_runner.lua >/dev/null && luajit -bl src/slot/slot_advert.lua >/dev/null && luajit -bl src/slot/slot.lua >/dev/null && luajit -bl src/packages.lua >/dev/null && echo "SYNTAX OK"
luajit test/test_idle_logic.lua && luajit test/test_slot_logic.lua && luajit test/test_subpixel.lua
```
Expected: `SYNTAX OK`, then `29 passed` / `21 passed` / `25 passed`, 0 failed.

- [ ] **Step 8: Commit**

```bash
git add src/lib/idle_runner.lua src/slot/slot_advert.lua src/slot/slot.lua src/packages.lua
git commit -m "feat(idle): shared idle_runner; slot uses it via play() + slot_advert

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

- [ ] **Step 9: In-game verification (user, deploy loop)**

`git push`; on the slot run `update slot` and restart it. Confirm behavior is unchanged from before the refactor: empty zone → COME PLAY / GET MONEY advert; player near → reels only; lever spins; a spin started then walking away finishes the round before sleeping; Q quits cleanly.

---

### Task 4: `pong_advert` + convert pong to the runner

Give pong the same idle model (it has none today): a static advert + a `play(mon, pres)` that sleeps when the zone empties.

**Files:**
- Create: `src/pong/pong_advert.lua`
- Modify: `src/pong/pong.lua`, `src/packages.lua`

**Interfaces:**
- Consumes: `idle_runner.run` (Task 3); `idle_logic.newPresence` (Task 2).
- Produces: `pong_advert.draw(mon)`; pong running under the runner.

- [ ] **Step 1: Create `src/pong/pong_advert.lua`**

```lua
-- pong_advert.lua — pong's static idle advertisement. Drawn ONCE by idle_runner while empty.
-- Default palette colours only; no animation.
local M = {}

function M.draw(mon)
  local w, h = mon.getSize()
  mon.setBackgroundColor(colors.black)
  mon.clear()
  local function center(text, y, fg)
    mon.setTextColor(fg)
    mon.setCursorPos(math.floor((w - #text) / 2) + 1, y)
    mon.write(text)
  end
  center("P O N G", math.floor(h / 2) - 1, colors.white)
  center("STEP ON A PLATE", math.floor(h / 2) + 1, colors.yellow)
end

return M
```

- [ ] **Step 2: Wrap pong's game loop as `play` and call the runner**

In `src/pong/pong.lua`, delete everything from the line:

```lua
resetBall(math.random() < 0.5 and -1 or 1)
```

through the final line:

```lua
print("Thanks for playing Pong!")
```

and replace it all with:

```lua
-- ACTIVE session: pong's physics loop, run by idle_runner while a player is present. Resets the
-- game each entry (fresh scores/ball). Returns "sleep" when the zone empties (no round to finish),
-- or "quit" on the operator's Q.
local function play(mon, pres)
  ls, rs = 0, 0
  lp = math.floor((H - PADDLE_H) / 2) + 1
  rp = lp
  resetBall(math.random() < 0.5 and -1 or 1)
  local timer = os.startTimer(TICK)
  draw()

  while true do
    local ev = { os.pullEvent() }
    if ev[1] == "timer" and ev[2] == timer then
      physics()
      draw()
      if pres.gone() then return "sleep" end   -- zone empty: stop (no round to finish)
      timer = os.startTimer(TICK)
    elseif ev[1] == "rednet_message" then
      pres.fromEvent(ev)
    elseif ev[1] == "key" and ev[2] == keys.q then
      return "quit"
    end
  end
end

require("idle_runner").run{ name = "pong", monitor = mon, zone = "all", play = play }
```

- [ ] **Step 3: Add pong's deps to the pong package**

In `src/packages.lua`, change the `pong` package `files` to:

```lua
    files = {
      { name = "idle_logic",  path = "lib/idle_logic.lua" },
      { name = "idle_runner", path = "lib/idle_runner.lua" },
      { name = "pong_advert", path = "pong/pong_advert.lua" },
      { name = "pong",        path = "pong/pong.lua" },
    },
```

- [ ] **Step 4: Syntax-check and run the local suite**

```bash
cd /d/KreaFolder/cctweaked
luajit -bl src/pong/pong_advert.lua >/dev/null && luajit -bl src/pong/pong.lua >/dev/null && luajit -bl src/packages.lua >/dev/null && echo "SYNTAX OK"
luajit test/test_idle_logic.lua && luajit test/test_slot_logic.lua && luajit test/test_subpixel.lua
```
Expected: `SYNTAX OK`, then `29 passed` / `21 passed` / `25 passed`, 0 failed.

- [ ] **Step 5: Commit**

```bash
git add src/pong/pong_advert.lua src/pong/pong.lua src/packages.lua
git commit -m "feat(pong): adopt idle_runner — static advert, sleep when zone empties

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

- [ ] **Step 6: In-game verification (user) + status docs**

`git push`; on the pong station run `update pong` and restart it. Confirm: empty zone → the PONG advert (static); player near (per the hub detector) → pong runs; walking away → it sleeps; Q quits cleanly. Confirm the slot still works after the folder move. Then update `README.md`'s Layout section to describe the new `src/` folders, and commit:

```bash
git add README.md
git commit -m "docs: README layout reflects per-station src/ folders

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Notes for the implementer

- **`ev[3]` is the message** in a `rednet_message` event (`{ "rednet_message", senderId, message, protocol }`); `presenceFor`/`fromEvent` take `ev[3]` / the whole `ev` respectively as written in the code blocks.
- **Do not change any `require()` calls.** Modules are required by bare name and land flat on the computer at deploy; the folder move is purely a `packages.lua` `path` concern.
- **`luajit -bl <file>`** only parses (CC globals never execute) — it catches syntax errors, not behavior. Runtime behavior is covered by the in-game steps.
- **slot.lua after Task 3** no longer needs `require("idle_logic")` directly (the runner and advert own presence); the reels/gradient/`drawTopFrame`/`restorePalette`/`newSpin` code and the `slot test` mode are unchanged.
- **pong.lua after Task 4** relies on the runner to open rednet; pong's `mon` (from `peripheral.find("monitor")`) and its plate polling are unchanged.
