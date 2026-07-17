# Per-Station Proximity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a player at the cage wake the cage and nothing else, at a cost that does not grow as the floor grows.

**Architecture:** The hub becomes a server-wide position oracle. Once per poll it asks *who is online* (1 call) and *where each player is* (P calls) — **O(players), not O(stations)** — then matches zones in **pure Lua** and sends presence **addressed to each station's computer ID** on edges only. Stations keep a true zero-cost `os.pullEvent` deep sleep and learn their own position from `gps.locate()` with a `pos=` cfg fallback. The legacy `zone="all"` broadcast is left byte-for-byte intact, so any station that has not registered a position behaves exactly as it does today.

**Tech Stack:** CC:Tweaked (CraftOS, Lua 5.1), Advanced Peripherals 0.7 `player_detector`, rednet (`ccvegas` protocol), luajit for unit tests.

Spec: `docs/superpowers/specs/2026-07-17-per-station-proximity-design.md` — read its **Confirmed facts** section before starting. Every fact there was read from mod source or measured; do not re-derive them, and do not "fix" code that looks odd but matches a numbered fact.

## Global Constraints

- **Lua 5.1 / CraftOS only.** No `goto`, no integer division `//`, no bitwise operators. `table.unpack or unpack` for portability. Pure modules must run under `luajit` with **no CC APIs at all**.
- **Every `player_detector` method is `mainThread = true`** (spec fact 1) — each call parks the coroutine ~50ms. **Count the calls.** Per poll this design permits exactly `2 + P` (P = online players). Adding a per-station peripheral call is a plan violation, not an optimisation choice.
- **`getPlayerPos` must be `pcall`ed.** It throws when `enablePlayerPosFunction=false` (spec fact 3). An unguarded call takes the hub — and therefore the whole floor — down.
- **`getPlayerPos` does NOT filter by dimension** (spec fact 4). The hub must filter on `dimension` itself.
- **Deploy flattens `src/` by name**, so `require("proximity")` never encodes the folder.
- **A new `lib/` file that is not added to `src/packages.lua` will not deploy.** This project has already paid for that bug twice. Task 6 exists solely for it.
- Protocol constant is `PROTO = "ccvegas"`. Hub hostname is `hub`.
- Header comment on every program: what it does, how to run it, wiring notes.
- Existing message kinds are unchanged. One new kind: `station_pos` → `station_pos_ok`.

## File Structure

| File | Responsibility |
|---|---|
| `src/lib/proximity.lua` | **New.** Pure zone math: `parsePos`, `near`, `evaluate`, `edges`. No CC APIs. The only new logic in the feature. |
| `test/test_proximity.lua` | **New.** Unit tests for the above, luajit. |
| `src/hub/hub.lua` | **Modify.** `hub test pos` spike; `station_pos` handler + persistence; `presenceLoop` rewritten around the oracle. |
| `src/lib/idle_runner.lua` | **Modify.** Resolve own position (gps → cfg → none), register it, default `cfg.zone` to the computer ID. |
| `src/cage/cage.lua` | **Modify.** `pos=`/`dim=`/`range=` cfg keys; `zone` default `"all"` → `nil`. |
| `src/slot/slot.lua`, `src/pong/pong.lua` | **Modify.** Drop the hardcoded `"all"` so idle_runner can auto-resolve. |
| `src/packages.lua` | **Modify.** Ship `proximity` with every package that requires it. |

---

### Task 1: `hub test pos` — the blocking spike tool

**Ship this first and push it.** The owner runs it in-world while the rest is built; **Task 4 is gated on its result.** It is hub-only, depends on nothing, and cannot regress anything (it returns before the registrar starts).

**Files:**
- Modify: `src/hub/hub.lua` (insert before the existing `if args[1] == "test" then` block, currently line 51)

**Interfaces:**
- Consumes: nothing.
- Produces: nothing consumed by later tasks. Its **output decides whether Task 4 proceeds.**

- [ ] **Step 1: Read the existing test block**

Read `src/hub/hub.lua` lines 51-73. The existing `hub test` block starts with `if args[1] == "test" then`. The new block must go **before** it, because `args[1] == "test"` would otherwise swallow `test pos` and print the live range meter instead.

- [ ] **Step 2: Insert the `hub test pos` block**

Insert immediately before the line `if args[1] == "test" then`:

```lua
-- `hub test pos` — THE SPIKE. Per-station proximity reads player POSITIONS, and three Advanced
-- Peripherals config values can each silently break that. All three default in our favour, but
-- pre-1.21 AP defaulted playerDetMaxRange to 100 (it is -1 now), so nothing here is assumed.
-- Run this ONCE standing at the hub and ONCE from a station ~1000 blocks out — a capped range looks
-- exactly like "nobody is there", which is the failure this tool exists to make loud.
-- See docs/superpowers/specs/2026-07-17-per-station-proximity-design.md facts (2) and (3).
if args[1] == "test" and args[2] == "pos" then
  local det = peripheral.find("player_detector")
  if not det then
    print("No 'player_detector' found. Check the block is on the wired network.")
    return
  end
  local names = det.getOnlinePlayers()
  print(("getOnlinePlayers() -> %d: %s"):format(#names, table.concat(names, ", ")))
  if #names == 0 then print("Nobody online?? Stand in the world and re-run."); return end
  for _, n in ipairs(names) do
    local ok, p = pcall(det.getPlayerPos, n)
    if not ok then
      print(("  %s: THREW: %s"):format(n, tostring(p)))
      print("  => enablePlayerPosFunction = FALSE. Per-station proximity CANNOT work.")
      print("  => Ask for it to be enabled, or fall back to Plan B (detector per station).")
    elseif type(p) ~= "table" then
      print(("  %s: returned %s"):format(n, tostring(p)))
      print("  => nil = you are OUTSIDE playerDetMaxRange. It is CAPPED; ask for -1, or Plan B.")
    else
      print(("  %s: x=%s y=%s z=%s"):format(n, tostring(p.x), tostring(p.y), tostring(p.z)))
      print(("     dim=%s"):format(tostring(p.dimension)))
      if p.dimension == nil then
        print("  => no `dimension` field: morePlayerInformation = FALSE.")
        print("  => Ask for TRUE, else a player in the Nether can wake the floor.")
      end
    end
  end
  print("")
  print("CHECK: compare the x/z above against F3.")
  print("Off by tens of blocks => enablePlayerPosRandomError = TRUE => remote stations WILL NOT work.")
  print("Re-run this from ~1000 blocks out. nil there = capped range.")
  return
end
```

- [ ] **Step 3: Syntax check**

