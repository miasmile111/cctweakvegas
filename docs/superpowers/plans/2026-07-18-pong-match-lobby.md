# Pong match/lobby framework — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace pong's first-prototype shell with a reusable `lobby → play → results` match framework that every future 2–4 player game sits on.

**Architecture:** `lib/match.lua` owns the state machine (`lobby → play → flash → results`), the `mp_econ` instance and the event pump; a game supplies only a `play(ctx)` that draws its rally and returns scores. Pure logic lives in sibling `_logic` modules (the established `idle_logic`/`idle_runner` split) so the state machine, the counter easing, the relay mapping and the pong physics are all unit-testable with no peripherals.

**Tech Stack:** Lua 5.1 / CraftOS (CC:Tweaked), `luajit` for offline unit tests, `test/runner.lua` assert harness.

**Spec:** `docs/superpowers/specs/2026-07-18-pong-match-lobby-design.md`

## Global Constraints

- **Lua 5.1 only.** No `goto`, no integer division `//`, no bitwise operators, no `#!` shebangs. `table.unpack` is `unpack`.
- **One program per file; filename = the in-world program name.** Deploy flattens every file by name, so `require("match")` never encodes the folder.
- **Header comment on every file:** what it does, how to run it, wiring notes.
- **Every new `src/` file must be added to `src/packages.lua`** under the `pong` package or it will not install in-world.
- **Pure modules must not reference CC globals** (`colors`, `peripheral`, `redstone`, `os.pullEvent`) — they run under bare `luajit` in tests where those do not exist.
- **Tests:** `package.path = "src/lib/?.lua;test/?.lua;" .. package.path` at the top, `local t = require("runner")`, `t.eq`/`t.ok`, `t.done()` at the end. Run one file with `luajit test/test_<name>.lua`.
- **A test that cannot fail is worse than no test** — it claims coverage it does not have. For each
  assertion, ask whether it would fail if the production line it covers were deleted or inverted.
  This project has shipped vacuous tests twice (see the SDD ledgers), and Task 1's original test
  block was a third: it passed against a stub that ignored the ramp entirely. When a module's whole
  purpose is a *behaviour over time*, assert the behaviour, not just its endpoints.
- **Syntax check every changed Lua file:** `luajit -bl <file> > /dev/null`.
- **Canvas geometry (fixed, formula-verified):** 3×2 blocks @ `setTextScale(0.5)` = **57×24 cells**.
- **Screens ship debug-grade native text this session.** No subpixel art, no `pixelfont`. The art pass is a separate effort against the spec's UI contract.
- **Currency renders as `$`.**
- **`match` consumes `mp_econ`, never `wallet` directly.**

---

## File Structure

| File | Responsibility | Status |
|------|----------------|--------|
| `src/lib/counter.lua` | Eased delta-tinted numeric counter. Pure. | Create |
| `src/lib/controls.lua` | Redstone abstraction: relay peripheral or computer sides. | Create |
| `src/lib/match_logic.lua` | Pure state-machine helpers: ready gating, balance capture, result rows, deny copy. | Create |
| `src/lib/lobby.lua` | The lobby screen: layout constants, hit test, draw. | Create |
| `src/lib/match.lua` | The runner: event pump, phase loop, results screen. Owns `mp_econ`. | Create |
| `src/pong/pong_logic.lua` | Pure pong physics + first-to-5 scoring. | Create |
| `src/pong/pong.lua` | Station file: config, controls, rally render, hands `play` to `match`. | Rewrite |
| `src/lib/mp_econ.lua` | Add `reset()`. | Modify |
| `src/packages.lua` | Add the new files to the `pong` package. | Modify |

**Deviation from the spec, deliberate and additive:** the spec's file list named `lib/match.lua` and `pong/pong.lua` without their pure siblings. This plan adds **`lib/match_logic.lua`** and **`pong/pong_logic.lua`**, following the repository's own `idle_logic`/`idle_runner` and `slot_logic`/`slot.lua` precedent. Without them the spec's own testing section ("`match.lua` state machine — phase transitions… Pong scoring — first to 5 terminates") is not satisfiable, because the state machine and the physics would be trapped behind an event pump and a monitor. No behaviour changes; it is a decomposition choice.

**Second deviation:** the spec sketched `counter.tint()` returning `YELLOW`/`PINK`/`WHITE`. A pure module cannot reference the `colors` global (it does not exist under `luajit`). `tint()` returns the symbolic strings `"up"`/`"down"`/`"rest"`; the caller maps them to `colors.yellow`/`colors.pink`/`colors.white`. Same behaviour, testable.

---

### Task 1: `lib/counter.lua` — the eased delta-tinted counter

**Files:**
- Create: `src/lib/counter.lua`
- Test: `test/test_counter.lua`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `counter.easeToward(cur, target) -> number`
  - `counter.new{ value = number } -> instance`
  - `instance.setTarget(n)`, `instance.step()`, `instance.value() -> number`, `instance.target() -> number`, `instance.atRest() -> boolean`, `instance.tint() -> "up"|"down"|"rest"`

- [ ] **Step 1: Write the failing test**

Create `test/test_counter.lua`:

```lua
-- test_counter.lua — the eased delta-tinted counter (extracted from cage.lua).
-- The tint IS the feedback: a player reads "being paid" / "spending" before reading the digits.
package.path = "src/lib/?.lua;test/?.lua;" .. package.path
local t = require("runner")
local counter = require("counter")

-- ---- easeToward: the raw ramp ----
do
  t.eq(counter.easeToward(10, 10), 10, "at rest, easeToward is a fixed point")
  t.ok(counter.easeToward(0, 100) > 0, "climbs toward a higher target")
  t.ok(counter.easeToward(100, 0) < 100, "falls toward a lower target")
  t.eq(counter.easeToward(0, 1), 1, "a 1-unit gap closes in one step, never overshoots")
  t.eq(counter.easeToward(1, 0), 0, "a 1-unit fall closes in one step")
end

-- ---- convergence: it must ALWAYS arrive, and never pass the target ----
do
  local c = counter.new{ value = 100 }
  c.setTarget(90)
  local n = 0
  while not c.atRest() and n < 500 do c.step(); n = n + 1 end
  t.eq(c.value(), 90, "a falling counter converges exactly on the target")
  t.ok(n < 500, "convergence terminates (it did not spin)")
end

do
  local c = counter.new{ value = 90 }
  c.setTarget(110)
  local n = 0
  while not c.atRest() and n < 500 do c.step(); n = n + 1 end
  t.eq(c.value(), 110, "a climbing counter converges exactly on the target")
end

-- Overshoot is the failure that matters: a counter that sails past the target and eases back
-- shows the player a balance they never had.
do
  local c = counter.new{ value = 0 }
  c.setTarget(1000)
  for _ = 1, 500 do
    c.step()
    t.ok(c.value() <= 1000, "climbing never exceeds the target")
    if c.atRest() then break end
  end
end

-- ---- tint ----
do
  local c = counter.new{ value = 100 }
  t.eq(c.tint(), "rest", "equal value and target reads at rest (white)")
  c.setTarget(110)
  t.eq(c.tint(), "up", "climbing tints up (gold)")
  c.setTarget(90)
  t.eq(c.tint(), "down", "falling tints down (pink, not red)")
  c.setTarget(100)
  t.eq(c.tint(), "rest", "returning to the current value reads at rest again")
end

-- ---- a fresh counter starts at rest on its own value ----
do
  local c = counter.new{ value = 42 }
  t.eq(c.value(), 42, "value() is the seeded value")
  t.eq(c.target(), 42, "target defaults to the seeded value")
  t.ok(c.atRest(), "a fresh counter is at rest")
  c.step()
  t.eq(c.value(), 42, "stepping an at-rest counter changes nothing")
end

-- ---- defaults ----
do
  local c = counter.new()
  t.eq(c.value(), 0, "no cfg defaults to 0")
end

-- ---- THE RAMP ITSELF ----
-- Without this block the whole module is unconstrained: a stub `easeToward(c, t) return t end` --
-- an instant snap with no easing at all -- passes every other assertion in this file. That was
-- proven empirically in review, so these assertions are the ones actually holding the module's
-- reason for existing in place.
do
  t.ok(counter.easeToward(0, 1000) < 1000, "a large gap does NOT jump straight to the target")
  t.eq(counter.easeToward(0, 1000), 42, "a 1000 gap steps by ceil(1000/24) = 42, not by 1000")
  t.eq(counter.easeToward(1000, 0), 958, "and the same ramp applies falling")

  local c = counter.new{ value = 0 }
  c.setTarget(1000)
  local n = 0
  while not c.atRest() and n < 500 do c.step(); n = n + 1 end
  t.ok(n >= 20, "a large gap takes a RAMP of steps (~24), not one -- easing IS the module's purpose")
end

t.done()
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `luajit test/test_counter.lua`
Expected: FAIL — `module 'counter' not found`.

- [ ] **Step 3: Write the implementation**

Create `src/lib/counter.lua`:

```lua
-- counter.lua — an eased, direction-tinted number. Pure: no peripherals, no drawing, no colours.
--
-- Extracted from cage.lua, where a balance that merely SNAPPED to its new value read as a glitch.
-- Easing it over ~24 frames and tinting it by direction turns a number into feedback: the player
-- reads "being paid" / "spending" before reading the digits.
--
--   local c = counter.new{ value = 100 }
--   c.setTarget(90); c.step(); c.value(); c.tint()   --> 90-ish, "down"
--
-- tint() returns SYMBOLS, not colours: this module runs under bare luajit in tests, where the CC
-- `colors` global does not exist. The caller maps "up"->yellow, "down"->pink, "rest"->white.
-- PINK, not red: stock red is luminance 114 against the cage's ~118 gold band, so a red number
-- vanishes on half the gradient drift -- and a cell holds only 2 colours, so no outline can save it.
local M = {}

local RAMP = 24   -- frames to close a gap; the slot's win count-up uses the same ramp

-- Step `cur` one frame toward `target`. Clamps, so it can never overshoot -- an overshoot would
-- show the player a balance they never had.
function M.easeToward(cur, target)
  if cur == target then return cur end
  local step = math.max(1, math.ceil(math.abs(target - cur) / RAMP))
  if cur < target then return math.min(target, cur + step) end
  return math.max(target, cur - step)
end

-- cfg.value = the starting (and initial target) value. Defaults to 0.
function M.new(cfg)
  cfg = cfg or {}
  local start = cfg.value or 0
  local self = { _v = start, _t = start }

  function self.setTarget(n) self._t = n end
  function self.step()       self._v = M.easeToward(self._v, self._t) end
  function self.value()      return self._v end
  function self.target()     return self._t end
  function self.atRest()     return self._v == self._t end

  function self.tint()
    if self._v < self._t then return "up"   end   -- climbing: gold
    if self._v > self._t then return "down" end   -- falling: pink
    return "rest"                                 -- white
  end

  return self
end

return M
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `luajit test/test_counter.lua`
Expected: PASS — `N passed, 0 failed`.

- [ ] **Step 5: Syntax check**

Run: `luajit -bl src/lib/counter.lua > /dev/null`
Expected: no output, exit 0.

- [ ] **Step 6: Commit**

```bash
git add src/lib/counter.lua test/test_counter.lua
git commit -m "feat(counter): eased delta-tinted counter extracted from cage"
```

---

### Task 2: `lib/controls.lua` — the redstone/relay abstraction

**Files:**
- Create: `src/lib/controls.lua`
- Test: `test/test_controls.lua`

**Interfaces:**
- Consumes: nothing.
- Produces: `controls.new{ cfg = <parsed station cfg table>, inputs = {"p1_up", ...}, deps = { peripheral = ..., redstone = ... } } -> instance`; `instance.get(name) -> boolean`; `instance.sideOf(name) -> string`; `instance.sourceName() -> string`.

**Background:** verified against tweaked.cc — peripheral type `redstone_relay`, CC:Tweaked 1.114.0+, methods **name-identical** to the built-in `redstone` API (`getInput(side)`). That is what makes this abstraction nearly free: a source is either the global `redstone` table or `peripheral.wrap(name)`, and they are duck-type identical.

`deps` exists solely so the tests can inject fake `peripheral`/`redstone` tables. Production callers omit it.

- [ ] **Step 1: Write the failing test**

Create `test/test_controls.lua`:

```lua
-- test_controls.lua — logical input names -> a redstone source (relay peripheral or computer sides).
--
-- The rule this file defends: NO peripheral name is ever hardcoded in a station. CC does not hand
-- identically-built stations identical peripheral names, so wiring lives in the station's .cfg and
-- discovery is BY TYPE. An explicit name in cfg always wins over discovery.
package.path = "src/lib/?.lua;test/?.lua;" .. package.path
local t = require("runner")
local controls = require("controls")

-- ---- fakes -----------------------------------------------------------------
local function fakeRedstone(levels)
  return { getInput = function(side) return levels[side] == true end }
end

-- names = ordered peripheral names; types = name -> type string; levels = name -> {side->bool}
local function fakePeripheral(names, types, levels)
  return {
    getNames = function() return names end,
    hasType  = function(n, ty) return types[n] == ty end,
    wrap     = function(n)
      if not types[n] then return nil end
      return { getInput = function(side) return (levels[n] or {})[side] == true end }
    end,
  }
end

local INPUTS = { "p1_up", "p1_down", "p2_up", "p2_down" }
local WIRING = { p1_up = "left", p1_down = "front", p2_up = "right", p2_down = "back" }

local function cfgWith(extra)
  local c = {}
  for k, v in pairs(WIRING) do c[k] = v end
  for k, v in pairs(extra or {}) do c[k] = v end
  return c
end

-- ---- source = computer ----
do
  local rs = fakeRedstone{ left = true, back = true }
  local ctl = controls.new{
    cfg = cfgWith{ source = "computer" }, inputs = INPUTS,
    deps = { redstone = rs, peripheral = fakePeripheral({}, {}, {}) },
  }
  t.eq(ctl.get("p1_up"), true, "computer source reads the built-in redstone table")
  t.eq(ctl.get("p1_down"), false, "an unpowered side reads false")
  t.eq(ctl.get("p2_down"), true, "back is powered")
  t.eq(ctl.sourceName(), "computer", "sourceName reports the computer")
end

-- ---- source omitted defaults to computer (a station with no relay must still work) ----
do
  local rs = fakeRedstone{ left = true }
  local ctl = controls.new{
    cfg = cfgWith{}, inputs = INPUTS,
    deps = { redstone = rs, peripheral = fakePeripheral({}, {}, {}) },
  }
  t.eq(ctl.sourceName(), "computer", "no source= in cfg defaults to the computer's own sides")
  t.eq(ctl.get("p1_up"), true, "and it reads")
end

-- ---- source = relay: discovered BY TYPE, not by name ----
do
  local per = fakePeripheral(
    { "monitor_0", "drive_1", "redstone_relay_3" },
    { monitor_0 = "monitor", drive_1 = "drive", redstone_relay_3 = "redstone_relay" },
    { redstone_relay_3 = { left = true } })
  local ctl = controls.new{
    cfg = cfgWith{ source = "relay" }, inputs = INPUTS,
    deps = { redstone = fakeRedstone{}, peripheral = per },
  }
  t.eq(ctl.sourceName(), "redstone_relay_3", "relay is discovered by TYPE -- the index is not 0")
  t.eq(ctl.get("p1_up"), true, "reads through the discovered relay")
  t.eq(ctl.get("p2_up"), false, "an unpowered relay side reads false")
end

-- ---- an explicit peripheral name WINS over discovery ----
do
  local per = fakePeripheral(
    { "redstone_relay_0", "redstone_relay_1" },
    { redstone_relay_0 = "redstone_relay", redstone_relay_1 = "redstone_relay" },
    { redstone_relay_0 = {}, redstone_relay_1 = { left = true } })
  local ctl = controls.new{
    cfg = cfgWith{ source = "redstone_relay_1" }, inputs = INPUTS,
    deps = { redstone = fakeRedstone{}, peripheral = per },
  }
  t.eq(ctl.sourceName(), "redstone_relay_1", "a named source is used verbatim")
  t.eq(ctl.get("p1_up"), true, "and it is the named one, not the first discovered")
end

-- ---- FAIL LOUD: a missing relay is a hard stop, never a silently dead paddle ----
do
  local per = fakePeripheral({ "monitor_0" }, { monitor_0 = "monitor" }, {})
  local ok, err = pcall(function()
    controls.new{ cfg = cfgWith{ source = "relay" }, inputs = INPUTS,
                  deps = { redstone = fakeRedstone{}, peripheral = per } }
  end)
  t.eq(ok, false, "source=relay with no relay attached errors")
  t.ok(tostring(err):find("redstone_relay"), "and the error names what it looked for")
end

do
  local per = fakePeripheral({}, {}, {})
  local ok, err = pcall(function()
    controls.new{ cfg = cfgWith{ source = "nope_0" }, inputs = INPUTS,
                  deps = { redstone = fakeRedstone{}, peripheral = per } }
  end)
  t.eq(ok, false, "a named source that is not attached errors")
  t.ok(tostring(err):find("nope_0"), "and the error names it")
end

-- ---- FAIL LOUD: an unmapped or nonsense input is a hard stop ----
do
  local ok, err = pcall(function()
    controls.new{ cfg = { source = "computer", p1_up = "left" }, inputs = INPUTS,
                  deps = { redstone = fakeRedstone{}, peripheral = fakePeripheral({}, {}, {}) } }
  end)
  t.eq(ok, false, "an input with no cfg line errors")
  t.ok(tostring(err):find("p1_down"), "and the error names the MISSING logical input")
end

do
  local ok, err = pcall(function()
    controls.new{ cfg = cfgWith{ p2_up = "sideways" }, inputs = INPUTS,
                  deps = { redstone = fakeRedstone{}, peripheral = fakePeripheral({}, {}, {}) } }
  end)
  t.eq(ok, false, "a non-side value errors")
  t.ok(tostring(err):find("sideways"), "and the error quotes the bad value")
end

-- ---- get() on an unknown name errors rather than silently reading false ----
do
  local ctl = controls.new{
    cfg = cfgWith{ source = "computer" }, inputs = INPUTS,
    deps = { redstone = fakeRedstone{}, peripheral = fakePeripheral({}, {}, {}) },
  }
  t.eq(ctl.sideOf("p1_up"), "left", "sideOf exposes the resolved wiring for diagnostics")
  local ok = pcall(function() return ctl.get("p3_up") end)
  t.eq(ok, false, "get() on an unconfigured name errors -- a typo must not read as 'not pressed'")
end

t.done()
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `luajit test/test_controls.lua`
Expected: FAIL — `module 'controls' not found`.

- [ ] **Step 3: Write the implementation**

Create `src/lib/controls.lua`:

```lua
-- controls.lua — logical input names -> a redstone source. The station's diegetic input layer.
--
--   local ctl = controls.new{ cfg = CFG, inputs = { "p1_up", "p1_down", "p2_up", "p2_down" } }
--   if ctl.get("p1_up") then ... end
--
-- WHY THIS EXISTS: pong's plates moved from the computer's own sides onto a REDSTONE RELAY, and
-- `redstone.getInput(side)` reads the computer, which now never changes state. A relay is a
-- peripheral whose methods are NAME-IDENTICAL to the built-in redstone API (verified: tweaked.cc,
-- peripheral type `redstone_relay`, CC:Tweaked 1.114.0+), so a "source" is simply either the global
-- `redstone` table or `peripheral.wrap(name)` -- duck-type identical, which is what makes this
-- abstraction nearly free.
--
-- WIRING LIVES IN THE STATION'S .cfg, NEVER HERE. CC does not hand identically-built stations
-- identical peripheral names, so `source = relay` discovers the relay BY TYPE and an explicit name
-- in cfg always wins. Nothing in a station file may hardcode a peripheral name.
--
--   source  = relay        # or a peripheral name, or "computer" (the default)
--   p1_up   = left
--   p1_down = front
--
-- Every failure here is LOUD. A miswired station must stop at boot naming what it could not find --
-- a paddle that silently reads "not pressed" forever is the worst possible failure for a game.
local M = {}

local RELAY_TYPE = "redstone_relay"
local SIDES = { top = true, bottom = true, left = true, right = true, front = true, back = true }

-- cfg.cfg     = the parsed station .cfg table (source + one line per logical input)
-- cfg.inputs  = the logical names this station REQUIRES; every one must be mapped
-- cfg.deps    = { peripheral =, redstone = } test injection only; production omits it
function M.new(cfg)
  cfg = cfg or {}
  local conf   = cfg.cfg or {}
  local deps   = cfg.deps or {}
  local per    = deps.peripheral or peripheral
  local rsApi  = deps.redstone or redstone
  local wanted = cfg.inputs or {}

  local sourceCfg = conf.source or "computer"
  local src, srcName

  if sourceCfg == "computer" then
    src, srcName = rsApi, "computer"
  elseif sourceCfg == "relay" then
    for _, name in ipairs(per.getNames()) do
      if per.hasType(name, RELAY_TYPE) then
        src, srcName = per.wrap(name), name
        break
      end
    end
    if not src then
      error("controls: source=relay but no " .. RELAY_TYPE .. " peripheral is attached", 0)
    end
  else
    src, srcName = per.wrap(sourceCfg), sourceCfg
    if not src then
      error("controls: no peripheral named '" .. tostring(sourceCfg) .. "'", 0)
    end
  end

  local map = {}
  for _, name in ipairs(wanted) do
    local side = conf[name]
    if not side then
      error("controls: input '" .. name .. "' has no line in the station .cfg", 0)
    end
    if not SIDES[side] then
      error("controls: input '" .. name .. "' = '" .. tostring(side) .. "' is not a side "
            .. "(top/bottom/left/right/front/back)", 0)
    end
    map[name] = side
  end

  local self = {}

  function self.get(name)
    local side = map[name]
    if not side then
      error("controls: unknown input '" .. tostring(name) .. "'", 0)
    end
    return src.getInput(side) and true or false
  end

  function self.sideOf(name) return map[name] end
  function self.sourceName() return srcName end

  return self
end

return M
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `luajit test/test_controls.lua`
Expected: PASS.

- [ ] **Step 5: Syntax check**

Run: `luajit -bl src/lib/controls.lua > /dev/null`
Expected: no output, exit 0.

- [ ] **Step 6: Commit**

```bash
git add src/lib/controls.lua test/test_controls.lua
git commit -m "feat(controls): redstone relay/computer-side input abstraction"
```

---

### Task 3: `mp_econ.reset()` — close the "done is terminal" bug

**Files:**
- Modify: `src/lib/mp_econ.lua` (add `self.reset` after `self.finish`, before `self.status`)
- Test: `test/test_mp_econ.lua` (append; keep the existing 77 assertions green)

**Interfaces:**
- Consumes: the existing `mp_econ.new` instance.
- Produces: `instance.reset()` — sets `phase = "lobby"`, `pot = 0`, and clears every seat's `antedId`/`anted`. Returns nothing.

**Why:** `finish()` leaves `phase = "done"` and nothing ever moves it back, so a second `start()` on the same instance is refused forever. That is the observed in-world "the game did not reset". The fix belongs in the engine, not as a workaround in `match`.

- [ ] **Step 1: Write the failing test**

Append to `test/test_mp_econ.lua`, immediately **before** the final `t.done()` line:

```lua
-- ---- reset(): "done" must not be terminal -----------------------------------
-- finish() parks the instance in "done". Without reset() a station can play exactly ONE match and
-- then refuses every GO forever ("already playing" / a dead phase) -- the in-world reset bug.
do
  reset(); seat{ "alice", "bob" }
  local e = mp.new{ ante = 10 }
  t.eq(e.start(), "staked", "first match antes")
  e.finish{ [1] = 5, [2] = 3 }
  t.eq(e.phase, "done", "finish parks in done")

  e.reset()
  t.eq(e.phase, "lobby", "reset returns the phase to lobby")
  t.eq(e.pot, 0, "reset zeroes the pot")
  t.eq(e.seats[1].antedId, nil, "reset clears seat 1's anted id")
  t.eq(e.seats[2].antedId, nil, "reset clears seat 2's anted id")
  t.eq(e.seats[1].anted, 0, "reset zeroes seat 1's anted amount")

  t.eq(e.start(), "staked", "and a SECOND match can start on the same instance")
  t.eq(e.pot, 20, "the second pot is a full pot, not a leftover")
end

-- reset() mid-match must not silently eat a live pot: it is a lobby-return, not a resolver.
-- match.lua always finish()es before reset()ing; this asserts reset is not doing money work.
do
  reset(); seat{ "alice", "bob" }
  local e = mp.new{ ante = 10 }
  e.start()
  local creditsBefore = creditsTo("alice") + creditsTo("bob")
  e.reset()
  t.eq(creditsTo("alice") + creditsTo("bob"), creditsBefore, "reset pays nobody -- it is not finish()")
  t.eq(e.phase, "lobby", "and it still returns to lobby")
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `luajit test/test_mp_econ.lua`
Expected: FAIL — `attempt to call field 'reset' (a nil value)`.

- [ ] **Step 3: Write the implementation**

In `src/lib/mp_econ.lua`, insert this function immediately after the closing `end` of `self.finish` and immediately before `function self.status()`:

```lua
  -- Return to the lobby so the SAME instance can run another match. Without this, `finish` parks
  -- the instance in "done" forever and the station plays exactly one match per boot.
  --
  -- This is a lobby-return, NOT a resolver: it deliberately pays nobody. Any live pot must be
  -- settled with finish() FIRST -- calling reset() on a playing instance forfeits the pot silently,
  -- which is why match.lua always resolves before it resets.
  function self.reset()
    for _, s in ipairs(self.seats) do s.antedId, s.anted = nil, 0 end
    self.pot = 0
    self.phase = "lobby"
  end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `luajit test/test_mp_econ.lua`
Expected: PASS — the pre-existing assertions plus the new ones, `0 failed`.

- [ ] **Step 5: Syntax check**

Run: `luajit -bl src/lib/mp_econ.lua > /dev/null`
Expected: no output, exit 0.

- [ ] **Step 6: Commit**

```bash
git add src/lib/mp_econ.lua test/test_mp_econ.lua
git commit -m "fix(mp_econ): add reset() so 'done' is not terminal"
```

---

### Task 4: `lib/match_logic.lua` — pure state-machine helpers

**Files:**
- Create: `src/lib/match_logic.lua`
- Test: `test/test_match_logic.lua`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `match_logic.newReady(n) -> { [1..n] = false }`
  - `match_logic.toggle(ready, i) -> ready` (mutates and returns; ignores out-of-range `i`)
  - `match_logic.allReady(ready) -> boolean` (false for an empty table)
  - `match_logic.captureBalances(status) -> { [seat] = number|nil }`
  - `match_logic.denyMessage(reason, seat) -> string`
  - `match_logic.staked(potBefore) -> boolean`
  - `match_logic.freeResultText(seatLabels, scores) -> string`
  - `match_logic.resultRows(seatLabels, before, status, scores) -> { { seat, label, id, from, to } }`

- [ ] **Step 1: Write the failing test**

Create `test/test_match_logic.lua`:

```lua
-- test_match_logic.lua — the pure half of the match state machine.
--
-- The rule with money behind it: READY IS PER-MATCH CONSENT, NEVER A STICKY FLAG. If ready survived
-- a match, a player who walked away is still "ready" and the next GO antes their card for a game
-- they are not at. Every path back to the lobby clears it.
package.path = "src/lib/?.lua;test/?.lua;" .. package.path
local t = require("runner")
local ml = require("match_logic")

-- ---- ready flags ----
do
  local r = ml.newReady(2)
  t.eq(#r, 2, "newReady sizes to the seat count")
  t.eq(r[1], false, "seats start not ready")
  t.eq(ml.allReady(r), false, "nobody ready -> GO is not live")

  ml.toggle(r, 1)
  t.eq(r[1], true, "toggle sets")
  t.eq(ml.allReady(r), false, "ONE seat ready is not enough -- GO stays inert")

  ml.toggle(r, 2)
  t.eq(ml.allReady(r), true, "both ready -> GO goes live")

  ml.toggle(r, 1)
  t.eq(r[1], false, "toggle clears")
  t.eq(ml.allReady(r), false, "un-readying takes GO back down")
end

do
  t.eq(ml.allReady(ml.newReady(0)), false, "a zero-seat station never enables GO")
end

do
  local r = ml.newReady(2)
  ml.toggle(r, 5)
  t.eq(ml.allReady(r), false, "an out-of-range toggle is ignored, not an error")
  ml.toggle(r, 0)
  t.eq(ml.allReady(r), false, "seat 0 is ignored too")
end

-- ---- balance capture: the results screen replays money that ALREADY moved ----
do
  local status = { seats = {
    { player = "alice", balance = 100 },
    { player = nil,     balance = nil },
  } }
  local before = ml.captureBalances(status)
  t.eq(before[1], 100, "a carded seat's balance is captured")
  t.eq(before[2], nil, "an anonymous seat captures nil, not 0 -- it has no balance to replay")
end

-- ---- deny copy: the three states must never collapse into one lie ----
do
  t.ok(ml.denyMessage("timeout", 2):find("HUB OFFLINE"),
       "a hub timeout says HUB OFFLINE, never INSUFFICIENT -- telling a player holding $500 they "
    .. "are broke is a lie about money")
  t.ok(ml.denyMessage("timeout", 2):find("nobody charged"), "and reassures that nobody was charged")
  t.ok(ml.denyMessage("already playing", 1):find("ALREADY RUNNING"), "double-GO is its own message")
  t.ok(ml.denyMessage("insufficient", 2):find("SEAT 2"), "a funds deny names the seat")
  t.ok(ml.denyMessage("insufficient", 2):find("REFUNDED"),
       "and says the other antes came back -- rule 1, never a partial pot")
  t.ok(ml.denyMessage("unknown", 3):find("SEAT 3"), "an unknown reason still names the seat")
end

-- The message line is native cell-text on a 57-cell canvas. Capping at 55 keeps one cell of margin
-- at each edge; an ASCII hyphen is used throughout because an em dash is not reliably present in
-- CC's charset and renders as a box.
do
  for _, r in ipairs({ "timeout", "already playing", "insufficient", "unknown" }) do
    local m = ml.denyMessage(r, 2)
    t.ok(#m <= 55, "deny copy for '" .. r .. "' fits the 55-cell cap")
    t.eq(m:find("\226"), nil, "deny copy for '" .. r .. "' is pure ASCII (no em dash)")
  end
  t.ok(#ml.denyMessage(("x"):rep(200), 2) <= 55, "even a pathological reason string is capped")
end

-- ---- staked vs free ----
do
  t.eq(ml.staked(20), true, "a pot means the match was staked")
  t.eq(ml.staked(0), false, "no pot means a free match")
end

-- ---- free result text ----
do
  local labels = { "LEFT", "RIGHT" }
  t.eq(ml.freeResultText(labels, { [1] = 5, [2] = 3 }), "LEFT PLAYER WON", "left takes it")
  t.eq(ml.freeResultText(labels, { [1] = 2, [2] = 5 }), "RIGHT PLAYER WON", "right takes it")
  t.eq(ml.freeResultText(labels, { [1] = 5 }),          "LEFT PLAYER WON",
       "a missing score counts as 0")
  t.eq(ml.freeResultText(labels, { [1] = 3, [2] = 3 }), "LEFT PLAYER WON",
       "a tie goes to the lowest seat -- pong cannot tie at first-to-5, this is only a guard")
end

-- ---- the win flash: the beat between the last rally point and the money ----
do
  local labels = { "LEFT", "RIGHT" }
  local carded = { seats = { { player = "alice" }, { player = "bob" } } }
  t.eq(ml.winnerText(labels, carded, { [1] = 5, [2] = 3 }), "alice WON!",
       "a carded winner is named by their card id -- the player sees THEIR name, not a seat")
  t.eq(ml.winnerText(labels, carded, { [1] = 2, [2] = 5 }), "bob WON!", "and so is seat 2")
end

do
  -- An anonymous winner has no id to show, so it falls back to the seat label. It must never
  -- render "anon WON!" or an empty name.
  local anon = { seats = { { player = nil }, { player = "bob" } } }
  t.eq(ml.winnerText({ "LEFT", "RIGHT" }, anon, { [1] = 5, [2] = 1 }), "LEFT WON!",
       "an anonymous winner falls back to the seat label")
end

do
  local long = { seats = { { player = "bartholomew-the-longwinded" }, { player = "bob" } } }
  local txt = ml.winnerText({ "LEFT", "RIGHT" }, long, { [1] = 5, [2] = 0 })
  t.ok(#txt <= 24, "a long id is truncated so the flash panel cannot overflow the canvas")
  t.ok(txt:find("WON!"), "and it still says WON!")
end

-- ---- result rows: from balanceAtGO to balanceNow ----
do
  local labels = { "LEFT", "RIGHT" }
  local before = { [1] = 100, [2] = 100 }
  local status = { seats = {
    { player = "alice", balance = 110 },   -- anted 10, won the 20 pot
    { player = "bob",   balance = 90  },   -- anted 10, lost it
  } }
  local rows = ml.resultRows(labels, before, status, { [1] = 5, [2] = 3 })

  t.eq(#rows, 2, "one row per seat")
  t.eq(rows[1].label, "LEFT", "row carries the seat label")
  t.eq(rows[1].id, "alice", "row carries the card id")
  t.eq(rows[1].from, 100, "the winner's counter starts where it was at GO")
  t.eq(rows[1].to, 110, "and climbs past its own start -- ante back, plus the pot")
  t.eq(rows[2].from, 100, "the loser starts at the same place")
  t.eq(rows[2].to, 90, "and drains by the ante")
end

do
  -- An anonymous seat has no money to replay; it must still appear, so the screen shows a seat
  -- that played rather than silently omitting a player.
  local rows = ml.resultRows({ "LEFT", "RIGHT" },
    { [1] = 100 },
    { seats = { { player = "alice", balance = 90 }, { player = nil, balance = nil } } },
    { [1] = 5, [2] = 1 })
  t.eq(#rows, 2, "the anonymous seat still gets a row")
  t.eq(rows[2].id, nil, "with no id")
  t.eq(rows[2].from, nil, "and nothing to animate")
  t.eq(rows[2].to, nil, "at either end")
end

t.done()
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `luajit test/test_match_logic.lua`
Expected: FAIL — `module 'match_logic' not found`.

- [ ] **Step 3: Write the implementation**

Create `src/lib/match_logic.lua`:

```lua
-- match_logic.lua — the pure half of the match state machine. No peripherals, no drawing, no
-- events; match.lua is the impure runner around it (the idle_logic / idle_runner split).
--
-- Everything here is a decision the state machine makes, hoisted out so it can be tested without
-- a monitor, a hub or an event pump.
local M = {}

-- ---- ready flags -----------------------------------------------------------
-- READY IS PER-MATCH CONSENT, NEVER A STICKY FLAG. If it survived a match, a player who walked away
-- is still "ready" and the next GO antes their card for a game they are not at. That is a money
-- bug, not a UI wrinkle -- every path back to the lobby calls newReady().
function M.newReady(n)
  local r = {}
  for i = 1, (n or 0) do r[i] = false end
  return r
end

function M.toggle(ready, i)
  if ready[i] ~= nil then ready[i] = not ready[i] end
  return ready
end

-- GO is live only when EVERY seat has consented. An empty table is never ready -- a station with no
-- seats must not present a live GO.
function M.allReady(ready)
  if #ready == 0 then return false end
  for i = 1, #ready do
    if not ready[i] then return false end
  end
  return true
end

-- ---- balance capture -------------------------------------------------------
-- The results screen REPLAYS a completed transaction: the ante was debited at GO and the pot
-- credited at finish, so by the time results draws, the money has already moved. Capture each
-- seat's balance immediately BEFORE mp_econ.start() or there is nothing honest to animate from.
-- An anonymous seat captures nil, not 0: it has no balance, and 0 would animate a drain from broke.
function M.captureBalances(status)
  local out = {}
  for i, s in ipairs(status.seats) do out[i] = s.balance end
  return out
end

-- ---- deny copy -------------------------------------------------------------
-- The three deny states must never collapse into one. Telling a player holding $500 that they are
-- INSUFFICIENT because the hub was unreachable is a lie about money, and this project has shipped
-- that bug twice (kb/economy.md lesson 7).
--
-- ASCII ONLY, capped at 55. The line is native cell-text on a 57-cell canvas (one cell of margin
-- each side), and an em dash is not reliably in CC's charset -- it renders as a box.
M.MSG_MAX = 55

function M.denyMessage(reason, seat)
  local msg
  if reason == "timeout" then
    msg = "HUB OFFLINE - nobody charged"
  elseif reason == "already playing" then
    msg = "MATCH ALREADY RUNNING"
  else
    msg = ("SEAT %d: %s - all antes REFUNDED"):format(seat or 0, tostring(reason):upper())
  end
  return msg:sub(1, M.MSG_MAX)
end

-- ---- results ---------------------------------------------------------------
function M.staked(potBefore)
  return (potBefore or 0) > 0
end

-- Best score wins; a tie takes the lowest seat index. Pong cannot tie at first-to-5, so this is a
-- guard for an aborted match (both on 0), not a tournament rule.
local function bestSeat(n, scores)
  local best, bestScore = 1, nil
  for i = 1, n do
    local sc = scores[i] or 0
    if bestScore == nil or sc > bestScore then best, bestScore = i, sc end
  end
  return best
end

M.bestSeat = bestSeat

-- The win flash: a 1-second panel over the finished rally, before the results screen. It names the
-- winner by their CARD ID when there is one -- a player should see their own name at the moment
-- they win, not a seat number. An anonymous seat has no id, so it falls back to the seat label
-- rather than rendering "anon WON!".
M.FLASH_MAX = 24   -- keeps the panel inside the canvas whatever a player called themselves