Run: `luajit -bl src/hub/hub.lua /dev/null && echo SYNTAX_OK`
Expected: `SYNTAX_OK`

- [ ] **Step 4: Verify the existing `hub test` still routes correctly**

Read the file back and confirm the new block sits **above** `if args[1] == "test" then`, and that the old block is untouched. `hub test` (no second arg) must still reach the live `isPlayersInRange` meter.

- [ ] **Step 5: Commit**

```bash
git add src/hub/hub.lua
git commit -m "feat(hub): \`hub test pos\` — spike the three AP config values proximity needs"
```

---

### Task 2: `lib/proximity.lua` — pure zone math

**Files:**
- Create: `src/lib/proximity.lua`
- Test: `test/test_proximity.lua`

**Interfaces:**
- Consumes: nothing. **No CC APIs** — it must run under bare luajit.
- Produces (Tasks 4 and 5 depend on these exact names and types):
  - `M.DEFAULT_RANGE = 4` (number), `M.DEFAULT_YRANGE = 3` (number)
  - `M.parsePos(v)` → `{x=number, y=number, z=number}` or `nil`. Accepts `"x,y,z"` string or an already-valid table.
  - `M.near(station, playerPos, defaultDim)` → `boolean`. `station` = `{pos={x,y,z}, dim=string|nil, range=number|nil, yRange=number|nil}`. `playerPos` = a `getPlayerPos` return.
  - `M.evaluate(stations, positions, defaultDim)` → `{ [computerID] = boolean }`. `stations` keyed by computerID; `positions` keyed by player name.
  - `M.edges(prev, now)` → `{ {id=computerID, present=boolean}, ... }`, **changes only**, sorted by `id`.

- [ ] **Step 1: Write the failing test**

Create `test/test_proximity.lua`:

```lua
package.path = "src/lib/?.lua;test/?.lua;" .. package.path
local t = require("runner")
local P = require("proximity")

local OVER, NETHER = "minecraft:overworld", "minecraft:the_nether"
local function st(x, y, z, extra)
  local s = { pos = { x = x, y = y, z = z } }
  for k, v in pairs(extra or {}) do s[k] = v end
  return s
end
local function pp(x, y, z, dim) return { x = x, y = y, z = z, dimension = dim or OVER } end

-- parsePos: the cfg escape hatch. Strings in, table out.
t.eq(P.parsePos("10,64,-20").x, 10, "parsePos x")
t.eq(P.parsePos("10,64,-20").y, 64, "parsePos y")
t.eq(P.parsePos("10,64,-20").z, -20, "parsePos z")
t.eq(P.parsePos(" 10 , 64 , -20 ").z, -20, "parsePos tolerates spaces")
t.eq(P.parsePos("10.5,64,-20.25").x, 10.5, "parsePos accepts decimals")
t.eq(P.parsePos("10,64"), nil, "parsePos rejects 2 components")   -- NOT .z -- indexing nil would error, not fail
t.eq(P.parsePos("a,b,c"), nil, "parsePos rejects non-numbers")
t.eq(P.parsePos(""), nil, "parsePos rejects empty")
t.eq(P.parsePos(nil), nil, "parsePos rejects nil")
t.eq(P.parsePos({ x = 1, y = 2, z = 3 }).y, 2, "parsePos passes a valid table through")
t.eq(P.parsePos({ x = 1, y = 2 }), nil, "parsePos rejects an incomplete table")

-- near: an axis-aligned box. Default range 4 in x/z, 3 in y. Boundaries are INCLUSIVE.
t.ok(P.near(st(0, 64, 0), pp(0, 64, 0), OVER), "player on the station -> near")
t.ok(P.near(st(0, 64, 0), pp(4, 64, 4), OVER), "at the x/z boundary (4) -> near")
t.ok(not P.near(st(0, 64, 0), pp(5, 64, 0), OVER), "one past x boundary -> not near")
t.ok(not P.near(st(0, 64, 0), pp(0, 64, 5), OVER), "one past z boundary -> not near")
t.ok(P.near(st(0, 64, 0), pp(0, 67, 0), OVER), "at the y boundary (3) -> near")
t.ok(not P.near(st(0, 64, 0), pp(0, 68, 0), OVER), "one past y boundary -> not near (floor above)")
t.ok(P.near(st(0, 64, 0), pp(-4, 61, -4), OVER), "negative corner -> near")
t.ok(P.near(st(0, 64, 0, { range = 10 }), pp(9, 64, 0), OVER), "range override widens x/z")
t.ok(not P.near(st(0, 64, 0, { range = 1 }), pp(2, 64, 0), OVER), "range override narrows x/z")
t.ok(P.near(st(0, 64, 0, { yRange = 20 }), pp(0, 80, 0), OVER), "yRange override widens y")

-- dimension: the ONE filter getPlayerPos does not do for us (spec fact 4).
t.ok(not P.near(st(0, 64, 0), pp(0, 64, 0, NETHER), OVER),
  "same x/z in the NETHER -> NOT near (the whole point of fact 4)")
t.ok(P.near(st(0, 64, 0, { dim = NETHER }), pp(0, 64, 0, NETHER), OVER),
  "a station that declares itself in the Nether matches a Nether player")
t.ok(not P.near(st(0, 64, 0, { dim = NETHER }), pp(0, 64, 0, OVER), OVER),
  "...and stops matching overworld players")
t.ok(P.near(st(0, 64, 0), { x = 0, y = 64, z = 0 }, OVER),
  "no dimension field -> PERMISSIVE (a false wake is cosmetic; a bricked floor is not)")

-- garbage in
t.ok(not P.near(st(0, 64, 0), nil, OVER), "nil playerPos -> not near")
t.ok(not P.near(st(0, 64, 0), { x = 0, z = 0 }, OVER), "playerPos missing y -> not near")
t.ok(not P.near({ pos = nil }, pp(0, 64, 0), OVER), "station with no pos -> not near")
t.ok(not P.near(nil, pp(0, 64, 0), OVER), "nil station -> not near")

-- evaluate: every station judged against every player. Keys are computer IDs.
do
  local stations = { [5] = st(0, 64, 0), [7] = st(100, 64, 100), [9] = st(1000, 64, -800) }
  local now = P.evaluate(stations, { alice = pp(1, 64, 1) }, OVER)
  t.eq(now[5], true, "station 5 sees alice")
  t.eq(now[7], false, "station 7 does not")
  t.eq(now[9], false, "the 1000-blocks-out station does not")

  local two = P.evaluate(stations, { alice = pp(1, 64, 1), bob = pp(1000, 64, -800) }, OVER)
  t.eq(two[5], true, "station 5 still sees alice")
  t.eq(two[9], true, "station 9 sees bob at 1000 blocks -- distance is irrelevant to the math")

  t.eq(P.evaluate(stations, {}, OVER)[5], false, "nobody online -> everything empty")
  t.eq(P.evaluate({}, { alice = pp(0, 64, 0) }, OVER)[5], nil, "no stations -> empty result")

  -- two stations at one position both wake. Correct, not a bug.
  local twin = P.evaluate({ [5] = st(0, 64, 0), [6] = st(0, 64, 0) }, { alice = pp(0, 64, 0) }, OVER)
  t.ok(twin[5] and twin[6], "two stations at one position both wake")

  -- a player the hub could not locate (getPlayerPos returned nil -> never entered `positions`)
  t.eq(P.evaluate(stations, { alice = pp(1, 64, 1), bob = false }, OVER)[5], true,
    "a junk entry cannot crash the sweep or mask a real player")
end

-- edges: ONLY changes. This is what keeps rednet quiet while nobody moves.
do
  local e = P.edges({}, { [5] = false, [7] = false })
  t.eq(#e, 0, "first poll, nobody present -> NO messages (false == absent default)")

  e = P.edges({ [5] = false }, { [5] = true })
  t.eq(#e, 1, "arrival -> one edge")
  t.eq(e[1].id, 5, "edge carries the computer ID")
  t.eq(e[1].present, true, "edge carries present=true")

  e = P.edges({ [5] = true }, { [5] = true })
  t.eq(#e, 0, "standing still -> NO messages")

  e = P.edges({ [5] = true }, { [5] = false })
  t.eq(#e, 1, "departure -> one edge")
  t.eq(e[1].present, false, "departure edge is present=false")

  e = P.edges({ [5] = true, [7] = true }, { [5] = false, [7] = true })
  t.eq(#e, 1, "only the station that changed emits")
  t.eq(e[1].id, 5, "and it is the right one")

  -- a station that was present then deregistered must still be told to sleep
  e = P.edges({ [5] = true }, {})
  t.eq(#e, 1, "deregistered while present -> tell it to sleep")
  t.eq(e[1].present, false, "...with present=false")
  t.eq(#P.edges({ [5] = false }, {}), 0, "deregistered while absent -> nothing to say")

  -- deterministic ordering, so this test and the hub's log are stable
  e = P.edges({}, { [9] = true, [5] = true, [7] = true })
  t.eq(e[1].id, 5, "edges sorted by id (1)")
  t.eq(e[2].id, 7, "edges sorted by id (2)")
  t.eq(e[3].id, 9, "edges sorted by id (3)")
end

t.done()
```

- [ ] **Step 2: Run it to verify it fails**

Run: `luajit test/test_proximity.lua`
Expected: FAIL — `module 'proximity' not found`

- [ ] **Step 3: Write the implementation**

Create `src/lib/proximity.lua`:

```lua
-- proximity.lua — pure zone math for per-station presence. No CC APIs: unit-testable under luajit.
--
-- The hub asks the player detector WHO is online and WHERE each player is -- that is O(players) --
-- and then everything below is free Lua, however many stations the floor grows to. See
-- docs/superpowers/specs/2026-07-17-per-station-proximity-design.md.
--
-- A zone is an axis-aligned BOX around the station: `range` in x/z, `yRange` in y. This is OUR
-- shape, not Advanced Peripherals' -- AP's own ranges are Chebyshev squares in x/z with a quirky
-- feet/eye y rule (spec fact 5), which we never inherit because we never ask AP to do the matching.
local M = {}

M.DEFAULT_RANGE  = 4   -- blocks in x/z: a 9x9 column. A player at the machine, not merely in the room.
M.DEFAULT_YRANGE = 3   -- blocks in y: enough for a tall station, tight enough to ignore the floor above.

-- Accept a cfg `pos=x,y,z` string (or an already-good table) -> {x,y,z} | nil.
function M.parsePos(v)
  if type(v) == "table" then
    if type(v.x) == "number" and type(v.y) == "number" and type(v.z) == "number" then return v end
    return nil
  end
  if type(v) ~= "string" then return nil end
  local x, y, z = v:match("^%s*(-?%d+%.?%d*)%s*,%s*(-?%d+%.?%d*)%s*,%s*(-?%d+%.?%d*)%s*$")
  if not x then return nil end
  return { x = tonumber(x), y = tonumber(y), z = tonumber(z) }
end

-- Is this player inside this station's box? `p` is a getPlayerPos return.
function M.near(station, p, defaultDim)
  if type(station) ~= "table" or type(p) ~= "table" then return false end
  local sp = station.pos
  if type(sp) ~= "table" then return false end
  if type(p.x) ~= "number" or type(p.y) ~= "number" or type(p.z) ~= "number" then return false end

  -- getPlayerPos does NOT filter by dimension (spec fact 4): at playerDetMaxRange = -1 with
  -- playerDetMultiDimensional on, it happily returns a player standing in the Nether. So a station
  -- at the same x/z would wake for them. This line is the only thing stopping that.
  -- If the field is missing entirely (morePlayerInformation = false) we CANNOT filter -- be
  -- permissive: a rare false wake is cosmetic, a floor that never wakes is a brick. `hub test pos`
  -- reports the missing field so it gets fixed at the server, not papered over here.
  local dim = station.dim or defaultDim
  if dim and p.dimension and dim ~= p.dimension then return false end

  local r  = station.range  or M.DEFAULT_RANGE
  local yr = station.yRange or M.DEFAULT_YRANGE
  return math.abs(p.x - sp.x) <= r
     and math.abs(p.z - sp.z) <= r
     and math.abs(p.y - sp.y) <= yr
end

-- stations: computerID -> {pos, dim?, range?, yRange?}. positions: playerName -> getPlayerPos return.
-- -> computerID -> boolean. O(stations x players) of pure Lua, and ZERO peripheral calls.
function M.evaluate(stations, positions, defaultDim)
  local out = {}
  for id, station in pairs(stations or {}) do
    local present = false
    for _, p in pairs(positions or {}) do
      if M.near(station, p, defaultDim) then present = true; break end
    end
    out[id] = present
  end
  return out
end

-- Only what CHANGED. The hub sends one addressed message per edge, so a floor where nobody moves
-- is a floor with no rednet traffic at all -- the same edge-only contract idle_logic.occupancyChanged
-- gives the legacy "all" zone.
function M.edges(prev, now)
  prev, now = prev or {}, now or {}
  local out = {}
  for id, present in pairs(now) do
    if (prev[id] and true or false) ~= (present and true or false) then
      out[#out + 1] = { id = id, present = present and true or false }
    end
  end
  -- Deregistered (or forgotten) while present: it is still awake and nothing else will ever tell it
  -- to sleep. Say so once.
  for id, was in pairs(prev) do
    if was and now[id] == nil then out[#out + 1] = { id = id, present = false } end
  end
  table.sort(out, function(a, b) return a.id < b.id end)   -- deterministic: stable tests, stable logs
  return out
end

return M
```