function M.winnerText(seatLabels, status, scores)
  local i = bestSeat(#seatLabels, scores)
  local s = (status.seats or {})[i] or {}
  local who = s.player or seatLabels[i] or ("SEAT " .. i)
  return (who .. " WON!"):sub(1, M.FLASH_MAX)
end

-- A free match moved no money, so there is nothing to animate -- it just names the winner.
function M.freeResultText(seatLabels, scores)
  return seatLabels[bestSeat(#seatLabels, scores)] .. " PLAYER WON"
end

-- One row per seat: where its counter starts and where it lands. An anonymous seat still gets a row
-- (it played) but has nothing to animate at either end.
function M.resultRows(seatLabels, before, status, scores)
  local rows = {}
  for i = 1, #status.seats do
    local s = status.seats[i]
    rows[i] = {
      seat  = i,
      label = seatLabels[i] or ("SEAT " .. i),
      id    = s.player,
      from  = before[i],
      to    = s.balance,
      score = scores[i] or 0,
    }
  end
  return rows
end

return M
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `luajit test/test_match_logic.lua`
Expected: PASS.

- [ ] **Step 5: Syntax check**

Run: `luajit -bl src/lib/match_logic.lua > /dev/null`
Expected: no output, exit 0.

- [ ] **Step 6: Commit**

```bash
git add src/lib/match_logic.lua test/test_match_logic.lua
git commit -m "feat(match_logic): pure state-machine helpers for the match framework"
```

---

### Task 5: `lib/lobby.lua` — the lobby screen

**Files:**
- Create: `src/lib/lobby.lua`
- Test: `test/test_lobby.lua`

**Interfaces:**
- Consumes: nothing (the caller passes a plain view table).
- Produces:
  - `lobby.hitTest(x, y, nSeats) -> "ready", i | "go", nil | nil`
  - `lobby.draw(win, view)` where `view = { title, ante, seats = { { label, id, balance, status, ready } }, goEnabled, message }`
  - Layout constants `lobby.READY` (array of `{x,w,y,h}`), `lobby.GO` (`{x,w,y,h}`, shared with the results screen), `lobby.INFO`, `lobby.ID_MAX`, `lobby.BAND_Y`, `lobby.BAND_H`, `lobby.NET_X`, `lobby.GUARD_X0/X1/Y0/Y1`.
  - Drawing helpers reused by `match.lua`'s results screen: `lobby.inRect`, `lobby.fillRect`, `lobby.centerIn`, `lobby.infoWrite`, `lobby.drawNet`.

**Geometry — binding, and NOT arbitrary.** The canvas is **57×24 cells**. These rectangles come from
the approved visual design (`tools/pong-preview.html`, artifact
`875f7353-8ae5-4544-85ae-cc71da4728af`), generated from the same constants that page draws with.

Rendering is debug-grade native text this session, but **the touch geometry is final**. Hit-testing
is built once and verified in-world once; the art pass changes only how things are *drawn*, never
where they are *touched*. Do not "simplify" these numbers.

Everything mirrors exactly about the net: `col c ↔ col 58-c`. Nothing is asymmetric.

| Element | x | w | y | h | cells |
|---|---|---|---|---|---|
| READY seat 1 (LEFT) | 13 | 15 | 12 | 6 | cols 13–27, rows 12–17 |
| READY seat 2 (RIGHT) | 31 | 15 | 12 | 6 | cols 31–45, rows 12–17 |
| GO (lobby **and** results) | 21 | 17 | 18 | 5 | cols 21–37, rows 18–22 |
| Seat band (lobby) | — | — | 8 | 10 | rows 8–17 |
| LEFT info column | 2 | 11 | — | — | cols 2–12 |
| RIGHT info column | 46 | 11 | — | — | cols 46–56, **right-aligned** |

**GO is the same rectangle on both screens, deliberately** — the rematch button must be the same
button in the same place so muscle memory carries from lobby to results. One shared constant.

**`ID_MAX = 11`** — exact, not an estimate: it is the literal usable width of the info column
(cols 2–12). One cell of margin stays outboard so text never touches the canvas edge; the inboard
edge stops at col 12 because READY starts at col 13. `OFFLINE` (7) and `BAD CARD` (8) fit.

**The net's protected span.** The net is drawn at cell column **29 only** (subpixels 56–57). Native
`write` sets a whole cell's background, so a native string crossing col 29 physically **erases a
cell of net per row**. Cols 28 and 30 are the black clearance gutters — text there erases nothing
but crowds the spine and breaks the mirror. The enforced band is therefore the wider
**cols 28–30, rows 5–17** (the union across both screens: lobby's net runs rows 8–17, results'
rows 5–16). The play screen's net spans the full height but draws **zero** native text, so it needs
no exclusion.

- [ ] **Step 1: Write the failing test**

Create `test/test_lobby.lua`:

```lua
-- test_lobby.lua — the lobby screen: hit testing and drawing onto a stub window.
--
-- The assertion that matters most is the GO gate: that button moves real money, so "inert" and
-- "live" must be different pixels, not just different behaviour.
package.path = "src/lib/?.lua;test/?.lua;" .. package.path
local t = require("runner")
local lobby = require("lobby")

-- A window stub that records what was written and in what colours.
local function stubWin()
  local w = { _writes = {}, _bg = 0, _fg = 0, _visible = true }
  function w.getSize() return 57, 24 end
  function w.setVisible(v) w._visible = v end
  function w.setBackgroundColor(c) w._bg = c end
  function w.setTextColor(c) w._fg = c end
  function w.clear() w._writes = {} end
  function w.setCursorPos(x, y) w._x, w._y = x, y end
  function w.write(s)
    w._writes[#w._writes + 1] = { x = w._x, y = w._y, text = s, bg = w._bg, fg = w._fg }
    w._x = (w._x or 1) + #s
  end
  function w.find(pattern)
    for _, e in ipairs(w._writes) do
      if tostring(e.text):find(pattern, 1, true) then return e end
    end
    return nil
  end
  return w
end

-- ---- the geometry is the DESIGN's, not a convenience ----
-- These numbers come from tools/pong-preview.html. Rendering stays debug-grade this session but the
-- touch rects are final, so hit-testing is built once and verified in-world once.
do
  t.eq(lobby.READY[1].x, 13, "seat 1 READY starts at col 13")
  t.eq(lobby.READY[1].w, 15, "and is 15 cells wide")
  t.eq(lobby.READY[1].y, 12, "on row 12")
  t.eq(lobby.READY[1].h, 6,  "and 6 rows tall -- a 1-row button cannot bevel and is a poor target")
  t.eq(lobby.READY[2].x, 31, "seat 2 READY starts at col 31")
  t.eq(lobby.GO.x, 21, "GO starts at col 21")
  t.eq(lobby.GO.w, 17, "and is 17 cells wide")
  t.eq(lobby.GO.y, 18, "on row 18")
  t.eq(lobby.GO.h, 5,  "and 5 rows tall")
  t.eq(lobby.ID_MAX, 11, "an id truncates to the info column's exact width")
end

-- Everything mirrors about the net: col c <-> col 58-c. If this ever fails, one seat has drifted.
do
  t.eq(lobby.READY[1].x + lobby.READY[1].w - 1, 58 - lobby.READY[2].x,
       "the READY buttons are exact mirrors about the net")
  t.eq(lobby.GO.x + lobby.GO.w - 1, 58 - lobby.GO.x, "GO mirrors onto itself")
  -- cols 2-12 mirrors to cols 46-56: the OUTER edge of one maps to the OUTER edge of the other.
  t.eq(58 - lobby.INFO[1].x, lobby.INFO[2].x + lobby.INFO[2].w - 1,
       "LEFT's outer edge (col 2) mirrors to RIGHT's outer edge (col 56)")
  t.eq(58 - (lobby.INFO[1].x + lobby.INFO[1].w - 1), lobby.INFO[2].x,
       "LEFT's inner edge (col 12) mirrors to RIGHT's inner edge (col 46)")
  t.eq(lobby.INFO[1].w, lobby.INFO[2].w, "both info columns are the same width")
end

-- ---- hit testing ----
do
  local kind, i = lobby.hitTest(13, 12, 2)
  t.eq(kind, "ready", "the top-left cell of seat 1's button is a ready toggle")
  t.eq(i, 1, "for seat 1")

  kind, i = lobby.hitTest(27, 17, 2)
  t.eq(kind, "ready", "the bottom-right cell of seat 1's button still hits")
  t.eq(i, 1, "still seat 1")

  kind, i = lobby.hitTest(45, 17, 2)
  t.eq(kind, "ready", "seat 2's far corner hits")
  t.eq(i, 2, "for seat 2")

  t.eq(lobby.hitTest(28, 14, 2), nil, "the gutter between seat 1's button and the net is a miss")
  t.eq(lobby.hitTest(12, 14, 2), nil, "one cell left of seat 1's button is a miss")
  t.eq(lobby.hitTest(13, 11, 2), nil, "the row above the button is a miss")
  t.eq(lobby.hitTest(13, 18, 2), "go", "row 18 under seat 1's button is GO, not READY")
  t.eq(lobby.hitTest(13, 12, 1), nil, "seat 2's rect is dead at a 1-seat station")
  t.eq(lobby.hitTest(31, 12, 1), nil, "and so is its area")
end

do
  t.eq(lobby.hitTest(21, 18, 2), "go", "GO's top-left hits")
  t.eq(lobby.hitTest(37, 22, 2), "go", "GO's bottom-right hits")
  t.eq(lobby.hitTest(20, 20, 2), nil, "just left of GO is a miss")
  t.eq(lobby.hitTest(38, 20, 2), nil, "just right of GO is a miss")
  t.eq(lobby.hitTest(29, 23, 2), nil, "below GO is a miss")
  t.eq(lobby.hitTest(1, 1, 2), nil, "the title area is not a button")

  -- GO is checked with nSeats = 0 by the results screen, which has no READY buttons.
  t.eq(lobby.hitTest(29, 20, 0), "go", "GO still hits when there are no seat buttons")
  t.eq(lobby.hitTest(13, 14, 0), nil, "and READY does not")
end

-- ---- drawing ----
local function view(over)
  local v = {
    title = "PONG", ante = 10, goEnabled = false, message = nil,
    seats = {
      { label = "LEFT",  id = "alice", balance = 120, ready = false },
      { label = "RIGHT", id = nil,     balance = nil, ready = false },
    },
  }
  for k, x in pairs(over or {}) do v[k] = x end
  return v
end

do
  local w = stubWin()
  lobby.draw(w, view())
  t.ok(w.find("PONG"), "the title is drawn")
  t.ok(w.find("ANTE $10"), "the ante is drawn, with a $")
  t.ok(w.find("LEFT"), "seat 1's label is drawn")
  t.ok(w.find("RIGHT"), "seat 2's label is drawn")
  t.ok(w.find("alice"), "a carded seat shows its id")
  t.ok(w.find("120"), "and its balance")
  t.ok(w.find("anon"), "a cardless seat reads as anon, never as an empty gap")
  t.ok(w.find("READY"), "the ready buttons are drawn")
  t.ok(w.find("GO"), "the GO button is drawn")
end

do
  -- A hub-unreachable seat must say so rather than showing a stale or absent number.
  local v = view()
  v.seats[1].status = "OFFLINE"
  v.seats[1].balance = nil
  local w = stubWin()
  lobby.draw(w, v)
  t.ok(w.find("OFFLINE"), "a status word replaces the balance when there is no number to trust")
end

do
  local w = stubWin()
  lobby.draw(w, view{ message = "HUB OFFLINE - nobody charged" })
  t.ok(w.find("HUB OFFLINE"), "the deny message is drawn when present")
end

-- THE GO GATE. This button moves money: inert and live must be visibly different.
do
  local inert, live = stubWin(), stubWin()
  lobby.draw(inert, view{ goEnabled = false })
  lobby.draw(live,  view{ goEnabled = true })

  local a = inert.find("GO")
  local b = live.find("GO")
  t.ok(a and b, "GO is drawn in both states")
  t.ok(a.bg ~= b.bg or a.fg ~= b.fg,
       "an inert GO and a live GO must not render identically -- this button spends real money")
end

do
  -- A ready seat must be distinguishable from a not-ready one.
  local off, on = stubWin(), stubWin()
  local v = view(); v.seats[1].ready = true
  lobby.draw(off, view())
  lobby.draw(on, v)
  local a, b = off.find("READY"), on.find("READY")
  t.ok(a.bg ~= b.bg or a.fg ~= b.fg, "a READY seat renders differently from a not-ready one")
end

-- ---- flicker discipline: draw must buffer ----
do
  local w = stubWin()
  local seq = {}
  w.setVisible = function(v) seq[#seq + 1] = v end
  lobby.draw(w, view())
  t.eq(seq[1], false, "draw hides the window before painting (no flicker)")
  t.eq(seq[#seq], true, "and shows it once at the end")
end

t.done()
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `luajit test/test_lobby.lua`
Expected: FAIL — `module 'lobby' not found`.

- [ ] **Step 3: Write the implementation**

Create `src/lib/lobby.lua`:

```lua
-- lobby.lua — the lobby screen for a multiplayer match: seats, per-seat READY, and a gated GO.
--
-- Drawn by match.lua; it owns no state. Hand it a plain view table and it paints; hand it a touch
-- and hitTest tells you what was hit. That split is what lets the whole screen be tested with a
-- stub window and no monitor.
--
-- DEBUG-GRADE NATIVE TEXT, ON PURPOSE. The art pass for all three screens is a separate effort
-- against the spec's UI contract (kb/monitor-ui-workflow.md). Do not decorate this yet.
--
-- Canvas: 3x2 blocks @ setTextScale(0.5) = 57x24 cells (kb/monitor-resolution.md).
local M = {}

-- ---- layout (cells, 1-indexed) ---------------------------------------------
-- FROM THE APPROVED DESIGN (tools/pong-preview.html), generated from the same constants that page
-- draws with. Rendering below is debug-grade native text, but these RECTS ARE FINAL: hit-testing is
-- built once and verified in-world once, and the art pass changes only how things are drawn.
-- Everything mirrors about the net: col c <-> col 58-c.
M.W, M.H = 57, 24

M.NET_X = 29                          -- the net is this column and NO other
M.GUARD_X0, M.GUARD_X1 = 28, 30       -- enforced no-native-text band (net + its two gutters)
M.GUARD_Y0, M.GUARD_Y1 = 5, 17        -- union across the lobby (8-17) and results (5-16) nets

M.TITLE_Y = 2
M.MSG_Y   = 23
M.BAND_Y, M.BAND_H = 8, 10            -- the lobby's seat band: rows 8-17

M.READY = {
  { x = 13, w = 15, y = 12, h = 6 },  -- LEFT  : cols 13-27, rows 12-17
  { x = 31, w = 15, y = 12, h = 6 },  -- RIGHT : cols 31-45, rows 12-17
}

-- ONE rect, shared by the lobby and the results screen ON PURPOSE: the rematch button must be the
-- same button in the same place, so muscle memory carries between the two screens.
M.GO = { x = 21, w = 17, y = 18, h = 5 }   -- cols 21-37, rows 18-22

-- The outer info columns. RIGHT is right-aligned, so its text ENDS at col 56.
M.INFO = {
  { x = 2,  w = 11, align = "left"  },   -- cols 2-12
  { x = 46, w = 11, align = "right" },   -- cols 46-56
}
M.ID_MAX = 11   -- exact: the info column's usable width. READY starts at col 13, so 12 is the last.

local function inRect(r, x, y)
  return x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h
end
M.inRect = inRect

-- monitor_touch has NO release event, so nothing here is a press-and-hold; a tap is the whole
-- interaction and every "pressed" look in this project is a timed flash.
-- Returns "ready", seatIndex | "go", nil | nil.
-- The results screen calls this with nSeats = 0 to test GO alone.
function M.hitTest(x, y, nSeats)
  for i = 1, math.min(nSeats or 0, #M.READY) do
    if inRect(M.READY[i], x, y) then return "ready", i end
  end
  if inRect(M.GO, x, y) then return "go", nil end
  return nil
end

-- ---- drawing ---------------------------------------------------------------
local function writeAt(win, x, y, text, fg, bg)
  win.setCursorPos(x, y)
  win.setTextColor(fg)
  win.setBackgroundColor(bg)
  win.write(text)
end

-- Write into an info column, honouring its alignment and the id cap. Native `write` sets the whole
-- cell's background, so a string that crossed col 29 would ERASE a cell of net per row -- these
-- columns are the outer ones precisely so that can never happen.
local function infoWrite(win, i, y, text, fg)
  local col = M.INFO[i]
  if not col or not text or text == "" then return end
  text = text:sub(1, col.w)
  local x = (col.align == "right") and (M.W - #text) or col.x
  writeAt(win, x, y, text, fg, colors.black)
end
M.infoWrite = infoWrite

-- Fill a rect with a background colour: the fill IS the button, not a coloured word.
local function fillRect(win, r, bg)
  win.setBackgroundColor(bg)
  local line = string.rep(" ", r.w)
  for dy = 0, r.h - 1 do
    win.setCursorPos(r.x, r.y + dy)
    win.write(line)
  end
end
M.fillRect = fillRect

-- A label centred inside a rect, drawn over its fill.
local function centerIn(win, r, text, fg, bg)
  text = text:sub(1, r.w)
  writeAt(win, r.x + math.floor((r.w - #text) / 2), r.y + math.floor((r.h - 1) / 2), text, fg, bg)
end
M.centerIn = centerIn

-- The dashed centre spine. Cell column 29 only -- it is the machine's identity and the mirror line.
local function drawNet(win, y0, y1)
  win.setBackgroundColor(colors.white)
  for y = y0, y1, 2 do
    win.setCursorPos(M.NET_X, y)
    win.write(" ")
  end
  win.setBackgroundColor(colors.black)
end
M.drawNet = drawNet

-- view = {
--   title, ante, goEnabled, message,
--   seats = { { label, id, balance, status, ready }, ... },
-- }
function M.draw(win, view)
  win.setVisible(false)                       -- buffer the whole frame: no flicker
  win.setBackgroundColor(colors.black)
  win.setTextColor(colors.white)
  win.clear()

  writeAt(win, 2, M.TITLE_Y, view.title, colors.white, colors.black)
  local ante = ("ANTE $%d"):format(view.ante or 0)
  writeAt(win, M.W - #ante, M.TITLE_Y, ante, colors.yellow, colors.black)

  drawNet(win, M.BAND_Y, M.BAND_Y + M.BAND_H - 1)

  for i, s in ipairs(view.seats) do
    local r = M.READY[i]
    if r then
      infoWrite(win, i, M.BAND_Y,     s.label, colors.lightGray)
      infoWrite(win, i, M.BAND_Y + 1, (s.id or "anon"):sub(1, M.ID_MAX),
                s.id and colors.white or colors.gray)

      -- A status word REPLACES the balance. There is no number worth showing when the hub did not
      -- answer, and a stale one reads as truth.
      local money = s.status or (s.balance and ("$" .. s.balance)) or ""
      infoWrite(win, i, M.BAND_Y + 2, money, s.status and colors.pink or colors.white)

      -- READY latched = lime; not ready = steel. Colour AND (in the art pass) depth.
      fillRect(win, r, s.ready and colors.lime or colors.gray)
      centerIn(win, r, "READY", s.ready and colors.black or colors.lightGray,
               s.ready and colors.lime or colors.gray)
    end
  end

  if view.message then
    writeAt(win, 2, M.MSG_Y, view.message:sub(1, M.W - 2), colors.pink, colors.black)
  end

  -- THE GATE. This button spends real money, so inert and live differ in fill, text colour AND the
  -- word itself -- a player must never tap a GO that looks live and be told no.
  fillRect(win, M.GO, view.goEnabled and colors.yellow or colors.gray)
  centerIn(win, M.GO, view.goEnabled and "GO" or "WAITING",
           view.goEnabled and colors.black or colors.lightGray,
           view.goEnabled and colors.yellow or colors.gray)

  win.setVisible(true)
end

return M
```

- [ ] **Step 4: Make `colors` available to the test**

The stub window test runs under `luajit`, where the CC `colors` global does not exist. Add this shim to `test/test_lobby.lua`, immediately after the `require("runner")` line and **before** `require("lobby")`:

```lua
-- CC's `colors` global does not exist under luajit. lobby.lua is a DRAWING module, so unlike the
-- pure modules it legitimately references it; the shim gives each colour a distinct number so the
-- tests can assert that two states render differently.
colors = {
  black = 1, white = 2, gray = 3, lightGray = 4,
  green = 5, yellow = 6, pink = 7, red = 8,
  lime = 9, lightBlue = 10, orange = 11,
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `luajit test/test_lobby.lua`
Expected: PASS.

- [ ] **Step 6: Syntax check**

Run: `luajit -bl src/lib/lobby.lua > /dev/null`
Expected: no output, exit 0.

- [ ] **Step 7: Commit**

```bash
git add src/lib/lobby.lua test/test_lobby.lua
git commit -m "feat(lobby): lobby screen with per-seat ready and a gated GO"
```

---

### Task 6: `lib/match.lua` — the runner, the pump, the results screen

**Files:**
- Create: `src/lib/match.lua`
- Test: `test/test_match.lua`

**Interfaces:**
- Consumes: `match_logic`, `lobby`, `counter`, `mp_econ`.
- Produces: `match.run(cfg) -> function(mon, pres) -> "sleep" | "quit"` — the value a station hands to `idle_runner` as its `play`.

`cfg` fields: `title`, `seatLabels`, `minSeats`, `maxSeats`, `ante`, `drives`, `controls`, `target`, `play`, and `deps` (test injection: `{ mp_econ = , window = , os = }`).

`play(ctx)` receives `ctx = { win, controls, seats, target, tick }` and returns `{ [seatIndex] = score }`.

**The pump rule this task exists to enforce:** `match` owns `os.pullEvent`; `play` never calls it. Event-pump re-entrancy is this repository's most expensive recurring bug class (the floppy-swap freeze cost a full session), so a game author must not be able to get it wrong. `ctx.tick()` yields one frame and returns `false` when the match must abort.

- [ ] **Step 1: Write the failing test**

Create `test/test_match.lua`:

```lua
-- test_match.lua — the match runner: phase loop, pump ownership, and the money-replay capture.
--
-- Everything here runs against injected fakes: a fake mp_econ, a fake window, and a fake os whose
-- pullEvent replays a scripted event list. No monitor, no hub, no CC.
package.path = "src/lib/?.lua;test/?.lua;" .. package.path
local t = require("runner")

colors = { black = 1, white = 2, gray = 3, lightGray = 4,
           green = 5, yellow = 6, pink = 7, red = 8 }

local match = require("match")

-- ---- fakes -----------------------------------------------------------------
local function fakeWin()
  local w = { _writes = {} }
  function w.getSize() return 57, 24 end
  function w.setVisible() end
  function w.setBackgroundColor() end
  function w.setTextColor() end
  function w.clear() w._writes = {} end
  function w.setCursorPos(x, y) w._x, w._y = x, y end
  function w.write(s) w._writes[#w._writes + 1] = { x = w._x, y = w._y, text = s } end
  function w.find(p)
    for _, e in ipairs(w._writes) do
      if tostring(e.text):find(p, 1, true) then return e end
    end
  end
  return w
end

-- Scripted event source. Entries are handed out in order; once the script runs dry it emits filler
-- timer ticks so a phase that legitimately waits (the win flash, the results dwell) does not have
-- to have every tick spelled out. A hard cap still catches a loop that never returns.
--
-- startTimer always returns the SAME id so a scripted { "timer", 1 } is always the live timer --
-- the real code re-arms constantly and only id equality matters.
local TIMER_ID = 1
local function fakeOs(events)
  local i, filler = 0, 0
  return {
    pullEvent = function()
      i = i + 1
      if events[i] then return unpack(events[i]) end
      filler = filler + 1
      if filler > 2000 then error("EVENTS EXHAUSTED -- the match loop never returned", 0) end
      return "timer", TIMER_ID
    end,
    startTimer = function() return TIMER_ID end,
    epoch = function() return 0 end,
  }
end

-- a fake mp_econ instance recording what the runner asked of it
local function fakeEcon(script)
  script = script or {}
  local e = {
    phase = "lobby", pot = 0,
    seats = { {}, {} },
    _calls = {},
    _status = script.status or { phase = "lobby", pot = 0, seats = {
      { player = "alice", balance = 100 },
      { player = "bob",   balance = 100 },
    } },
  }
  function e.onEvent(ev) e._calls[#e._calls + 1] = { op = "onEvent", ev = ev } end
  function e.status() return e._status end
  function e.cardedCount() return 2 end
  function e.start()
    e._calls[#e._calls + 1] = { op = "start" }
    local r = script.start or { "staked" }
    if r[1] == "staked" then e.phase, e.pot = "playing", 20 else e.phase = "playing" end
    if r[1] == "deny" then e.phase = "lobby" end
    return r[1], r[2], r[3]
  end
  function e.finish(scores)
    e._calls[#e._calls + 1] = { op = "finish", scores = scores }
    e.phase, e.pot = "done", 0
    return script.finish or { potWinner = 1, potShare = { [1] = 20 }, pot = 20, matchWinner = 1 }
  end
  function e.reset()
    e._calls[#e._calls + 1] = { op = "reset" }
    e.phase, e.pot = "lobby", 0
  end
  function e.opsOf(name)
    local n = 0
    for _, c in ipairs(e._calls) do if c.op == name then n = n + 1 end end
    return n
  end
  return e
end

local function fakePres(goneAfter)
  local n = 0
  return {
    gone = function() n = n + 1; return goneAfter ~= nil and n >= goneAfter end,
    fromEvent = function() end,
  }
end

-- flashTicks defaults to 0 here so the win flash does not silently EAT the scripted touches that
-- follow a GO (the flash pumps, and a pump consumes events until a timer arrives). The flash gets
-- its own dedicated test below, with flashTicks = 1 and an explicit timer.
local function runner(cfg, events, econ, presGone)
  local win = fakeWin()
  local play = match.run{
    title = "PONG", seatLabels = { "LEFT", "RIGHT" },
    minSeats = 2, maxSeats = 2, ante = 10, target = 5,
    controls = {}, drives = { "drive_0", "drive_1" },
    flashTicks = cfg.flashTicks or 0, resultTicks = cfg.resultTicks or 9999,
    play = cfg.play,
    deps = {
      mp_econ = { new = function() return econ end },
      window  = { create = function() return win end },
      os      = fakeOs(events),
    },
  }
  local result = play({ setTextScale = function() end, getSize = function() return 57, 24 end },
                      fakePres(presGone))
  return result, win, econ
end

-- ---- Q quits, and the runner returns the idle_runner contract ----
do
  local econ = fakeEcon()
  local res = runner({ play = function() return {} end }, { { "key", 16 } }, econ)
  t.eq(res, "quit", "a Q key returns 'quit' to idle_runner")
end

-- ---- the zone emptying puts the station to sleep ----
do
  local econ = fakeEcon()
  local res = runner({ play = function() return {} end },
                     { { "timer", 1 } }, econ, 1)
  t.eq(res, "sleep", "an empty zone returns 'sleep'")
end

-- ---- GO is INERT until every seat is ready: a touch must not start a match ----
do
  local econ = fakeEcon()
  local lobby = require("lobby")
  local events = {
    { "monitor_touch", "monitor_0", 21, 18 },   -- GO while nobody is ready
    { "key", 16 },
  }
  runner({ play = function() return {} end }, events, econ)
  t.eq(econ.opsOf("start"), 0,
       "GO with no seats ready NEVER antes -- the gate is enforced in the runner, not just drawn")
end

-- ---- both ready -> GO -> the game runs -> results ----
do
  local econ = fakeEcon()
  local lobby = require("lobby")
  local played = false
  local events = {
    { "monitor_touch", "m", 13, 12 },   -- seat 1 READY
    { "monitor_touch", "m", 31, 12 },   -- seat 2 READY
    { "monitor_touch", "m", 21, 18 },   -- GO
    { "key", 16 },
  }
  local _, win = runner({
    play = function(ctx)
      played = true
      t.ok(ctx.win ~= nil, "play gets a window")
      t.eq(ctx.target, 5, "play gets the target score")
      t.eq(#ctx.seats, 2, "play gets the seats")
      return { [1] = 5, [2] = 3 }
    end,
  }, events, econ)

  t.eq(played, true, "GO with all seats ready runs the game")
  t.eq(econ.opsOf("start"), 1, "and antes exactly once")
  t.eq(econ.opsOf("finish"), 1, "and resolves exactly once")
end

-- ---- THE CAPTURE: balances are read BEFORE start(), not after ----
do
  local econ = fakeEcon()
  local lobby = require("lobby")
  -- status() changes after start(): if the runner captured late it would read the POST-ante number
  -- and the results screen would animate from the wrong place (a drain that never appears).
  local origStart = econ.start
  econ.start = function()
    local r = { origStart() }
    econ._status = { phase = "playing", pot = 20, seats = {
      { player = "alice", balance = 90 }, { player = "bob", balance = 90 } } }
    return unpack(r)
  end
  local events = {
    { "monitor_touch", "m", 13, 12 },   -- seat 1 READY
    { "monitor_touch", "m", 31, 12 },   -- seat 2 READY
    { "monitor_touch", "m", 21, 18 },   -- GO
    { "key", 16 },
  }
  local _, win = runner({ play = function() return { [1] = 5, [2] = 3 } end }, events, econ)
  t.ok(win.find("100"),
       "the results screen animates from the PRE-ante balance -- capture happens before start()")
end

-- ---- a deny is reported and nothing is played ----
do
  local econ = fakeEcon{ start = { "deny", "timeout", 1 } }
  local lobby = require("lobby")
  local played = false
  local events = {
    { "monitor_touch", "m", 13, 12 },   -- seat 1 READY
    { "monitor_touch", "m", 31, 12 },   -- seat 2 READY
    { "monitor_touch", "m", 21, 18 },   -- GO
    { "timer", 1 },
    { "key", 16 },
  }
  local _, win = runner({ play = function() played = true; return {} end }, events, econ)
  t.eq(played, false, "a denied GO does not run the game")
  t.ok(win.find("HUB OFFLINE"), "and the lobby says HUB OFFLINE, not INSUFFICIENT")
end

-- ---- disk events reach mp_econ ----
do
  local econ = fakeEcon()
  runner({ play = function() return {} end },
         { { "disk", "drive_0" }, { "key", 16 } }, econ)
  t.ok(econ.opsOf("onEvent") >= 1, "disk events are folded into mp_econ so seats refresh")
end

-- ---- READY IS CLEARED on the way back to the lobby ----
do
  local econ = fakeEcon()
  local lobby = require("lobby")
  local plays = 0
  local events = {
    { "monitor_touch", "m", 13, 12 },   -- seat 1 READY
    { "monitor_touch", "m", 31, 12 },   -- seat 2 READY
    { "monitor_touch", "m", 21, 18 },   -- GO: match 1
    { "monitor_touch", "m", 21, 18 },   -- GO on results: skip to the lobby
    { "monitor_touch", "m", 21, 18 },   -- GO again: READY was cleared, so this must be INERT
    { "key", 16 },
  }
  runner({ play = function() plays = plays + 1; return { [1] = 5, [2] = 3 } end }, events, econ)
  t.eq(plays, 1,
       "after a match, READY is cleared -- a stale ready flag would ante a player who walked away")
  t.eq(econ.opsOf("reset"), 1, "and the engine is reset so a second match is possible at all")
end

-- ---- THE WIN FLASH: named by card id, drawn over the finished board ----
do
  local econ = fakeEcon()
  local lobby = require("lobby")
  local events = {
    { "monitor_touch", "m", 13, 12 },          -- seat 1 READY
    { "monitor_touch", "m", 31, 12 },          -- seat 2 READY
    { "monitor_touch", "m", 21, 18 },          -- GO
    { "timer", 1 },                            -- the one flash tick
    { "key", 16 },
  }
  local _, win = runner({ flashTicks = 1, play = function() return { [1] = 5, [2] = 3 } end },
                        events, econ)
  t.ok(win.find("alice WON!"),
       "the flash names the WINNER BY CARD ID -- a player sees their own name at the moment of the win")
end

do
  -- An anonymous winner has no id, so the flash falls back to the seat label.
  local econ = fakeEcon()
  econ._status = { phase = "lobby", pot = 0, seats = {
    { player = nil, balance = nil }, { player = "bob", balance = 100 } } }
  local events = {
    { "monitor_touch", "m", 13, 12 },
    { "monitor_touch", "m", 31, 12 },
    { "monitor_touch", "m", 21, 18 },
    { "timer", 1 },
    { "key", 16 },
  }
  local _, win = runner({ flashTicks = 1, play = function() return { [1] = 5, [2] = 1 } end },
                        events, econ)
  t.ok(win.find("LEFT WON!"), "an anonymous winner falls back to the seat label, never 'anon WON!'")
end

-- ---- the verdict headline appears on a STAKED result, not only a free one ----
do
  local econ = fakeEcon()
  local events = {
    { "monitor_touch", "m", 13, 12 },
    { "monitor_touch", "m", 31, 12 },
    { "monitor_touch", "m", 21, 18 },
    { "key", 16 },
  }
  local _, win = runner({ play = function() return { [1] = 5, [2] = 3 } end }, events, econ)
  t.ok(win.find("LEFT PLAYER WON"),
       "a staked results screen still states who won -- settled counters alone carry no verdict")
end

t.done()
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `luajit test/test_match.lua`
Expected: FAIL — `module 'match' not found`.

- [ ] **Step 3: Write the implementation**

Create `src/lib/match.lua`:

```lua
-- match.lua — the reusable multi-screen match framework: LOBBY -> PLAY -> RESULTS.
--
--   require("idle_runner").run{
--     name = "pong", monitor = mon,
--     play = require("match").run{ title = "PONG", seatLabels = {"LEFT","RIGHT"}, ... },
--   }
--
-- A game supplies ONE function -- play(ctx) -> scores -- and gets the lobby, the ante, the pot, the
-- results screen and the money animation for free. Pong is its first consumer; any future 2-4
-- player game is the same shape.
--
-- MATCH OWNS THE EVENT PUMP; play() NEVER CALLS os.pullEvent. This is the single most important
-- boundary in the design. Event-pump re-entrancy is this project's most expensive recurring bug
-- class ([[event-pump-reentrancy]]: the floppy-swap freeze cost an entire session), and a game
-- author must not be able to get it wrong. play() gets ctx.tick(), which yields exactly one frame
-- and returns false when the match must abort.
--
-- Screens are DEBUG-GRADE NATIVE TEXT this session, on purpose; the art pass is separate.
local ml      = require("match_logic")
local lobbyUI = require("lobby")
local counter = require("counter")

local TICK         = 0.05
local RESULT_TICKS = 160   -- ~8s before results auto-returns to the lobby
local FLASH_TICKS  = 20    -- ~1s win flash over the finished board, before the money screen

local M = {}

local TINT = { up = colors.yellow, down = colors.pink, rest = colors.white }

-- The results screen's seat band sits HIGHER and runs LONGER than the lobby's: it drops the READY
-- row and gains the counter (approved design, tools/pong-preview.html).
local RES_BAND_Y, RES_BAND_H = 5, 12

-- cfg.deps = { mp_econ =, window =, os = } -- test injection only; production omits it.
function M.run(cfg)
  local deps   = cfg.deps or {}
  local mpEcon = deps.mp_econ or require("mp_econ")
  local windowApi = deps.window or window
  local osApi  = deps.os or os

  local seatLabels = cfg.seatLabels or {}
  local nSeats     = #seatLabels

  -- the value idle_runner calls: play(mon, pres) -> "sleep" | "quit"
  return function(mon, pres)
    local W, H = mon.getSize()
    local win = windowApi.create(mon, 1, 1, W, H, true)   -- offscreen buffer -> no flicker

    local econ = mpEcon.new{
      drives = cfg.drives, ante = cfg.ante,
      minSeats = cfg.minSeats, maxSeats = cfg.maxSeats,
    }

    local flashTicks  = cfg.flashTicks  or FLASH_TICKS
    local resultTicks = cfg.resultTicks or RESULT_TICKS

    local phase   = "lobby"          -- "lobby" | "results"
    local ready   = ml.newReady(nSeats)
    local message = nil
    local exit    = nil              -- "sleep" | "quit" once decided
    local rows, counters, headline, freeLabel, resultsTicks = nil, nil, nil, nil, 0
    local timer = osApi.startTimer(TICK)

    -- ---- rendering -------------------------------------------------------
    local function lobbyView()
      local st = econ.status()
      local seats = {}
      for i = 1, nSeats do
        local s = st.seats[i] or {}
        seats[i] = {
          label   = seatLabels[i],
          id      = s.player,
          balance = s.balance,
          status  = s.offline and "OFFLINE" or nil,
          ready   = ready[i],
        }
      end
      return {
        title = cfg.title, ante = cfg.ante, seats = seats,
        goEnabled = ml.allReady(ready), message = message,
      }
    end

    -- The win flash: a panel drawn OVER the finished rally, deliberately without clearing. The
    -- board the players were just watching stays visible underneath, so the moment reads as "that
    -- last point won it" rather than as a screen change. It is the beat between the rally and the
    -- money -- every game on this framework gets it for free.
    local function drawFlash(text)
      local w = #text + 4
      local x = math.floor((W - w) / 2) + 1
      local y = math.floor(H / 2) - 1
      win.setVisible(false)
      win.setBackgroundColor(colors.white)
      for dy = 0, 2 do
        win.setCursorPos(x, y + dy)
        win.write(string.rep(" ", w))
      end
      win.setTextColor(colors.black)
      win.setCursorPos(x + 2, y + 1)
      win.write(text)
      win.setBackgroundColor(colors.black)
      win.setVisible(true)
    end

    local function drawResults()
      win.setVisible(false)
      win.setBackgroundColor(colors.black)
      win.setTextColor(colors.white)
      win.clear()

      win.setCursorPos(2, 2); win.write(cfg.title .. " - RESULT")

      -- The verdict, on BOTH staked and free screens. Row 4 is deliberately ABOVE the net's
      -- protected span (rows 5-17): this string is centred and would otherwise cross col 29 and
      -- erase a cell of net, because native `write` sets the whole cell's background.
      if headline then
        win.setTextColor(colors.white)
        win.setCursorPos(math.max(1, math.floor((W - #headline) / 2) + 1), 4)
        win.write(headline)
      end

      lobbyUI.drawNet(win, RES_BAND_Y, RES_BAND_Y + RES_BAND_H - 1)

      for i = 1, #seatLabels do
        local row = rows and rows[i]
        lobbyUI.infoWrite(win, i, RES_BAND_Y, seatLabels[i], colors.lightGray)
        lobbyUI.infoWrite(win, i, RES_BAND_Y + 1,
                          (row and row.id or "anon"):sub(1, lobbyUI.ID_MAX),
                          (row and row.id) and colors.white or colors.gray)
        local c = counters and counters[i]
        if c then
          lobbyUI.infoWrite(win, i, RES_BAND_Y + 3, "$" .. tostring(c.value()), TINT[c.tint()])
        elseif freeLabel then
          -- A free match moved no money; label the panel so it does not read as broken or empty.
          lobbyUI.infoWrite(win, i, RES_BAND_Y + 3, freeLabel, colors.lightGray)
        end
      end

      -- The SAME rect as the lobby's GO, on purpose: the rematch button must be the same button in
      -- the same place so muscle memory carries between screens.
      lobbyUI.fillRect(win, lobbyUI.GO, colors.yellow)
      lobbyUI.centerIn(win, lobbyUI.GO, "GO", colors.black, colors.yellow)
      win.setBackgroundColor(colors.black)
      win.setVisible(true)
    end

    local function render()
      if phase == "lobby" then lobbyUI.draw(win, lobbyView())
      else drawResults() end
    end

    -- ---- returning to the lobby -------------------------------------------
    -- READY IS PER-MATCH CONSENT. Clearing it here, on the ONLY path back to the lobby, is what
    -- stops the next GO from anteing a player who already walked away.
    local function toLobby()
      econ.reset()
      phase, ready, message = "lobby", ml.newReady(nSeats), nil
      rows, counters, headline, freeLabel = nil, nil, nil, nil
    end

    -- ---- resolving --------------------------------------------------------
    -- A live pot must NEVER leave this loop unresolved. On the way out, whoever is ahead takes it --
    -- which is exactly what "the ante is forfeit" means when the player who walked off was losing.
    -- Without this, exiting mid-match debits every seat and credits nobody: the $ evaporates.
    local function resolve(scores)
      if econ.phase == "playing" then econ.finish(scores or {}) end
    end

    -- ---- the pump ---------------------------------------------------------
    -- The ONLY os.pullEvent in the framework. Returns when the frame timer fires, or immediately
    -- once `exit` is set. Handles a touch via the supplied dispatcher so the lobby and the results
    -- screen can share one pump.
    local function pump(onTouch)
      while not exit do
        local ev = { osApi.pullEvent() }
        local e = ev[1]

        if e == "timer" and ev[2] == timer then
          if pres.gone() then exit = "sleep"; return end
          timer = osApi.startTimer(TICK)
          return

        elseif e == "monitor_touch" then
          if onTouch then onTouch(ev[3], ev[4]) end
          -- Re-arm unconditionally: a touch handler that reaches the hub runs a NESTED event pump
          -- and can swallow this loop's pending tick timer. Only the timer branch re-arms, so
          -- without this the loop can block forever with no timer outstanding
          -- ([[event-pump-reentrancy]]). The cage does exactly the same.
          timer = osApi.startTimer(TICK)
          render()

        elseif e == "disk" or e == "disk_eject" then
          econ.onEvent(ev)
          timer = osApi.startTimer(TICK)   -- refreshCard reaches the hub: same reason as above
          render()

        elseif e == "rednet_message" then
          pres.fromEvent(ev)

        elseif e == "key" and ev[2] == keys.q then
          exit = "quit"; return
        end
      end
    end

    -- ---- starting a match --------------------------------------------------
    local function startMatch()
      message = nil

      -- CAPTURE BEFORE start(). By the time results draws, the money has already moved (the ante
      -- debits here, the pot credits at finish), so the animation is a REPLAY. Reading balances
      -- after start() would animate from the post-ante number and the drain would never appear.
      local before = ml.captureBalances(econ.status())

      local res, reason, seat = econ.start()
      if res == "deny" then
        message = ml.denyMessage(reason, seat)
        render()
        return
      end

      local potBefore = econ.pot

      -- Run the game. ctx.tick() is the ONLY way play() yields.
      local ctx = {
        win = win, controls = cfg.controls, seats = seatLabels, target = cfg.target,
        tick = function()
          pump(nil)
          return exit == nil
        end,
      }
      local scores = cfg.play(ctx) or {}

      resolve(scores)
      local st = econ.status()

      -- THE WIN FLASH -- ~1s over the finished board before the money screen. Named by CARD ID when
      -- the winner has one: a player should see their own name at the moment they win.
      --
      -- PUMPED, never slept. A bare sleep(1) here would swallow presence and the quit key for a
      -- full second, and this project has paid for blocking calls inside a play loop more than once
      -- ([[event-pump-reentrancy]]).
      if not exit then
        local flash = ml.winnerText(seatLabels, st, scores)
        local held = 0
        while not exit and held < flashTicks do
          drawFlash(flash)
          pump(nil)
          held = held + 1
        end
      end

      -- The verdict headline shows on BOTH staked and free results. Once the counters settle to
      -- white a staked screen would otherwise carry no statement of who actually won.
      headline = ml.freeResultText(seatLabels, scores)

      if ml.staked(potBefore) then
        rows, freeLabel = ml.resultRows(seatLabels, before, st, scores), nil
        counters = {}
        for i, row in ipairs(rows) do
          if row.from and row.to then
            counters[i] = counter.new{ value = row.from }
            counters[i].setTarget(row.to)
          end
        end
      else
        rows, counters, freeLabel = nil, nil, "FREE MATCH"
      end

      phase, resultsTicks = "results", 0
      render()
    end

    -- ---- the phase loop ----------------------------------------------------
    render()
    while not exit do
      if phase == "lobby" then
        pump(function(x, y)
          local kind, i = lobbyUI.hitTest(x, y, nSeats)
          if kind == "ready" then
            ml.toggle(ready, i)
            message = nil
          elseif kind == "go" then
            -- The gate is enforced HERE, not merely drawn. A GO that looks inert must also BE
            -- inert -- this button spends real money.
            if ml.allReady(ready) then startMatch() end
          end
        end)

      else   -- results
        pump(function(x, y)
          -- nSeats = 0: the results screen has no READY buttons, so only GO can be hit.
          if lobbyUI.hitTest(x, y, 0) == "go" then
            toLobby()   -- skip straight to a rematch
          end
        end)
        if not exit and phase == "results" then
          if counters then
            for _, c in pairs(counters) do c.step() end
          end
          resultsTicks = resultsTicks + 1
          if resultsTicks >= resultTicks then toLobby() end
          render()
        end
      end
    end

    resolve(nil)   -- never leave a live pot behind on the way out
    return exit
  end
end

return M
```

- [ ] **Step 4: Add the `keys` shim to the test**

`match.lua` references the CC `keys` global. Add to `test/test_match.lua`, immediately after the `colors` shim and **before** `require("match")`:

```lua
keys = { q = 16 }
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `luajit test/test_match.lua`
Expected: PASS.

- [ ] **Step 6: Syntax check**

Run: `luajit -bl src/lib/match.lua > /dev/null`
Expected: no output, exit 0.

- [ ] **Step 7: Commit**

```bash
git add src/lib/match.lua test/test_match.lua
git commit -m "feat(match): lobby/play/results state machine owning the event pump"
```

---

### Task 7: `pong/pong_logic.lua` — pure physics and first-to-5

**Files:**
- Create: `src/pong/pong_logic.lua`
- Test: `test/test_pong_logic.lua`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `pong_logic.newState(W, H, paddleH) -> state` where `state = { W, H, paddleH, lp, rp, bx, by, bvx, bvy, ls, rs }`
  - `pong_logic.resetBall(state, dir, vy)`
  - `pong_logic.clamp(v, lo, hi) -> number`
  - `pong_logic.step(state, lpv, rpv) -> state` (one physics frame; `lpv`/`rpv` are −1/0/1)
  - `pong_logic.isOver(state, target) -> boolean`
  - `pong_logic.PADDLE_STEP`, `pong_logic.BALL_SPEED`

The ball's vertical kick on a paddle hit (`bvy = bvy + (by - (paddle + paddleH/2)) * 0.15`) is preserved from the original — it is the one piece of feel worth keeping.

- [ ] **Step 1: Write the failing test**

Create `test/test_pong_logic.lua`:

```lua
-- test_pong_logic.lua — pong's rally physics and its win condition, with no monitor.
--
-- The physics is the ONE part of the 2026 prototype worth keeping; these tests pin its behaviour so
-- the rewrite around it cannot quietly change how the game feels.
package.path = "src/pong/?.lua;src/lib/?.lua;test/?.lua;" .. package.path
local t = require("runner")
local pl = require("pong_logic")

local function newGame()
  local s = pl.newState(57, 24, 6)
  pl.resetBall(s, 1, 0)
  return s
end

-- ---- clamp ----
do
  t.eq(pl.clamp(5, 1, 10), 5, "in range passes through")
  t.eq(pl.clamp(0, 1, 10), 1, "below clamps to lo")
  t.eq(pl.clamp(99, 1, 10), 10, "above clamps to hi")
end

-- ---- setup ----
do
  local s = newGame()
  t.eq(s.ls, 0, "left starts at 0")
  t.eq(s.rs, 0, "right starts at 0")
  t.ok(s.bx > 1 and s.bx < 57, "the ball starts on the field")
  t.ok(s.lp >= 1, "the left paddle starts on the field")
end

-- ---- paddles move, and cannot leave the field ----
do
  local s = newGame()
  local y0 = s.lp
  pl.step(s, -1, 0)
  t.ok(s.lp < y0, "-1 moves the left paddle up")
  pl.step(s, 1, 0); pl.step(s, 1, 0)
  t.ok(s.lp > y0 - 1, "+1 moves it back down")
end

do
  local s = newGame()
  for _ = 1, 200 do pl.step(s, -1, 0) end
  t.eq(s.lp, 1, "a paddle held up stops at the top edge, never off-field")
end

do
  local s = newGame()
  for _ = 1, 200 do pl.step(s, 0, 1) end
  t.eq(s.rp, 24 - 6 + 1, "a paddle held down stops with its whole body on the field")
end

-- ---- walls bounce ----
do
  local s = newGame()
  s.by, s.bvy = 1, -1
  pl.step(s, 0, 0)
  t.ok(s.bvy > 0, "the ball bounces off the top wall")
  s.by, s.bvy = 24, 1
  pl.step(s, 0, 0)
  t.ok(s.bvy < 0, "and off the bottom wall")
end

-- ---- scoring ----
do
  local s = newGame()
  s.bx, s.bvx = 1.2, -1        -- past the left paddle, heading out
  s.lp = 20                    -- paddle nowhere near it
  pl.step(s, 0, 0)
  t.eq(s.rs, 1, "a ball leaving the left edge scores for RIGHT")
  t.ok(s.bx > 1 and s.bx < 57, "and the ball is re-served onto the field")
end

do
  local s = newGame()
  s.bx, s.bvx = 56.5, 1
  s.rp = 1
  s.by = 20                    -- paddle nowhere near it
  pl.step(s, 0, 0)
  t.eq(s.ls, 1, "a ball leaving the right edge scores for LEFT")
end

-- ---- a paddle hit returns the ball and does NOT score ----
do
  local s = newGame()
  s.lp, s.paddleH = 10, 6
  s.by = 12                    -- squarely on the left paddle
  s.bx, s.bvx, s.bvy = 2.4, -0.6, 0
  pl.step(s, 0, 0)
  t.ok(s.bvx > 0, "the ball comes off the left paddle heading right")
  t.eq(s.rs, 0, "and nobody scored")
end

-- the off-centre kick is the game's feel; a hit above the paddle's middle must send the ball up
do
  local s = newGame()
  s.lp = 10
  s.by = 10                    -- top of a 6-tall paddle, above its centre (13)
  s.bx, s.bvx, s.bvy = 2.4, -0.6, 0
  pl.step(s, 0, 0)
  t.ok(s.bvy < 0, "a hit above the paddle's centre kicks the ball upward")
end

do
  local s = newGame()
  s.lp = 10
  s.by = 15                    -- below the centre
  s.bx, s.bvx, s.bvy = 2.4, -0.6, 0
  pl.step(s, 0, 0)
  t.ok(s.bvy > 0, "a hit below the centre kicks it downward")
end

-- ---- FIRST TO 5 ----
do
  local s = newGame()
  t.eq(pl.isOver(s, 5), false, "0-0 is not over")
  s.ls = 4
  t.eq(pl.isOver(s, 5), false, "4 is not 5")
  s.ls = 5
  t.eq(pl.isOver(s, 5), true, "left reaching 5 ends the match")
end

do
  local s = newGame()
  s.rs = 5
  t.eq(pl.isOver(s, 5), true, "right reaching 5 ends it too")
end

do
  -- The match must terminate. A rally with a paddle parked away from the ball always concedes,
  -- so a bounded loop must reach 5 -- if this ever spins, the win condition is unreachable.
  local s = newGame()
  local n = 0
  while not pl.isOver(s, 5) and n < 20000 do pl.step(s, 0, 0); n = n + 1 end
  t.eq(pl.isOver(s, 5), true, "an unattended rally reaches 5 and the match terminates")
end

t.done()
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `luajit test/test_pong_logic.lua`
Expected: FAIL — `module 'pong_logic' not found`.

- [ ] **Step 3: Write the implementation**

Create `src/pong/pong_logic.lua`:

```lua
-- pong_logic.lua — pong's rally physics and win condition. Pure: no monitor, no redstone, no events.
--
-- This is the ONE part of the original 2026 prototype worth keeping. It is hoisted out of pong.lua
-- so it can be tested offline (the slot_logic / slot.lua split), and so the rewrite around it
-- cannot quietly change how the game feels.
local M = {}

M.PADDLE_STEP = 1      -- cells a paddle moves per frame while its plate is held
M.BALL_SPEED  = 0.6    -- cells the ball moves per frame

function M.clamp(v, lo, hi)
  if v < lo then return lo elseif v > hi then return hi else return v end
end

function M.newState(W, H, paddleH)
  local top = math.floor((H - paddleH) / 2) + 1
  return {
    W = W, H = H, paddleH = paddleH,
    leftX = 2, rightX = W - 1,
    lp = top, rp = top,
    bx = W / 2, by = H / 2, bvx = M.BALL_SPEED, bvy = 0,
    ls = 0, rs = 0,
  }
end

-- dir = 1 serves right, -1 serves left. vy is the vertical component; the caller supplies it so
-- this module stays deterministic (pong.lua randomises it).
function M.resetBall(s, dir, vy)
  s.bx, s.by = s.W / 2, s.H / 2
  s.bvx = M.BALL_SPEED * dir
  s.bvy = vy or 0
end

-- One physics frame. lpv/rpv are -1 (up), 0 (still) or 1 (down).
function M.step(s, lpv, rpv)
  s.lp = M.clamp(s.lp + (lpv or 0) * M.PADDLE_STEP, 1, s.H - s.paddleH + 1)
  s.rp = M.clamp(s.rp + (rpv or 0) * M.PADDLE_STEP, 1, s.H - s.paddleH + 1)

  s.bx = s.bx + s.bvx
  s.by = s.by + s.bvy
  if s.by < 1    then s.by, s.bvy = 1, -s.bvy end
  if s.by > s.H  then s.by, s.bvy = s.H, -s.bvy end

  -- Paddle hits. The off-centre kick is the game's whole feel: the further from the paddle's
  -- middle the ball lands, the harder it is deflected.
  if s.bx <= s.leftX + 1 and s.bx >= s.leftX and s.by >= s.lp and s.by < s.lp + s.paddleH then
    s.bx, s.bvx = s.leftX + 1, math.abs(s.bvx)
    s.bvy = s.bvy + (s.by - (s.lp + s.paddleH / 2)) * 0.15
  end
  if s.bx >= s.rightX - 1 and s.bx <= s.rightX and s.by >= s.rp and s.by < s.rp + s.paddleH then
    s.bx, s.bvx = s.rightX - 1, -math.abs(s.bvx)
    s.bvy = s.bvy + (s.by - (s.rp + s.paddleH / 2)) * 0.15
  end

  if s.bx < 1   then s.rs = s.rs + 1; M.resetBall(s,  1, s.bvy) end
  if s.bx > s.W then s.ls = s.ls + 1; M.resetBall(s, -1, s.bvy) end

  return s
end

-- FIRST TO `target`. The original prototype had no win condition at all -- a debug END button
-- resolved the match, which is why it could never have a results screen.
function M.isOver(s, target)
  return s.ls >= target or s.rs >= target
end

return M
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `luajit test/test_pong_logic.lua`
Expected: PASS.

- [ ] **Step 5: Syntax check**

Run: `luajit -bl src/pong/pong_logic.lua > /dev/null`
Expected: no output, exit 0.

- [ ] **Step 6: Commit**

```bash
git add src/pong/pong_logic.lua test/test_pong_logic.lua
git commit -m "feat(pong_logic): pure rally physics + first-to-5 win condition"
```

---

### Task 8: Rewrite `pong/pong.lua` and update `packages.lua`

**Files:**
- Rewrite: `src/pong/pong.lua` (replace the file entirely)
- Modify: `src/packages.lua` — the `pong` package file list

**Interfaces:**
- Consumes: `controls`, `pong_logic`, `match`, `idle_runner`.
- Produces: the `pong` station program. No module exports.

**What is deleted, and why each deletion is deliberate:**
- The `SIDES` table of computer sides → `pong.cfg` via `controls`.
- `WAKE_SIDE` / `WAKE_LEVEL` and the whole local redstone wake → **removed**. It existed only because the station had no ender modem; it has one now, so presence wakes it. With the plates on a relay no computer side ever changes, so the old wake would read a line that can never move and would fail **silently**. Its removal is why `idle_runner` needs no change in this branch.
- The `GO` / `END` buttons, `drawEcon`, `drawButtons`, `btnHit` and the inline `mp_econ` harness → `match` owns all of it.
- `physics()`, `resetBall()`, `clamp()` → `pong_logic`.

**Kept:** `pong test` (the side-identification tool), now reporting through `controls`.

- [ ] **Step 1: Rewrite the station file**

Replace the entire contents of `src/pong/pong.lua` with:

```lua
-- pong.lua — 2-player Pong on a CC:Tweaked monitor, controlled by IN-WORLD PRESSURE PLATES.
--
--   Run:  pong        -> play (normally auto-run by the startup supervisor)
--   Run:  pong test   -> live input monitor, to find which plate feeds which relay side
--
-- Diegetic controls: each player stands on an "up" or "down" pressure plate. The plates feed a
-- REDSTONE RELAY (not the computer's own sides), so the wiring lives in pong.cfg and is read
-- through lib/controls.
--
-- This file is deliberately small. The lobby, the ante, the pot, the results screen and the money
-- animation all live in lib/match (the reusable framework); the rally physics lives in pong_logic.
-- What is left here is the station's wiring and how a rally is drawn.
--
-- Waking: pong wakes on hub PRESENCE (GPS proximity) like every other station. It needs an ENDER
-- MODEM ON A COMPUTER SIDE to self-locate -- gps.locate scans rs.getSides() only, never the cable.
local controls = require("controls")
local pl       = require("pong_logic")
local match    = require("match")

-- ---- config ----------------------------------------------------------------
local TEXT_SCALE = 0.5    -- 3x2 blocks @ 0.5 = 57x24 cells
local TARGET     = 5      -- first to 5 takes the match
local INPUTS     = { "p1_up", "p1_down", "p2_up", "p2_down" }

-- ---- per-station wiring ----------------------------------------------------
-- pong.cfg is NOT in the package file list, so it survives `update pong` (which OVERWRITES
-- pong.lua). It is the ONLY place per-station wiring belongs. cfg always wins over discovery:
-- CC does not hand identically-built stations identical peripheral names.
--
--   source  = relay          # or a peripheral name, or "computer"
--   p1_up   = left           # P1 up    (left paddle)
--   p1_down = front          # P1 down
--   p2_up   = right          # P2 up    (right paddle)
--   p2_down = back           # P2 down
--   drives  = drive_0,drive_1   # seat order: left paddle first
--   ante    = 10
local function readCfg()
  local out = {}
  if not fs.exists("pong.cfg") then return out end
  local f = fs.open("pong.cfg", "r")
  if not f then return out end
  local txt = f.readAll(); f.close()
  for k, v in txt:gmatch("([%w_]+)%s*=%s*([^\r\n#]+)") do
    out[k] = (v:gsub("%s+$", ""))
  end
  return out
end

local function splitList(s)
  if not s then return nil end
  local out = {}
  for item in s:gmatch("[^,%s]+") do out[#out + 1] = item end
  return #out > 0 and out or nil
end

local CFG  = readCfg()
local ANTE = tonumber(CFG.ante) or 10

local mon = peripheral.find("monitor")
if not mon then
  error("No monitor found. Attach a monitor (directly or via a wired modem) and rerun.", 0)
end
mon.setTextScale(TEXT_SCALE)

-- Fail loud at boot: a miswired station stops here naming what it could not find, rather than
-- running with a paddle that silently reads "not pressed" forever.
local ctl = controls.new{ cfg = CFG, inputs = INPUTS }

-- ===== TEST MODE: identify which physical plate feeds which input ============
local function testMode()
  local W, H = mon.getSize()
  local win = window.create(mon, 1, 1, W, H, true)
  print("Input source: " .. ctl.sourceName())
  local timer = os.startTimer(0.1)
  while true do
    local ev = { os.pullEvent() }
    if ev[1] == "timer" and ev[2] == timer then
      win.setVisible(false)
      win.setBackgroundColor(colors.black)
      win.setTextColor(colors.white)
      win.clear()
      win.setCursorPos(1, 1)
      win.write("INPUT TEST via " .. ctl.sourceName() .. " (Q quits)")
      for i, name in ipairs(INPUTS) do
        win.setCursorPos(1, i + 2)
        win.write(("%-9s %-7s %s"):format(name, ctl.sideOf(name),
                                          ctl.get(name) and "[ON] " or "[   ]"))
      end
      win.setVisible(true)
      timer = os.startTimer(0.1)
    elseif ev[1] == "key" and ev[2] == keys.q then
      return
    end
  end
end

if ({ ... })[1] == "test" then
  testMode()
  mon.setBackgroundColor(colors.black); mon.clear(); mon.setCursorPos(1, 1); mon.setTextScale(1)
  print("Test mode done.")
  return
end

-- ===== THE RALLY ============================================================
math.randomseed(os.epoch("utc"))

local function fill(win, x, y, w, h, color)
  win.setBackgroundColor(color)
  local line = string.rep(" ", w)
  for i = 0, h - 1 do
    win.setCursorPos(x, y + i)
    win.write(line)
  end
end

local function drawRally(win, s)
  win.setVisible(false)
  win.setBackgroundColor(colors.black)
  win.clear()
  for y = 1, s.H, 2 do fill(win, math.floor(s.W / 2), y, 1, 1, colors.white) end   -- the net
  fill(win, s.leftX,  s.lp, 1, s.paddleH, colors.white)
  fill(win, s.rightX, s.rp, 1, s.paddleH, colors.white)
  fill(win, pl.clamp(math.floor(s.bx), 1, s.W), pl.clamp(math.floor(s.by), 1, s.H), 1, 1, colors.white)

  win.setBackgroundColor(colors.black); win.setTextColor(colors.white)
  local txt = s.ls .. "  " .. s.rs
  win.setCursorPos(math.max(1, math.floor(s.W / 2 - #txt / 2)), 1)
  win.write(txt)
  win.setVisible(true)
end

-- The game, as match sees it: draw a frame, yield, repeat, hand back the scores.
-- NOTE: no os.pullEvent here, ever. match owns the pump; ctx.tick() is the only yield.
local function play(ctx)
  local W, H = ctx.win.getSize()
  local s = pl.newState(W, H, math.max(3, math.floor(H / 4)))
  pl.resetBall(s, math.random() < 0.5 and -1 or 1,
               pl.BALL_SPEED * (math.random() < 0.5 and -1 or 1))

  while not pl.isOver(s, ctx.target) do
    local lpv, rpv = 0, 0
    if ctl.get("p1_up")   then lpv = lpv - 1 end
    if ctl.get("p1_down") then lpv = lpv + 1 end
    if ctl.get("p2_up")   then rpv = rpv - 1 end
    if ctl.get("p2_down") then rpv = rpv + 1 end

    pl.step(s, lpv, rpv)
    drawRally(ctx.win, s)

    if not ctx.tick() then break end   -- the zone emptied or the player quit: abort, keep the score
  end

  return { [1] = s.ls, [2] = s.rs }
end

require("idle_runner").run{
  name = "pong", monitor = mon, zone = nil,
  play = match.run{
    title      = "PONG",
    seatLabels = { "LEFT", "RIGHT" },
    minSeats   = 2,
    maxSeats   = 2,
    ante       = ANTE,
    target     = TARGET,
    drives     = splitList(CFG.drives),
    controls   = ctl,
    play       = play,
  },
}
```

- [ ] **Step 2: Syntax check the station file**

Run: `luajit -bl src/pong/pong.lua > /dev/null`
Expected: no output, exit 0.

- [ ] **Step 3: Update the package manifest**

In `src/packages.lua`, replace the whole `pong = { ... }` block with:

```lua
  pong = {
    station = true,
    files = {
      { name = "idle_logic",   path = "lib/idle_logic.lua" },
      { name = "proximity",    path = "lib/proximity.lua" },
      { name = "idle_runner",  path = "lib/idle_runner.lua" },
      { name = "card",         path = "lib/card.lua" },
      { name = "card_session", path = "lib/card_session.lua" },
      { name = "wallet",       path = "lib/wallet.lua" },
      { name = "mp_econ",      path = "lib/mp_econ.lua" },
      { name = "counter",      path = "lib/counter.lua" },
      { name = "controls",     path = "lib/controls.lua" },
      { name = "match_logic",  path = "lib/match_logic.lua" },
      { name = "lobby",        path = "lib/lobby.lua" },
      { name = "match",        path = "lib/match.lua" },
      { name = "pong_logic",   path = "pong/pong_logic.lua" },
      { name = "pong_advert",  path = "pong/pong_advert.lua" },
      { name = "pong",         path = "pong/pong.lua" },
    },
  },
```

- [ ] **Step 4: Verify the manifest against the tree**

Every `path` must exist, and every module `pong.lua` requires must be listed. Run:

```bash
luajit -e 'package.path="src/?.lua;"..package.path; local p=dofile("src/packages.lua"); for _,f in ipairs(p.pong.files) do local io_=io.open("src/"..f.path); print((io_ and "OK  " or "MISS").." "..f.path); if io_ then io_:close() end end'
```

Expected: every line reads `OK`. A `MISS` means a path typo — fix it before committing.

- [ ] **Step 5: Confirm every `require` is packaged**

Run:

```bash
grep -oh 'require("[a-z_]*")' src/pong/pong.lua src/lib/match.lua src/lib/lobby.lua src/lib/match_logic.lua src/lib/counter.lua src/lib/controls.lua src/pong/pong_logic.lua | sort -u
```

Expected: every name printed appears as a `name =` entry in the `pong` package list from Step 3. A missing one installs a station that crashes on boot with `module not found` — the failure mode the manifest check exists to catch.

- [ ] **Step 6: Run the whole test suite**

Run:

```bash
for f in test/test_*.lua; do echo "== $f"; luajit "$f" || exit 1; done
```

Expected: every file reports `0 failed`. This is the regression gate — `mp_econ` gained a method and the slot and cage share its dependencies.

- [ ] **Step 7: Commit**

```bash
git add src/pong/pong.lua src/packages.lua
git commit -m "feat(pong): rewrite onto the match framework; relay controls, first to 5"
```

---

### Task 9: Documentation — `README.md` and `todo.md`

**Files:**
- Modify: `README.md` (the Components & roadmap table)
- Modify: `todo.md` (add a section; amend the MP-economy section's pot-journal item)

**Interfaces:** none.

- [ ] **Step 1: Update the roadmap table**

In `README.md`, replace the `**Multiplayer economy**` row with these two rows:

```markdown
| **Multiplayer economy**| engine ✓ (in-world pending) | `lib/card_session` (one card on one drive) + `lib/mp_econ` (N seats, ante→pot→payout). A seat is a drive; anon seats play but never win the pot. |
| **Match framework**    | v1 ✓ (in-world pending) | `lib/match` — the reusable `lobby → play → results` machine for any 2–4 player game. Owns the event pump so a game supplies only `play(ctx)`; per-seat touch READY gates a GO that antes. `lib/lobby`, `lib/counter`, `lib/controls` (relay input). Pong is its first consumer. |
```

- [ ] **Step 2: Add the todo section**

In `todo.md`, insert this section immediately **before** the `## Backlog` heading:

```markdown
## Pong rebuild + the match framework — CODE COMPLETE 2026-07-18 · **in-world PENDING** ⚠️

Spec: `docs/superpowers/specs/2026-07-18-pong-match-lobby-design.md`;
plan: `docs/superpowers/plans/2026-07-18-pong-match-lobby.md`.

Pong was the project's first prototype and predated every piece of infrastructure. Its rally physics
was the only part worth keeping. The deliverable is **not a better pong** — it is `lib/match`, the
reusable `lobby → play → results` machine every future 2–4 player game sits on. Pong is its proof.

- **`lib/match` owns the event pump; a game's `play(ctx)` never calls `os.pullEvent`.** The single
  most important boundary here: event-pump re-entrancy is this repo's most expensive recurring bug
  class (`[[event-pump-reentrancy]]`), so a game author must not be able to get it wrong.
- **READY is per-match consent, never a sticky flag.** Every path back to the lobby clears it. A
  surviving flag would ante the card of a player who had already walked away.
- **The results screen REPLAYS money that already moved** — the ante debits at GO, the pot credits
  at finish. Balances are captured *before* `mp_econ.start()`; animating from the post-ante number
  would hide the drain entirely.
- **`mp_econ.reset()`** — `"done"` was terminal, so a station played exactly one match per boot.
  That was the observed in-world reset bug.
- **`lib/controls`** — plates moved onto a `redstone_relay`, whose methods are name-identical to the
  built-in `redstone` API (verified: tweaked.cc, CC:Tweaked 1.114.0+). Wiring lives in `pong.cfg`;
  the relay is discovered BY TYPE; every failure is loud at boot.
- **The local redstone wake was REMOVED.** It only existed because the station had no ender modem.
  With the plates on a relay no computer side ever changes, so it would have failed *silently* —
  and removing it means `idle_runner` was not touched at all.
- **Screens are debug-grade native text on purpose.** The art pass for all three screens (plus
  `pong_advert`, still an 18-line stub) is a separate effort against the spec's UI contract:
  57×24 cells, 3×2 blocks @0.5.

**In-world verification (PENDING):** `update pong`, reboot · wakes on presence, no plate needed ·
all four paddles respond (`pong test`) · 0 cards → both READY → GO → free rally to 5 → `LEFT/RIGHT
PLAYER WON`, no counters, nobody debited · 1 card → free, no debit · 2 cards → GO → both debited,
`POT $20` → first to 5 → counters drain the loser and climb the winner → winner credited · GO on
results returns to lobby with **READY cleared** · results auto-returns after ~8s · eject a card
mid-match → the pot still pays the anted id · a different card mid-match → spectator · seat 2
insufficient → seat 1 not out of pocket · hub down → `HUB OFFLINE`, nobody debited · walk away
mid-match → the pot resolves · **regression: slot + cage still work.**

**Open question, to check in-world rather than assume:** does a `redstone_relay` input change raise
the computer's `redstone` event? tweaked.cc is silent. Nothing here depends on it (presence is the
wake, paddles are polled), but a future design that leans on it would fail silently.
```

- [ ] **Step 2b: Amend the pot-journal item**

In `todo.md`'s "MP economy engine" section, replace the sentence `**Must be closed before an MP game takes real players.**` with:

```markdown
  **Owner's call 2026-07-18: accepted risk, not closed** — the window realistically requires a full
  server crash mid-match. Reconsider if it is ever observed in the wild.
```

- [ ] **Step 3: Commit**

```bash
git add README.md todo.md
git commit -m "docs: record the match framework and pong's rebuild"
```

---

## Post-plan: in-world verification

The deploy loop means **nothing is verified until it runs in-world**, and that happens *after* the
merge and push (`CLAUDE.md`). Mind the CDN lag: `raw.githubusercontent.com` edge-caches ~5 minutes
and does not reliably honour the cache-buster, so `update pong` immediately after a push can fetch a
stale `packages.lua` — a new module then reads as `module not found`. Wait 2–5 minutes and re-run.

The checklist is the one written into `todo.md` in Task 9. The two items most likely to fail first:

1. **`pong test` shows nothing lighting up.** The relay is not being seen, or `pong.cfg` maps the
   wrong sides. `controls` fails loud at boot for a missing relay, so a *silent* wrong reading means
   the sides are misconfigured — step on each plate and read `pong test`'s live table.
2. **`update pong` installs but pong crashes on boot with `module not found`.** A file was added to
   `src/` but not to `packages.lua`, or the CDN is still serving the old manifest. Task 8 steps 4–5
   exist to catch the first; wait out the second.

## Self-Review

**Spec coverage:**

| Spec requirement | Task |
|---|---|
| `lib/match.lua` state machine + pump | 6 |
| `lib/lobby.lua` seats / READY / gated GO | 5 |
| `lib/counter.lua` extracted from cage | 1 |
| `lib/controls.lua` relay abstraction | 2 |
| `mp_econ.reset()` | 3 |
| `pong.lua` rewritten, first to 5 | 7, 8 |
| Local redstone wake removed | 8 |
| `balanceAtGO` captured before `start()` | 4 (pure), 6 (enforced + tested) |
| Free match shows no counters | 4, 6 |
| READY cleared on every lobby entry | 4, 6 |
| GO inert until all ready | 5 (drawn), 6 (enforced) |
| Deny copy: HUB OFFLINE ≠ INSUFFICIENT | 4 |
| `packages.lua` updated + verified | 8 |
| Docs / in-world checklist | 9 |
| Cage NOT refactored to use `counter` | (no task — deliberate) |
| Art pass, 4-player, pot journal | (deferred — no task) |

No gaps.

**Placeholder scan:** none — every step carries the literal file content or the exact command.

**Type consistency:** `counter.new/setTarget/step/value/target/atRest/tint`, `controls.new/get/sideOf/sourceName`, `match_logic.newReady/toggle/allReady/captureBalances/denyMessage/staked/winnerText/freeResultText/resultRows/bestSeat/MSG_MAX/FLASH_MAX`, `lobby.hitTest/draw/inRect/fillRect/centerIn/infoWrite/drawNet/READY/GO/INFO/ID_MAX/BAND_Y/BAND_H/NET_X/GUARD_*`, `match.run`, `pong_logic.newState/resetBall/clamp/step/isOver/PADDLE_STEP/BALL_SPEED`, `mp_econ.reset` — each name is used in later tasks exactly as defined. `tint()` returns `"up"/"down"/"rest"` at every call site (Task 1 defines, Task 6 maps through `TINT`). `lobby.GO` is one table shared by the lobby and the results screen, deliberately.