- [ ] **Step 4: Run the tests**

Run: `luajit test/test_proximity.lua`
Expected: `47 passed, 0 failed` (exact count may differ slightly; **0 failed** is the gate)

- [ ] **Step 5: Confirm it is genuinely CC-free**

Run:
```bash
luajit -e 'local P = dofile("src/lib/proximity.lua"); print("pure: loads with NO CC globals; DEFAULT_RANGE=" .. P.DEFAULT_RANGE)'
```
Expected: `pure: loads with NO CC globals; DEFAULT_RANGE=4`

This is the check that actually *proves* purity — bare luajit has no `peripheral`/`rednet`/`term`, so if the module touched one at load time it would error here. (An earlier version of this plan grepped for CC API names and expected no output. Don't: that grep matches comment prose, and `term` matches the word "de**term**inistic", so its documented pass condition is unreachable and reads as a failure. Grep greps English too.)

- [ ] **Step 6: Commit**

```bash
git add src/lib/proximity.lua test/test_proximity.lua
git commit -m "feat(proximity): pure zone math -- parsePos/near/evaluate/edges"
```

---

### Task 3: Hub — `station_pos` handler + persistence

**Files:**
- Modify: `src/hub/hub.lua` (registry init ~line 76-87; registrar loop ~line 120-172)

**Interfaces:**
- Consumes: `require("proximity")` (Task 2) for `parsePos`.
- Produces (Task 4 and Task 5 depend on these):
  - Persisted `reg.stations[computerID] = { pos={x,y,z}, dim=string|nil, range=number|nil, label=string|nil }`
  - Message in: `{ kind="station_pos", computerID=number, pos={x,y,z}|nil, dim=string|nil, range=number|nil, label=string|nil }`
  - Message out: `{ kind="station_pos_ok", computerID=number, zone=number }`
  - `hub test zones` — prints the registered station table.

- [ ] **Step 1: Require proximity and initialise the store**

At the top of `src/hub/hub.lua`, beside `local idle = require("idle_logic")` (line 18), add:

```lua
local prox      = require("proximity")
local DIM       = "minecraft:overworld"   -- stations are assumed here unless they say otherwise.
                                          -- There is no CC API for "what dimension am I in", so this
                                          -- is config -- but a station that GPS-located itself has
                                          -- already proved it shares the constellation's dimension
                                          -- (spec fact 7).
```

In the registry init block, after the line `reg.counters    = reg.counters or {}`, add:

```lua
reg.stations    = reg.stations or {}      -- computerID -> { pos = {x,y,z}, dim, range, label }
```

- [ ] **Step 2: Add the `station_pos` handler**

In `registrar()`, immediately after the `register` branch's `print(...)` line and before the `mint` branch, add:

```lua
    elseif type(msg) == "table" and msg.kind == "station_pos"
           and type(msg.computerID) == "number" then
      -- A station reporting where it is. `pos = nil` deregisters it (it lost GPS and has no cfg),
      -- which drops it back to the legacy "all" zone rather than stranding it asleep forever.
      local pos = prox.parsePos(msg.pos)
      if pos then
        reg.stations[msg.computerID] = {
          pos   = pos,
          dim   = (type(msg.dim) == "string") and msg.dim or nil,
          range = tonumber(msg.range) or nil,
          label = (type(msg.label) == "string") and msg.label or nil,
        }
        print(("  #%d  pos %d,%d,%d%s"):format(msg.computerID, pos.x, pos.y, pos.z,
          msg.label and (" (" .. msg.label .. ")") or ""))
      else
        reg.stations[msg.computerID] = nil
        print(("  #%d  pos cleared -> legacy 'all' zone"):format(msg.computerID))
      end
      persist()
      rednet.send(sender, { kind = "station_pos_ok", computerID = msg.computerID,
                            zone = msg.computerID }, PROTO)
```

- [ ] **Step 3: Make the existing `test` guard stop swallowing subcommands**

`hub test zones` needs `reg.stations`, which is only loaded further down the file (~line 76). But the existing block at line 51 reads `if args[1] == "test" then ... return end`, so it would catch `test zones` first and print the live range meter instead. **Narrow that guard** — change:

```lua
if args[1] == "test" then
```

to:

```lua
if args[1] == "test" and not args[2] then
```

(`hub test pos` from Task 1 sits above this and is unaffected either way; this change is what lets any *later* subcommand exist at all.)

- [ ] **Step 4: Add `hub test zones` after the registry loads**

Insert immediately after the `reg.stations = reg.stations or {}` line from Step 1 — it must be **after** the registry load and **before** `print("Hub v0 registrar online.")`:

```lua
-- `hub test zones` — what the hub thinks the floor looks like. A station that never appears here
-- never registered a position, and is therefore still on the legacy "all" zone (not an error).
if args[1] == "test" and args[2] == "zones" then
  local n = 0
  for id, s in pairs(reg.stations) do
    n = n + 1
    print(("  #%d  %s  pos=%d,%d,%d  range=%s  dim=%s"):format(
      id, s.label or "?", s.pos.x, s.pos.y, s.pos.z,
      tostring(s.range or prox.DEFAULT_RANGE), tostring(s.dim or DIM)))
  end
  if n == 0 then print("No stations have registered a position. All are on the legacy 'all' zone.") end
  return
end

-- An unknown subcommand must not silently boot the hub: `hub test drop` would otherwise look like it
-- worked while actually starting the registrar.
if args[1] == "test" then
  print(("Unknown subcommand: test %s"):format(tostring(args[2])))
  print("Try: `hub test` (range meter), `hub test pos`, `hub test zones`.")
  return
end
```

- [ ] **Step 5: Syntax check**

Run: `luajit -bl src/hub/hub.lua /dev/null && echo SYNTAX_OK`
Expected: `SYNTAX_OK`

- [ ] **Step 6: Verify no existing branch was disturbed**

Run: `grep -cE 'msg\.kind == "(register|mint|bet|debit|credit|query)"' src/hub/hub.lua`
Expected: `6` — all six original handlers still present and untouched.

- [ ] **Step 7: Verify all three `test` subcommands route**

Read the file and confirm the order top-to-bottom is: `test pos` (Task 1) → `test` with `not args[2]` (the range meter) → registry load → `test zones` → unknown-subcommand catch → `print("Hub v0 registrar online.")`. Each must `return`.

- [ ] **Step 8: Commit**

```bash
git add src/hub/hub.lua
git commit -m "feat(hub): station_pos handler + persisted computerID -> position map"
```

---

### Task 4: Hub — `presenceLoop` rewritten around the oracle

**GATE: do not start until `hub test pos` (Task 1) has come back green in-world.** If it reported a throw, a `nil` at distance, or fuzzed coordinates, **stop and report** — the spec's Plan B (a `player_detector` per station) is the fallback and it is a different design.

**Files:**
- Modify: `src/hub/hub.lua` (`presenceLoop`; also the `presence?` reply in `registrar()`)
- Modify: `src/lib/idle_logic.lua` (`presenceFor` — **one line**)
- Modify: `test/test_idle_logic.lua` (it asserts the contract being changed)

**Interfaces:**
- Consumes: `prox.evaluate`, `prox.edges` (Task 2); `reg.stations` (Task 3).
- Produces: `{ kind="presence", zone=<computerID>, present=<bool> }` **addressed via `rednet.send`** to that computer ID. The legacy `{ kind="presence", zone="all", present=occ }` broadcast still goes out for unregistered stations.

> ### PLAN CORRECTION (2026-07-17) — this task originally could not work. Read before starting.
>
> This task first said "keep the legacy broadcast byte-for-byte AND leave `idle_logic.presenceFor`
> unchanged". **Those two are contradictory**, and the whole-branch review caught it. `presenceFor`
> matched `msg.zone == "all" or msg.zone == myZone` — the `"all"` clause matches **unconditionally**,
> so a station registered to zone `5` *still* wakes on the floor-wide broadcast. A player at the hub
> would wake the cage 1000 blocks away: **the original bug, fully intact**. Step 3 of this plan's own
> in-world checklist ("walk to the hub → the cage does **not** wake") was unpassable.
>
> The owner approved the fix below on 2026-07-17. **Both halves must land in this task**; half of it
> is worse than neither, because half silently breaks the boot resync instead.

- [ ] **Step 0a: Make `presenceFor` stop treating `"all"` as a wildcard**

In `src/lib/idle_logic.lua`, change the one condition in `presenceFor`:

```lua
-- A zone name means what it says. This deliberately does NOT special-case "all" as a wildcard:
-- an UNREGISTERED station's zone IS literally the string "all", so it still matches the hub's
-- floor-wide broadcast (no regression), while a station registered to its own computer ID stops
-- matching it. Treating "all" as a wildcard here is what made per-station zones a no-op -- a player
-- at the hub woke every station on the floor, which is the bug this whole feature exists to kill.
function M.presenceFor(msg, myZone)
  if type(msg) ~= "table" or msg.kind ~= "presence" then return nil end
  if msg.zone == myZone then
    return msg.present and true or false
  end
  return nil
end
```

- [ ] **Step 0b: Update the tests that assert the OLD contract**

`test/test_idle_logic.lua` currently asserts a wildcard `"all"` matches a station in zone `"slot1"`. That is exactly the behaviour being removed. Replace the first block:

```lua
-- presenceFor: a zone name means what it says. "all" is NOT a wildcard -- it is the literal zone an
-- unregistered station answers to, which is why the floor-wide broadcast still reaches those and
-- ONLY those.
t.eq(I.presenceFor({ kind = "presence", zone = "all", present = true }, "all"), true,
  "unregistered station (zone 'all') wakes on the floor-wide broadcast")
t.eq(I.presenceFor({ kind = "presence", zone = "all", present = false }, "all"), false,
  "...and sleeps on it")
t.eq(I.presenceFor({ kind = "presence", zone = "all", present = true }, 5), nil,
  "REGISTERED station (zone 5) IGNORES the floor-wide broadcast -- a player at the hub must NOT wake it")
t.eq(I.presenceFor({ kind = "presence", zone = 5, present = true }, 5), true,
  "registered station wakes on its OWN zone")
t.eq(I.presenceFor({ kind = "presence", zone = 5, present = false }, 5), false,
  "...and sleeps on its own zone")
t.eq(I.presenceFor({ kind = "presence", zone = 7, present = true }, 5), nil,
  "another station's zone -> nil (ignore)")
t.eq(I.presenceFor({ kind = "presence", zone = "slot1", present = true }, "slot1"), true,
  "a pinned string zone still works")
t.eq(I.presenceFor({ kind = "presence", zone = "slot2", present = true }, "slot1"), nil,
  "other zone -> nil (ignore)")
t.eq(I.presenceFor({ kind = "register" }, "slot1"), nil, "non-presence msg -> nil")
t.eq(I.presenceFor("hello", "slot1"), nil, "non-table msg -> nil")
```

Also check the `newPresence` block further down the same file — it feeds `zone = "all"` messages to a handle built with zone `"slot1"` and expects them to match. Those cases must be rewritten to use a matching zone, or they will now fail. Run the file and fix whatever it reports; do not delete a failing case to make it pass — each one encodes a real contract.

- [ ] **Step 0c: Make the hub's `presence?` reply zone-aware**

In `registrar()`, the presence-query branch currently always answers `zone = "all"`. A registered station would get an answer it no longer matches, silently breaking the boot resync that the whole 1000-blocks-out design depends on. It must answer that station's own zone. The station's query already carries `msg.zone` (see `idle_runner.queryPresence`).

`presenceLoop` must therefore share its per-station map with `registrar()`, exactly the way `occupied` already is. Add beside `local occupied = false`:

```lua
-- Shared with presenceLoop, same reason `occupied` is: the registrar answers `presence?` pulls and
-- must give a registered station ITS OWN presence, not the floor-wide answer. A station that just
-- booted (chunk loaded because a player walked up) pulls before it can be pushed to -- that pull is
-- the entire reason a station 1000 blocks out works at all.
local zonePresent = {}     -- computerID -> boolean
```

Replace the presence-query branch with:

```lua
    elseif idle.isPresenceQuery(msg) then
      local z = msg.zone
      if type(z) == "number" and zonePresent[z] ~= nil then
        rednet.send(sender, { kind = "presence", zone = z, present = zonePresent[z] }, PROTO)
      else
        rednet.send(sender, { kind = "presence", zone = "all", present = occupied }, PROTO)
      end
```

- [ ] **Step 1: Replace `presenceLoop` wholesale**

Replace the entire existing `presenceLoop` function with:

```lua
-- The hub's one forever-loop, and the floor's only proximity cost.
--
-- Per poll: isPlayersInRange (1 call, the legacy "all" zone) + getOnlinePlayers (1 call) +
-- getPlayerPos per online player (P calls). That is `2 + P` -- it does NOT grow with the number of
-- stations, which is the whole reason this design exists. Every one of those is mainThread = true
-- (~50ms of parked coroutine each, see [[main-thread-peripheral-calls-cost-a-tick]]), so the call
-- count is the budget. Matching is pure Lua and free. NEVER add a per-station peripheral call here.
--
-- Known bound, named not fixed: P is every player online SERVER-WIDE (playerDetMaxRange = -1), not
-- just the ones near the floor. Fine for a close-friends server; if this ever runs 20+ concurrent
-- players, raise POLL or gate on getPlayersInRange first. Do not pre-optimise.
local function presenceLoop()
  local det = peripheral.find("player_detector")
  if not det then
    print("No player detector attached — presence disabled (registrar only).")
    return
  end
  print(("Presence loop online: isPlayersInRange(%d) + position oracle every %.2fs."):format(DET_RANGE, POLL))
  local proxOff, warnedNil = false, false
  local timer = os.startTimer(POLL)
  while true do
    local ev = { os.pullEvent() }
    if ev[1] == "timer" and ev[2] == timer then
      -- ---- legacy "all" zone: byte-for-byte the old behaviour, for stations with no position ----
      local occ = det.isPlayersInRange(DET_RANGE) and true or false
      if idle.occupancyChanged(occupied, occ) then
        rednet.broadcast({ kind = "presence", zone = "all", present = occ }, PROTO)
        print(occ and "[presence] occupied -> WAKE" or "[presence] empty -> SLEEP")
      end
      occupied = occ

      -- ---- per-station zones ----
      if not proxOff and next(reg.stations) ~= nil then
        local positions = {}
        local names = det.getOnlinePlayers()
        for _, name in ipairs(names) do
          -- pcall: getPlayerPos THROWS when enablePlayerPosFunction = false (spec fact 3). Unguarded,
          -- that kills the hub, and the hub is the one machine the whole floor depends on.
          local ok, p = pcall(det.getPlayerPos, name)
          if not ok then
            proxOff = true
            print("=====================================================")
            print(" PER-STATION PROXIMITY DISABLED")
            print(" getPlayerPos is disabled in the server config")
            print(" (enablePlayerPosFunction = false). Run `hub test pos`.")
            print(" Falling back to the floor-wide 'all' zone.")
            print("=====================================================")
            break
          end
          if type(p) == "table" then
            positions[name] = p
          elseif not warnedNil then
            -- nil for a player who IS online is the ONLY tell that playerDetMaxRange is capped --
            -- and it is otherwise completely silent: a capped range looks exactly like "nobody is
            -- there", so distant stations would just never wake and nothing would say why. (It can
            -- also mean the player logged off mid-poll, which is harmless -- hence a one-time note,
            -- not a fatal.) The owner verified getPlayerPos out to ~500 blocks, so at -1 this should
            -- never print; if it starts printing, the cap is real and the stations beyond it are the
            -- ones going dark.
            warnedNil = true
            print(("[proximity] NOTE: getPlayerPos(%s) returned nil for an ONLINE player."):format(name))
            print("  Harmless if they just logged off. If it repeats, playerDetMaxRange is CAPPED —")
            print("  stations beyond it will never wake. Run `hub test pos` from a far station.")
          end
        end
        if not proxOff then
          local now = prox.evaluate(reg.stations, positions, DIM)
          for _, e in ipairs(prox.edges(zonePresent, now)) do
            rednet.send(e.id, { kind = "presence", zone = e.id, present = e.present }, PROTO)
            print(("[zone] #%d -> %s"):format(e.id, e.present and "WAKE" or "SLEEP"))
          end
          zonePresent = now   -- shared upvalue: the registrar answers `presence?` pulls from this
        end
      end

      timer = os.startTimer(POLL)
    end
  end
end
```

- [ ] **Step 2: Syntax check**

Run: `luajit -bl src/hub/hub.lua /dev/null && echo SYNTAX_OK`
Expected: `SYNTAX_OK`

- [ ] **Step 3: Verify the call-count budget by inspection**

Run: `grep -nE "det\.(isPlayersInRange|getOnlinePlayers|getPlayerPos)" src/hub/hub.lua`
Expected: exactly three hits inside `presenceLoop` (plus the two in the `test` blocks). **None of them may sit inside a loop over `reg.stations`.** If a detector call appears in a per-station loop, the task has failed its core constraint.

- [ ] **Step 4: Verify the legacy path still reaches unregistered stations**

Run: `grep -n 'zone = "all"' src/hub/hub.lua`
Expected: two hits — the `presenceLoop` broadcast, and the **fallback** arm of the `presence?` reply in `registrar()`. A registered station must no longer be answered `"all"`.

- [ ] **Step 5: Run the idle_logic tests**

Run: `luajit test/test_idle_logic.lua`
Expected: `0 failed`. These now encode the new contract — in particular that a **registered** station ignores the floor-wide broadcast. That single assertion is the difference between this feature working and being a no-op.

- [ ] **Step 6: Prove the bug is actually dead (the check the old plan couldn't pass)**

Run:
```bash
luajit -e '
  package.path = "src/lib/?.lua;" .. package.path
  local I = require("idle_logic")
  local B = { kind = "presence", zone = "all", present = true }   -- the hub floor-wide broadcast
  assert(I.presenceFor(B, "all") == true,  "unregistered station must STILL wake on the broadcast")
  assert(I.presenceFor(B, 5)     == nil,   "registered station must IGNORE the broadcast")
  assert(I.presenceFor({ kind = "presence", zone = 5, present = true }, 5) == true,
         "registered station must wake on its own addressed zone")
  print("per-station zones are real: a player at the hub no longer wakes the cage")
'
```
Expected: `per-station zones are real: a player at the hub no longer wakes the cage`

- [ ] **Step 7: Commit**

```bash
git add src/hub/hub.lua src/lib/idle_logic.lua test/test_idle_logic.lua
git commit -m "feat(hub): presenceLoop as a position oracle -- O(players), not O(stations)"
```

---

### Task 5: Station — resolve position, register it, default the zone

**Files:**
- Modify: `src/lib/idle_runner.lua`
- Modify: `src/cage/cage.lua` (CFG block ~line 82-90; `loadCfg` scalars ~line 303; the `idle_runner.run` call ~line 917)
- Modify: `src/slot/slot.lua` (line 20)
- Modify: `src/pong/pong.lua` (line 170)

**Interfaces:**
- Consumes: `prox.parsePos` (Task 2); the hub's `station_pos` / `station_pos_ok` (Task 3).
- Produces: `idle_runner.run{ name, monitor, zone?, pos?, dim?, range?, wake?, play }`. `cfg.zone` **nil** now means "auto": the computer ID if a position registered, else `"all"`.

- [ ] **Step 1: Add position resolution + registration to `idle_runner`**

In `src/lib/idle_runner.lua`, after `local idle = require("idle_logic")`, add:

```lua
local prox  = require("proximity")
```

Then, immediately before `local function run(cfg)`, add:

```lua
-- Where am I? gps.locate first, so a floor of hundreds of stations never needs hand-typed
-- coordinates; `pos=x,y,z` in the station's .cfg is the escape hatch and the answer before the GPS
-- constellation exists. Neither -> we simply do not register, and stay on the legacy "all" zone.
--
-- gps.locate needs a WIRELESS MODEM ON A SIDE OF THE COMPUTER -- it scans rs.getSides() only, never
-- the cable (spec fact 8). Mounting the ender modem on a wired network (if that even works) would
-- silently kill GPS here. Keep it on a side.
--
-- The constellation must be 3 hosts + a 4th LIFTED OFF THEIR PLANE; four coplanar hosts cannot
-- resolve trilateration's mirror and gps.locate just returns nil (spec fact 9,
-- test/spikes/gps_constellation.lua). One force-loaded chunk is plenty -- CC's GPS distances are
-- exact, so horizontal spread buys nothing.
local function resolvePos(cfg)
  local fromCfg = prox.parsePos(cfg.pos)
  if fromCfg then return fromCfg, "cfg" end
  if gps then
    local x, y, z = gps.locate(2)
    if x then return { x = x, y = y, z = z }, "gps" end
  end
  return nil, "none"
end

-- Tell the hub where we are. Best-effort and non-fatal: a station whose hub is down still plays
-- (its lever wakes it), it just will not get proximity until the hub hears from it again.
-- Returns true only if the hub ACKED -- an OLD hub silently ignores station_pos and would otherwise
-- look identical to success (see todo.md's `hub_version` follow-up).
local function registerPos(pos, cfg)
  local hub = rednet.lookup(PROTO, "hub")
  if not hub then return false end
  rednet.send(hub, {
    kind = "station_pos", computerID = os.getComputerID(), pos = pos,
    dim = cfg.dim, range = cfg.range, label = os.getComputerLabel(),
  }, PROTO)
  local timer = os.startTimer(2)
  while true do
    local ev = { os.pullEvent() }
    if ev[1] == "rednet_message" and type(ev[3]) == "table"
       and ev[3].kind == "station_pos_ok" then
      return true
    elseif ev[1] == "timer" and ev[2] == timer then
      return false
    end
  end
end
```

**Note on the event loop above:** this runs once at boot, *before* `deepSleep`, so there is no caller loop whose timer it could swallow — unlike `wallet.request`, it needs no stash/re-queue (`[[event-pump-reentrancy]]`). Do not copy this pattern into a hot path.

- [ ] **Step 2: Wire it into `run`**

Replace the first three lines of `run(cfg)`:

```lua
local function run(cfg)
  local zone   = cfg.zone or "all"
  local mon    = cfg.monitor
  local advert = require(cfg.name .. "_advert")

  local hasRednet = openAllModems() > 0
```

with:

```lua
local function run(cfg)
  local mon    = cfg.monitor
  local advert = require(cfg.name .. "_advert")

  local hasRednet = openAllModems() > 0

  -- Zone resolution. cfg.zone pins it (legacy stations, or two computers sharing one zone).
  -- Otherwise: our own computer ID if the hub knows where we are, else the floor-wide "all".
  -- The registrar already keys everything by the immutable os.getComputerID(), so reusing it as the
  -- zone costs no new names, cannot collide, and lets the hub rednet.send straight to us --
  -- rednet addresses BY computer ID, so per-station presence needs no broadcast at all.
  local zone = cfg.zone
  if not zone then
    zone = "all"
    if hasRednet then
      local pos, src = resolvePos(cfg)
      if pos and registerPos(pos, cfg) then
        zone = os.getComputerID()
        print(("[zone] #%d at %d,%d,%d (%s)"):format(zone, pos.x, pos.y, pos.z, src))
      elseif pos then
        print("[zone] hub did not ack station_pos (offline, or too old) -> zone 'all'")
      else
        print("[zone] no position (no GPS fix, no pos= in cfg) -> zone 'all'")
      end
    end
  end
```

`idle_logic.presenceFor(msg, myZone)` already matches `msg.zone == "all" or msg.zone == myZone` — **it needs no change.** This is the "config-only upgrade" the idle spec promised.

- [ ] **Step 3: Add the cfg keys to `cage.lua`**

In the `CFG` table, change `zone = "all",` to:

```lua
  zone     = nil,        -- nil = AUTO: this computer's ID once the hub knows our position, else "all"
  pos      = nil,        -- "x,y,z" — only needed until the GPS constellation exists; gps.locate wins nothing
                         -- if this is set, because cfg ALWAYS wins over discovery
  dim      = nil,        -- nil = the hub's dimension (minecraft:overworld)
  range    = nil,        -- nil = proximity.DEFAULT_RANGE (4 blocks in x/z)
```

In `loadCfg`, change the scalars line to:

```lua
    local scalars = { deposit = true, vault = true, side = true, monitor = true, zone = true,
                      pos = true, dim = true, range = true }
```

At the bottom, change the `idle_runner.run` call to:

```lua
require("idle_runner").run{
  name = "cage", monitor = mon, zone = CFG.zone, play = play,
  pos = CFG.pos, dim = CFG.dim, range = tonumber(CFG.range),
}
```

And in the `cage.cfg` header documentation block, replace the `--   zone=all` line with:

```lua
--   pos=105,64,-238         # where this cage IS. Only needed until the GPS constellation exists —
--                           # with GPS a station finds this out itself. `hub test zones` shows what
--                           # the hub believes. Without either, the cage stays on the floor-wide
--                           # "all" zone (i.e. today's behaviour: the hub's range wakes everything).
--   range=4                 # how close a player must get, in x/z. Default 4 (a 9x9 column).
--   dim=minecraft:overworld # only if this cage is NOT in the overworld
--   zone=all                # pin the zone; only to force the legacy floor-wide behaviour
```

- [ ] **Step 4: Un-hardcode the zone in slot and pong**

`src/slot/slot.lua` line 20 — change:

```lua
local ZONE = "all"  -- proximity zone this station answers to. "all" = any player in the hub's range.
```

to:

```lua
-- nil = AUTO: idle_runner registers our GPS position with the hub and we answer to our own computer
-- ID; with no GPS fix we fall back to the floor-wide "all" (today's behaviour). A slot has no .cfg,
-- so GPS is the only way it gets a zone of its own — which is exactly what the constellation buys.
local ZONE = nil
```

`src/pong/pong.lua` line 170 — change `zone = "all"` to `zone = nil`:

```lua
require("idle_runner").run{ name = "pong", monitor = mon, zone = nil, play = play }
```

- [ ] **Step 5: Syntax check every touched file**

Run:
```bash
for f in src/lib/idle_runner.lua src/cage/cage.lua src/slot/slot.lua src/pong/pong.lua; do
  luajit -bl "$f" /dev/null && echo "OK $f"
done
```
Expected: `OK` for all four.

- [ ] **Step 6: Confirm the idle_logic contract really is untouched**

Run: `git status --porcelain src/lib/idle_logic.lua`
Expected: **no output** — i.e. the file is untouched in the working tree, not merely already committed.

The spec's central claim is that the station-side plumbing already existed and this is a config-only upgrade. If this task needed to modify `idle_logic`, that claim was wrong: **stop and report rather than patching it**, because `presenceFor` is what every station's wake path runs through.

Run: `luajit test/test_idle_logic.lua`
Expected: `... 0 failed` — the existing contract still holds.

- [ ] **Step 7: Commit**

```bash
git add src/lib/idle_runner.lua src/cage/cage.lua src/slot/slot.lua src/pong/pong.lua
git commit -m "feat(station): self-locate via gps.locate (cfg pos= fallback), zone = computer ID"
```

---

### Task 6: Deploy manifest + whole-branch verification

**`proximity.lua` does not exist in-world until it is in `packages.lua`.** A missing manifest entry deploys a station that crashes on `require("proximity")` — and per `CLAUDE.md`, the CDN lag means the owner will reasonably suspect a stale cache instead. This project has paid for this bug before.

**Files:**
- Modify: `src/packages.lua`

**Interfaces:**
- Consumes: every file created in Tasks 2-5.
- Produces: a manifest that matches the tree.

- [ ] **Step 1: Add `proximity` to every package that requires it**

`hub` requires it directly; `slot`, `cage`, and `pong` require it transitively via `idle_runner`. Add `{ name = "proximity", path = "lib/proximity.lua" },` to all four:

- `slot.files` — after the `idle_logic` line
- `cage.files` — after the `idle_logic` line
- `pong.files` — after the `idle_logic` line
- `hub.files` — after the `idle_logic` line

(`issue` does not use `idle_runner`; leave it alone.)

- [ ] **Step 2: Verify every manifest path exists on disk**

Run:
```bash
luajit -e '
  local pkgs = dofile("src/packages.lua")
  local bad = 0
  for name, p in pairs(pkgs) do
    for _, f in ipairs(p.files) do
      local path = "src/" .. (f.path or (f.name .. ".lua"))
      local fh = io.open(path, "r")
      if fh then fh:close() else print("MISSING: " .. name .. " -> " .. path); bad = bad + 1 end
    end
  end
  print(bad == 0 and "ALL MANIFEST PATHS OK" or (bad .. " MISSING"))
'
```
Expected: `ALL MANIFEST PATHS OK`

- [ ] **Step 3: Verify every `require` in a package resolves to a shipped file**

Run:
```bash
luajit -e '
  local pkgs = dofile("src/packages.lua")
  local bad = 0
  for name, p in pairs(pkgs) do
    local ships = {}
    for _, f in ipairs(p.files) do ships[f.name] = true end
    for _, f in ipairs(p.files) do
      local path = "src/" .. (f.path or (f.name .. ".lua"))
      for req in io.open(path):read("*a"):gmatch("require%(\"([%w_]+)\"%)") do
        if not ships[req] then
          print(("%s: %s requires %q but the package does not ship it"):format(name, f.name, req))
          bad = bad + 1
        end
      end
    end
  end
  print(bad == 0 and "ALL REQUIRES SATISFIED" or (bad .. " UNSATISFIED"))
'
```
Expected: `ALL REQUIRES SATISFIED`. This is the check that actually catches the bug; Step 2 only proves the repo paths are real.

- [ ] **Step 4: Run the whole unit suite**

Run: `for f in test/test_*.lua; do echo "-- $f"; luajit "$f" || exit 1; done`
Expected: every file `0 failed`.

Run: `luajit test/spikes/gps_constellation.lua`
Expected: `13 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add src/packages.lua
git commit -m "build(deploy): ship lib/proximity with hub, slot, cage and pong"
```

---

## After the plan

**Merge to main and push** (`superpowers:finishing-a-development-branch`, option 1) — the deploy loop pulls from the repo, so in-world verification happens *after* the merge+push. Then wait 2-5 minutes for the CDN (`CLAUDE.md`'s deploy gotcha: a stale `packages.lua` reads as `unknown package` or a short file list — it is not a code bug).

**In-world checklist** (from the spec):

1. `update hub` + reboot, then **`hub test pos`** — at the hub, and again from ~1000 blocks out. **This gates Task 4.**
2. `update cage`; put `pos=<the cage's x,y,z>` in `cage.cfg`; reboot. `hub test zones` should list it.
3. Walk to the cage → **only** the cage wakes. Walk to the hub → the cage does **not** wake. *(This is the bug that started it all: the cage's GUI was never reached because the hub's zone woke everything and nothing woke the cage.)*
4. Walk away → the cage sleeps and redraws its advert.
5. Reboot the cage while standing at it → it wakes immediately (the `presence?` pull path).
6. A station with no `pos` (slot, until GPS exists) still wakes on the `all` zone — **no regression**.
7. Fly to the Nether at the cage's x/z → the cage does **not** wake (spec fact 4).
8. Watch the hub's terminal while nobody moves → **no `[zone]` lines at all**. Edge-only is the contract; chatter here means `edges` is broken.

**Then, and only then, the constellation** (a build task, not a code task — nothing above needs it): four computers in the hub's force-loaded chunk running `gps host <x> <y> <z>`, three at the chunk's corners and **one lifted ~40 blocks** off their plane. Then delete `pos=` from `cage.cfg` and reboot — it should re-derive the same position via GPS and `hub test zones` should be unchanged. That is the moment station #100 becomes wire-it-and-run.

**Known follow-ups, filed not fixed:**
- P is every player online server-wide, not just those near the floor. Fine for a close-friends server; revisit past ~20 concurrent players.
- `hub_version` / ping (already in `todo.md`) — `registerPos` now detects an old hub via the missing ack, which is a point fix for one message, not the general answer.
- Whether a wired cable can carry an ender modem is untested (spec fact 11) — and per fact 8 we do not want it, because it would kill GPS.
