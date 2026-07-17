# MP Economy Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the engine that makes future 2–4 player staked games wire-it-and-run: multi-drive card reads, an extracted card session, and an `mp_econ` pot gateway — with pong as a throwaway debug harness.

**Architecture:** A card session is **one card on one drive**. Bound to `drive = nil` it is exactly today's single-card gateway (`sp_econ`, `cage_econ`) with no behaviour change; bound to N named drives it is N seats. `mp_econ` is N sessions plus pot arithmetic. `wallet` and `ledger` are not touched and **the rednet protocol does not change** — a pot is existing `debit` + `credit` calls.

**Tech Stack:** Lua 5.1 (CraftOS / CC:Tweaked). Tests run under `luajit` with hand-rolled fakes for CC globals. No dependencies, no build step.

**Spec:** `docs/superpowers/specs/2026-07-17-mp-econ-engine-design.md` — read it before Task 1.

## Global Constraints

- **Lua 5.1 only.** No `goto`, no integer division `//`, no bitops. `unpack`, not `table.unpack` (use `local unpack = table.unpack or unpack` if needed).
- **Every file is `require`d by flat name**, never by folder: deploy flattens `src/` by filename. `require("card_session")`, never `require("lib.card_session")`.
- **Money is integer `$`.** `("%d"):format(101.5)` silently prints `101` in Lua 5.1, so a fractional balance would live in the ledger while every screen showed a different number. Split remainders explicitly; shares must sum to exactly the pot.
- **No new blocking calls outside `wallet`.** No `sleep`, no `parallel`, no `rednet.receive`, no `rednet.lookup` anywhere in this branch. `wallet.request`/`wallet._pumpSafe` already stash and re-queue foreign events; anything new that pumps will eat a play loop's tick timer and freeze the station (`[[event-pump-reentrancy]]`).
- **Credit, never `creditNow`, from a station.** Refunds and payouts must outbox on a hub timeout — the player is owed that money.
- **Pay the `antedId`, never `session.player`.** The drive may be empty or hold a stranger by payout time.
- **Tests:** `luajit test/test_<name>.lua`. Assert harness is `test/runner.lua` — `t.eq(actual, expected, msg)`, `t.ok(cond, msg)`, `t.done()`. Every test file starts with `package.path = "src/lib/?.lua;...;test/?.lua;" .. package.path`.
- **Branch:** `feat/mp-econ`. **Progress file:** `.superpowers/sdd/progress-mp.md` (NOT `progress.md` — a parallel session owns that).
- **`todo.md` / `README.md` are contended** by a parallel session. Touch them **only in Task 8**, in one small commit, and rebase before merging.

---

### Task 1: `card.lua` — multi-drive reads

**Files:**
- Modify: `src/lib/card.lua` (whole file)
- Test: `test/test_card.lua` (create — `card.lua` has no tests today)

**Interfaces:**
- Consumes: nothing.
- Produces: `card.drives() -> {string}` (ALL drives, sorted) · `card.read(drive?) -> {id=string, score=number}|nil` · `card.readAll() -> {{drive=string, id=string, score=number}}` · `card.write(id, score, drive?) -> true | false, reason` · `card.writeMirror(score, drive?) -> true | false, reason` · `card.isCardEvent(ev) -> boolean` (unchanged).

**Context:** `card.lua:8`'s `mountPath()` returns the **first** drive with a disk. That single fact bakes one-card-per-station into every layer above it and is the actual MP blocker. This task makes drives addressable **without changing any existing caller** — `drive` is an optional last argument that defaults to today's behaviour.

**`drives()` returns EVERY drive, disk or not.** A drive is a seat, and an empty seat still exists — filtering to drives-with-a-disk would make a cardless player vanish from the station instead of showing up as an anonymous seat. `readAll()` does the filtering.

- [ ] **Step 1: Write the failing test**

Create `test/test_card.lua`. `card.lua` touches the CC globals `peripheral`, `fs` and `textutils`, so they are faked here (the `_G.peripheral = {...}` pattern from `test/test_cage_hw.lua`).

```lua
-- test_card.lua — multi-drive card reads against a FAKE peripheral network + filesystem.
--
-- card.read() used to take the FIRST drive with a disk, which baked single-card-per-station into
-- every gateway above it. These tests pin the two halves of the fix: `drive` is addressable, and
-- omitting it still means exactly what it meant before (the no-regression bar -- slot, cage and
-- issue all call read()/writeMirror() with no argument and must not change behaviour).
package.path = "src/lib/?.lua;test/?.lua;" .. package.path
local t = require("runner")

-- ---- fake CC globals -------------------------------------------------------
local DRIVES = {}   -- name -> { type = "drive", mount = "/disk" | nil }
local FILES  = {}   -- path -> contents

_G.peripheral = {
  getNames = function()
    local n = {}
    for k in pairs(DRIVES) do n[#n + 1] = k end
    table.sort(n)
    return n
  end,
  getType = function(name) return DRIVES[name] and DRIVES[name].type or nil end,
  wrap = function(name)
    local d = DRIVES[name]
    if not d then return nil end
    return {
      isDiskPresent = function() return d.mount ~= nil end,
      getMountPath  = function() return d.mount end,
    }
  end,
}

_G.fs = {
  exists = function(p) return FILES[p] ~= nil end,
  open = function(p, mode)
    if mode == "r" then
      if not FILES[p] then return nil end
      return { readAll = function() return FILES[p] end, close = function() end }
    end
    local buf = {}
    return {
      write = function(s) buf[#buf + 1] = s end,   -- card.lua calls f.write(s), not f:write(s)
      close = function() FILES[p] = table.concat(buf) end,
    }
  end,
}

_G.textutils = {
  serialize = function(v) return ("{id=%q,score=%s}"):format(v.id, tostring(v.score)) end,
  unserialize = function(s)
    local f = loadstring("return " .. s)
    if not f then return nil end
    local ok, v = pcall(f)
    return ok and v or nil
  end,
}

local card = require("card")

local function reset()
  DRIVES, FILES = {}, {}
end

-- put a drive on the network. `mount` nil = drive with NO disk (an empty seat).
local function addDrive(name, mount)
  DRIVES[name] = { type = "drive", mount = mount }
end

local function putCard(mount, id, score)
  FILES[mount .. "/ccvegas_card"] = ("{id=%q,score=%s}"):format(id, tostring(score))
end

-- ---- drives(): EVERY drive, sorted -- an empty seat is still a seat ----
do
  reset()
  addDrive("drive_1", "/disk2")   -- deliberately out of order + a non-drive peripheral
  addDrive("drive_0", "/disk")
  DRIVES["monitor_0"] = { type = "monitor" }
  local d = card.drives()
  t.eq(#d, 2, "drives() ignores non-drive peripherals")
  t.eq(d[1], "drive_0", "drives() is sorted (stable seat order across reboots)")
  t.eq(d[2], "drive_1", "drives() is sorted")
end

do
  reset()
  addDrive("drive_0", nil)        -- no disk
  addDrive("drive_1", "/disk")
  local d = card.drives()
  t.eq(#d, 2, "drives() returns a drive with NO disk -- a seat with no card is still a seat")
  t.eq(d[1], "drive_0", "the empty drive keeps its seat position")
end

-- ---- read(drive): addressable ----
do
  reset()
  addDrive("drive_0", "/disk");  putCard("/disk", "alice", 500)
  addDrive("drive_1", "/disk2"); putCard("/disk2", "bob", 120)
  t.eq(card.read("drive_1").id, "bob", "read(drive) reads THAT drive")
  t.eq(card.read("drive_1").score, 120, "read(drive) carries the score mirror")
  t.eq(card.read("drive_0").id, "alice", "read(drive) reads THAT drive")
end

-- ---- read(nil): the no-regression bar -- still the first drive with a disk ----
do
  reset()
  addDrive("drive_0", nil)         -- empty drive sorts FIRST but holds no card
  addDrive("drive_1", "/disk2"); putCard("/disk2", "bob", 120)
  t.eq(card.read().id, "bob", "read(nil) skips a diskless drive and finds the first CARD")
end

do
  reset()
  addDrive("drive_0", "/disk");  putCard("/disk", "alice", 500)
  addDrive("drive_1", "/disk2"); putCard("/disk2", "bob", 120)
  t.eq(card.read().id, "alice", "read(nil) is the FIRST drive with a disk -- unchanged behaviour")
end

do
  reset()
  t.eq(card.read(), nil, "no drives at all -> nil, not an error")
  addDrive("drive_0", nil)
  t.eq(card.read(), nil, "a drive with no disk -> nil")
  addDrive("drive_1", "/disk2")
  t.eq(card.read(), nil, "a disk with no card file -> nil (a blank floppy is not a card)")
end

do
  reset()
  addDrive("drive_0", "/disk")
  FILES["/disk/ccvegas_card"] = "this is not lua"
  t.eq(card.read(), nil, "an unreadable card -> nil, not a crash")
  FILES["/disk/ccvegas_card"] = "{score=5}"
  t.eq(card.read(), nil, "a card with no id is not a card")
end

do
  reset()
  addDrive("drive_0", "/disk"); putCard("/disk", "alice", 500)
  t.eq(card.read("drive_9"), nil, "read() of a drive that isn't attached -> nil, not a crash")
  DRIVES["monitor_0"] = { type = "monitor" }
  t.eq(card.read("monitor_0"), nil, "read() of a non-drive peripheral -> nil, not a crash")
end

-- ---- readAll(): only drives holding a card ----
do
  reset()
  addDrive("drive_0", "/disk");  putCard("/disk", "alice", 500)
  addDrive("drive_1", nil)                                  -- empty seat: skipped
  addDrive("drive_2", "/disk3"); putCard("/disk3", "bob", 120)
  local all = card.readAll()
  t.eq(#all, 2, "readAll() skips drives with no card")
  t.eq(all[1].drive, "drive_0", "readAll() carries the drive name")
  t.eq(all[1].id, "alice", "readAll() carries the id")
  t.eq(all[2].id, "bob", "readAll() is in drives() order")
  t.eq(all[2].drive, "drive_2", "readAll() carries the drive name")
end

do
  reset()
  t.eq(#card.readAll(), 0, "readAll() with no drives -> empty list")
end

-- ---- write / writeMirror are drive-addressable, and the id survives a mirror write ----
do
  reset()
  addDrive("drive_0", "/disk");  putCard("/disk", "alice", 500)
  addDrive("drive_1", "/disk2"); putCard("/disk2", "bob", 120)
  t.ok(card.writeMirror(640, "drive_1"), "writeMirror(score, drive) writes THAT drive")
  t.eq(card.read("drive_1").score, 640, "the mirror landed")
  t.eq(card.read("drive_1").id, "bob", "writeMirror preserves the id")
  t.eq(card.read("drive_0").score, 500, "and did NOT touch the other drive")

  t.ok(card.write("carol", 10, "drive_0"), "write(id, score, drive) writes THAT drive")
  t.eq(card.read("drive_0").id, "carol", "write landed on the addressed drive")
  t.eq(card.read("drive_1").id, "bob", "and did not touch the other drive")
end

do
  reset()
  addDrive("drive_0", "/disk"); putCard("/disk", "alice", 500)
  t.ok(card.writeMirror(700), "writeMirror(score) with no drive still means the first drive")
  t.eq(card.read().score, 700, "the no-arg mirror landed")

  reset()
  t.ok(not card.write("alice", 1), "write with no drive present -> false, not a crash")
  t.ok(not card.writeMirror(1), "writeMirror with no card -> false, not a crash")
end

t.done()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `luajit test/test_card.lua`
Expected: FAIL — `attempt to call field 'drives' (a nil value)`, because `card.drives` does not exist yet.

- [ ] **Step 3: Write the implementation**

Rewrite `src/lib/card.lua`:

```lua
-- card.lua — membership floppy read/write. A card = a mounted disk holding the file
-- /<mount>/ccvegas_card = serialize{ id=<string>, score=<number> }. No file => anonymous.
-- `score` is a display mirror only; the hub is authoritative (see wallet + hub).
--
-- Every read/write takes an OPTIONAL `drive` (a peripheral name). Omit it and you get the first
-- drive holding a disk -- exactly what this module did before multiplayer existed, which is what
-- lets slot/cage/issue keep calling read() and writeMirror() unchanged. Name a drive and you get
-- that one: a multi-seat station is N drives, and a seat must be able to read ITS card and no other.
local M = {}
local FILE = "ccvegas_card"

-- every disk drive attached, by peripheral name, SORTED.
--
-- Includes drives with NO disk: a drive is a SEAT, and an empty seat still exists -- filtering
-- them out here would make a cardless player disappear from the station rather than show up as an
-- anonymous seat. readAll() does the card filtering.
--
-- Sorted so seat order is stable across reboots FOR THIS STATION. It does NOT make names stable
-- across identically-built stations -- CC burns <type>_<n> indices on attach/detach, so the first
-- cage's droppers came up 1-4, not 0-3 ([[station-hardware-discovery]]). That is what the per-
-- station .cfg override exists for.
function M.drives()
  local out = {}
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "drive" then out[#out + 1] = name end
  end
  table.sort(out)
  return out
end

-- mount path of `drive`, or of the first drive holding a disk when `drive` is nil. nil if none.
local function mountPath(drive)
  if drive then
    if peripheral.getType(drive) ~= "drive" then return nil end
    local d = peripheral.wrap(drive)
    if not d or not d.isDiskPresent() then return nil end
    return d.getMountPath()
  end
  for _, name in ipairs(M.drives()) do
    local d = peripheral.wrap(name)
    if d and d.isDiskPresent() then
      local mp = d.getMountPath()
      if mp then return mp end
    end
  end
  return nil
end

-- read the card in `drive` (nil = the first drive with a disk).
-- Returns { id, score } or nil (no disk / blank / unreadable).
function M.read(drive)
  local mp = mountPath(drive); if not mp then return nil end
  local path = mp .. "/" .. FILE
  if not fs.exists(path) then return nil end
  local f = fs.open(path, "r"); if not f then return nil end
  local d = f.readAll(); f.close()
  local ok, t = pcall(textutils.unserialize, d)
  if ok and type(t) == "table" and type(t.id) == "string" then
    return { id = t.id, score = t.score }
  end
  return nil
end

-- every card on the station: { { drive, id, score }, ... } in drives() order.
-- Drives holding no readable card are omitted -- an empty seat has no card to report.
function M.readAll()
  local out = {}
  for _, name in ipairs(M.drives()) do
    local c = M.read(name)
    if c then out[#out + 1] = { drive = name, id = c.id, score = c.score } end
  end
  return out
end

-- write id + score to the card in `drive` (nil = first drive with a disk). true, or false,reason.
function M.write(id, score, drive)
  local mp = mountPath(drive); if not mp then return false, "no disk" end
  local f = fs.open(mp .. "/" .. FILE, "w")
  if not f then return false, "cannot open" end
  f.write(textutils.serialize({ id = id, score = score })); f.close()
  return true
end

-- update just the score mirror on `drive`'s card (id preserved). Best-effort.
function M.writeMirror(score, drive)
  local c = M.read(drive); if not c then return false, "no card" end
  return M.write(c.id, score, drive)
end

-- true for events that change disk state, so a play loop knows to re-read the card.
-- ev[2] is the drive's name/side -- a multi-seat station uses it to refresh only the seat that
-- actually changed (see card_session.onEvent).
function M.isCardEvent(ev)
  return type(ev) == "table" and (ev[1] == "disk" or ev[1] == "disk_eject")
end

return M
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `luajit test/test_card.lua`
Expected: PASS — `N passed, 0 failed`

Then the no-regression check — `sp_econ` stubs `card`, so this proves nothing about `card` itself, but it must stay green:

Run: `luajit test/test_sp_econ.lua`
Expected: PASS

- [ ] **Step 5: Syntax check**

Run: `luajit -bl src/lib/card.lua /dev/null`
Expected: no output (exit 0). On Windows/Git Bash use `luajit -bl src/lib/card.lua nul` if `/dev/null` errors.

- [ ] **Step 6: Commit**

```bash
git add src/lib/card.lua test/test_card.lua
git commit -m "feat(card): drives are addressable -- read(drive)/readAll(), the MP blocker

card.read() took the FIRST drive with a disk, which baked one-card-per-station
into every gateway above it. `drive` is now an optional last argument that
defaults to exactly the old behaviour, so slot/cage/issue are untouched.

drives() deliberately returns EVERY drive, disk or not: a drive is a seat, and
an empty seat still exists.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: `card_session.lua` — the extraction

**Files:**
- Create: `src/lib/card_session.lua`
- Test: `test/test_card_session.lua` (create)

**Interfaces:**
- Consumes: `card.read(drive)`, `card.writeMirror(score, drive)`, `card.isCardEvent(ev)` (Task 1); `wallet.query(id) -> balance, reason`, `wallet.flush()`.
- Produces: `card_session.new{ drive=string|nil, flush=boolean|nil } -> session` where session has fields `player`, `balance`, `offline`, `drive` and methods `refresh()`, `onEvent(ev)`, `isCardEvent(ev)`, `noteHub(reason)`, `setBalance(b)`, `status() -> {player, balance, offline}`.

**Context:** `sp_econ` and `cage_econ` are instances 1 and 2 of the same machinery (`cage_econ.lua:6-8` says exactly this); `mp_econ` is the third. **A session is one card on one drive** — that framing is what makes the extraction and the MP blocker the same work.

**Two things this task must get right:**

1. **The drift.** `sp_econ` has an `offline` flag (hub-unreachable ≠ broke); `cage_econ` folds both into one `msg` string. `sp_econ` is correct — it exists because telling a player holding $500 they are `INSUFFICIENT` is a lie the machine tells about money. **The session carries `offline`. Do not copy the drift forward.**
2. **`onEvent` filters by drive.** A `disk` event carries the drive's name in `ev[2]`. Without the filter, one card insert at a 4-seat station fires **four** `wallet.query` round-trips, three of them re-reading cards that did not change.

- [ ] **Step 1: Write the failing test**

Create `test/test_card_session.lua`:

```lua
-- test_card_session.lua — one card on one drive: the session machinery sp_econ and cage_econ
-- both grew independently, extracted when mp_econ made it three.
package.path = "src/lib/?.lua;test/?.lua;" .. package.path
local t = require("runner")

-- ---- stub the two modules card_session composes ---------------------------
local stubCard = { _disks = {}, _mirrors = {}, _reads = 0 }
function stubCard.read(drive)
  stubCard._reads = stubCard._reads + 1
  return stubCard._disks[drive or "_first"]
end
function stubCard.writeMirror(score, drive) stubCard._mirrors[drive or "_first"] = score end
function stubCard.isCardEvent(ev) return ev[1] == "disk" or ev[1] == "disk_eject" end

local stubWallet = { _query = {}, _flushes = 0, _queries = 0 }
function stubWallet.flush() stubWallet._flushes = stubWallet._flushes + 1 end
function stubWallet.query(id)
  stubWallet._queries = stubWallet._queries + 1
  return stubWallet._query.balance, stubWallet._query.reason
end

package.loaded["card"]   = stubCard
package.loaded["wallet"] = stubWallet
local cs = require("card_session")

local function reset()
  stubCard._disks, stubCard._mirrors, stubCard._reads = {}, {}, 0
  stubWallet._query, stubWallet._flushes, stubWallet._queries = {}, 0, 0
end

-- ---- a bound session reads ITS drive ----
do
  reset()
  stubCard._disks["drive_0"] = { id = "alice", score = 500 }
  stubCard._disks["drive_1"] = { id = "bob",   score = 120 }
  stubWallet._query = { balance = 640 }
  local s = cs.new{ drive = "drive_1" }
  t.eq(s.player, "bob", "a session bound to a drive reads THAT card")
  t.eq(s.balance, 640, "hub balance wins over the card mirror")
  t.eq(stubCard._mirrors["drive_1"], 640, "and the mirror is written back to THAT drive")
end

-- ---- an unbound session is the old single-card behaviour ----
do
  reset()
  stubCard._disks["_first"] = { id = "alice", score = 500 }
  stubWallet._query = { balance = 500 }
  local s = cs.new{}
  t.eq(s.player, "alice", "drive=nil -> the first drive, exactly as before")
end

-- ---- hub offline: fall back to the mirror, and SAY it is offline ----
do
  reset()
  stubCard._disks["_first"] = { id = "alice", score = 500 }
  stubWallet._query = { balance = nil, reason = "timeout" }
  local s = cs.new{}
  t.ok(s.offline, "card in + hub timeout -> offline")
  t.eq(s.balance, 500, "offline falls back to the card's score mirror")
  t.eq(stubCard._mirrors["_first"], nil, "and does NOT write a mirror it never got from the hub")
end

-- ---- no card is anonymous free play, NOT a hub error ----
do
  reset()
  stubWallet._query = { balance = nil, reason = "timeout" }
  local s = cs.new{}
  t.eq(s.player, nil, "no card -> anonymous")
  t.ok(not s.offline, "no card -> not offline: nobody asked the hub anything")
  t.eq(stubWallet._queries, 0, "and no card means no pointless hub round-trip")
end

-- ---- onEvent: only MY drive's events (the N-round-trips bug) ----
do
  reset()
  stubCard._disks["drive_1"] = { id = "bob", score = 120 }
  stubWallet._query = { balance = 120 }
  local s = cs.new{ drive = "drive_1" }
  local before = stubWallet._queries

  s.onEvent({ "disk", "drive_0" })
  t.eq(stubWallet._queries, before, "another seat's disk event does NOT re-query my card")

  stubCard._disks["drive_1"] = { id = "carol", score = 9 }
  s.onEvent({ "disk", "drive_1" })
  t.eq(s.player, "carol", "MY drive's disk event refreshes me")

  s.onEvent({ "timer", 1 })
  t.eq(s.player, "carol", "a non-card event changes nothing")
end

-- ---- an UNBOUND session refreshes on any drive's event (it has no drive of its own) ----
do
  reset()
  stubCard._disks["_first"] = { id = "alice", score = 500 }
  stubWallet._query = { balance = 500 }
  local s = cs.new{}
  stubCard._disks["_first"] = nil
  s.onEvent({ "disk_eject", "left" })
  t.eq(s.player, nil, "drive=nil -> any card event refreshes; ejected -> anonymous")
end

-- ---- ejecting while offline clears offline ----
do
  reset()
  stubCard._disks["_first"] = { id = "alice", score = 500 }
  stubWallet._query = { balance = nil, reason = "timeout" }
  local s = cs.new{}
  t.ok(s.offline, "precondition: starts offline with a card in")
  stubCard._disks["_first"] = nil
  s.onEvent({ "disk_eject", "left" })
  t.ok(not s.offline, "card ejected while offline -> offline cleared")
end

-- ---- noteHub: the caller's hub calls decide offline too ----
do
  reset()
  stubCard._disks["_first"] = { id = "alice", score = 500 }
  stubWallet._query = { balance = 500 }
  local s = cs.new{}
  t.ok(not s.offline, "precondition: hub answered")
  s.noteHub("timeout")
  t.ok(s.offline, "noteHub('timeout') -> offline")
  s.noteHub("insufficient")
  t.ok(not s.offline, "an insufficient deny is NOT offline -- the hub answered")
  s.noteHub(nil)
  t.ok(not s.offline, "a clean call clears offline")
end

-- ---- setBalance: display + mirror in step ----
do
  reset()
  stubCard._disks["drive_1"] = { id = "bob", score = 120 }
  stubWallet._query = { balance = 120 }
  local s = cs.new{ drive = "drive_1" }
  s.setBalance(90)
  t.eq(s.balance, 90, "setBalance updates the displayed balance")
  t.eq(stubCard._mirrors["drive_1"], 90, "setBalance writes the mirror to MY drive")
end

-- ---- flush: once per station, not once per seat ----
do
  reset()
  local s = cs.new{}
  t.eq(stubWallet._flushes, 1, "a session flushes the outbox on entry by default")

  reset()
  local a = cs.new{ drive = "drive_0", flush = false }
  local b = cs.new{ drive = "drive_1", flush = false }
  t.eq(stubWallet._flushes, 0, "flush=false suppresses it -- mp_econ flushes ONCE for the station")
end

-- ---- status() ----
do
  reset()
  stubCard._disks["_first"] = { id = "alice", score = 500 }
  stubWallet._query = { balance = 640 }
  local st = cs.new{}.status()
  t.eq(st.player, "alice", "status carries the player")
  t.eq(st.balance, 640, "status carries the balance")
  t.ok(not st.offline, "status carries offline")
end

t.done()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `luajit test/test_card_session.lua`
Expected: FAIL — `module 'card_session' not found`

- [ ] **Step 3: Write the implementation**

Create `src/lib/card_session.lua`:

```lua
-- card_session.lua — ONE card on ONE drive.
--
-- sp_econ and cage_econ each grew their own copy of this: read the card, ask the hub for the truth,
-- fall back to the card's mirror when the hub is quiet, re-read on disk events, write the mirror
-- back. Two instances is a coincidence; mp_econ made it three, so it lives here now.
--
-- The framing that makes multiplayer cheap: a session is one card on one DRIVE. Bind it to nil and
-- it is the single-card behaviour slot and the cage have always had. Bind N of them to N named
-- drives and you have N seats. That is the whole trick -- mp_econ is N of these plus arithmetic.
local card   = require("card")
local wallet = require("wallet")

local M = {}

-- cfg.drive = a drive's peripheral name, or nil = the first drive holding a disk.
-- cfg.flush = false to skip the entry outbox flush.
--   A multi-seat station must flush ONCE, not once per seat: N seats would be N rednet round-trips
--   at boot, and with the hub down that is N serialised LOOKUP_BACKOFF windows (wallet.lua) in the
--   boot path. mp_econ flushes for its seats and passes flush=false.
function M.new(cfg)
  cfg = cfg or {}
  local self = {
    drive   = cfg.drive,
    player  = nil,    -- id string, or nil (anonymous)
    balance = nil,    -- last known hub balance for player
    offline = false,  -- hub unreachable. NOT the same as broke, and the difference is the point:
                      -- telling a player holding $500 they are INSUFFICIENT is a lie about money.
  }

  if cfg.flush ~= false then wallet.flush() end

  -- record the outcome of a hub call the CALLER made. The gateways above (tryBet, tryDebit) make
  -- hub calls this session never sees, and they must render the result honestly -- so they hand the
  -- reason back here instead of each keeping a second, drifting copy of `offline`.
  function self.noteHub(reason)
    self.offline = (reason == "timeout")
  end

  -- read the card and reconcile with the hub. The hub is truth; the card's score is a mirror we
  -- fall back to only when the hub does not answer.
  function self.refresh()
    local c = card.read(self.drive)
    if c then
      self.player = c.id
      local b, reason = wallet.query(c.id)
      self.noteHub(reason)
      self.balance = b or c.score
      if b then card.writeMirror(b, self.drive) end
    else
      self.player, self.balance = nil, nil
      self.offline = false   -- no card is anonymous free play, not a hub error
    end
  end
  self.refresh()

  -- re-exported so a gateway can react to a card change without requiring `card` itself.
  -- sp_econ and cage_econ both need "was that a card event?" to clear their own denied/msg state.
  function self.isCardEvent(ev) return card.isCardEvent(ev) end

  -- fold a raw os event into state. Call for EVERY event in the play loop.
  function self.onEvent(ev)
    if not card.isCardEvent(ev) then return end
    -- ev[2] is the drive that changed. A bound seat ignores the others: without this, one insert at
    -- a 4-seat station fires FOUR wallet.query round-trips, three of them re-reading a card that
    -- did not change. An unbound session has no drive of its own, so any card event may be its own.
    if self.drive and ev[2] ~= self.drive then return end
    self.refresh()
  end

  -- keep the displayed balance and the card mirror in step after a hub write the CALLER made.
  function self.setBalance(b)
    self.balance = b
    card.writeMirror(b, self.drive)
  end

  function self.status()
    return { player = self.player, balance = self.balance, offline = self.offline }
  end

  return self
end

return M
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `luajit test/test_card_session.lua`
Expected: PASS — `N passed, 0 failed`

- [ ] **Step 5: Syntax check**

Run: `luajit -bl src/lib/card_session.lua /dev/null`
Expected: no output (exit 0).

- [ ] **Step 6: Commit**

```bash
git add src/lib/card_session.lua test/test_card_session.lua
git commit -m "feat(card_session): extract the session -- one card on ONE drive

sp_econ and cage_econ each grew their own copy of this machinery; mp_econ is
the third instance, so it lives in one place now.

The session carries `offline`, which is sp_econ's flag, NOT cage_econ's
msg-string conflation -- hub-unreachable is not the same as broke and the
gateways must not drift apart on that again. onEvent filters by drive: without
it, one insert at a 4-seat station is four wallet.query round-trips.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: `sp_econ` on `card_session` — the no-regression task

**Files:**
- Modify: `src/lib/sp_econ.lua`
- Test: `test/test_sp_econ.lua` (modify — the stubs change, the assertions must not)

**Interfaces:**
- Consumes: `card_session.new{drive, flush}` (Task 2).
- Produces: `sp_econ.new(cfg)` — **unchanged public API**: `tryBet(stake)`, `settle(result)`, `onEvent(ev)`, `status()`, `sp_econ.drawHeader(mon, s)`.

**Context:** The slot is **shipped and in-world verified**. This task must not change one byte of its behaviour — it swaps the private card machinery for the shared session and nothing else. `status()` must keep returning the same shape (`slot.lua` renders it).

**The one subtlety:** `sp_econ.offline` was a field on `self` written from two places (`refreshCard` and `tryBet`). It now lives on the session, and `tryBet` sets it via `session.noteHub(reason)`. `status()` reads it from the session. The existing test file's assertions are the specification — **do not weaken a single one**; only the stubs move (from stubbing `card`+`wallet` to stubbing `card_session`... no — keep stubbing `card` and `wallet`, so the real `card_session` is exercised end-to-end through `sp_econ`).

- [ ] **Step 1: Update the test's stubs, keep every assertion**

In `test/test_sp_econ.lua`, `sp_econ` now pulls in the real `card_session`, which itself requires `card` and `wallet` — both already stubbed. So the **only** change needed is that `stubCard.read` and `stubCard.writeMirror` now take a `drive` argument (which the stub ignores), and `stubWallet.query` is already returning `balance, reason`.

Replace the stub block at the top of `test/test_sp_econ.lua`:

```lua
-- ---- stub the CORE modules sp_econ composes (via the real card_session) ----
-- card_session is NOT stubbed: sp_econ's whole job is now to drive it correctly, so it is
-- exercised for real here and the assertions below are unchanged from before the extraction.
local stubCard = { _disk = nil }
function stubCard.read(drive) return stubCard._disk end
function stubCard.writeMirror(b, drive) stubCard._mirror = b end
function stubCard.isCardEvent(ev) return ev[1] == "disk" or ev[1] == "disk_eject" end

local stubWallet = { _query = {}, _bet = {} }
function stubWallet.flush() end
function stubWallet.query(id) return stubWallet._query.balance, stubWallet._query.reason end
function stubWallet.bet(id, st) return stubWallet._bet.ok, stubWallet._bet.balance, stubWallet._bet.reason end
function stubWallet.credit(id, d) return true, 0 end

package.loaded["card"]   = stubCard
package.loaded["wallet"] = stubWallet
local sp = require("sp_econ")
```

Every `do ... end` test block below it stays **exactly as-is**. Do not touch them.

- [ ] **Step 2: Run to verify it still passes BEFORE the refactor**

Run: `luajit test/test_sp_econ.lua`
Expected: PASS — this is the baseline. If it fails now, the stub edit is wrong; fix it before touching `sp_econ.lua`.

- [ ] **Step 3: Refactor `sp_econ.lua` onto the session**

Modify `src/lib/sp_econ.lua`. Replace the header comment, the `require` block, the state table, and `refreshCard`:

```lua
-- sp_econ.lua — single-player economy gateway. Composes a card_session + wallet into the bet-gate,
-- settle/credit and card lifecycle a game drives from its play() loop. Owns economy STATE; the game
-- renders it (status()). Reuses the modem idle_runner already opened; never opens rednet itself.
--
-- The card session (read/query/mirror/refresh-on-disk-event) used to live here in full. It is now
-- lib/card_session, shared with cage_econ and mp_econ. What stays here is the SHAPE that is
-- single-player-specific: a wager round with a house paytable. mp_econ sits beside this on the same
-- session+wallet core, not on top of it -- a pot is a different shape, not a bigger bet.
local card_session = require("card_session")
local wallet       = require("wallet")

local M = {}

-- cfg.pay = { STAKE = <int>, eval = function(result, stake) -> payout:int }
-- cfg.drive = which drive holds the card (nil = the first one; single-card stations want nil).
-- cfg.zone is accepted for symmetry with the station's zone (unused today).
function M.new(cfg)
  local sess = card_session.new{ drive = cfg.drive }   -- flushes the outbox on entry

  local self = {
    pay      = cfg.pay,
    session  = sess,
    lastWin  = 0,
    denied   = false,
    round    = nil,   -- "staked" | "free" | nil : current round's bet outcome
    stakedId = nil,   -- id that was debited this round; settle credits THIS, not the live card
    stakedStake = nil,   -- stake debited this round; settle evals payout against THIS
  }

  -- fold a raw os event into state. Call for EVERY event in the play loop.
  -- `denied` clears on a CARD event only -- that is exactly what the old refreshCard did. Clearing
  -- it on every event instead would wipe the INSUFFICIENT header one frame after it appeared.
  -- sess.isCardEvent is the session's re-export (Task 2), so this file needs no `card` dependency.
  function self.onEvent(ev)
    if sess.isCardEvent(ev) then self.denied = false end
    sess.onEvent(ev)
  end
```

Then the rest of `sp_econ.lua` — `tryBet`, `settle`, `status`, `drawHeader` — becomes:

```lua
  -- called on the arm edge. "staked" = stake debited, run the round for real;
  -- "free" = anonymous, run the round but it pays nothing; "deny" = insufficient/offline, do NOT run.
  function self.tryBet(stake)
    self.denied = false
    if not sess.player then self.round = "free"; return "free" end
    local st = stake or self.pay.STAKE
    local ok, bal, reason = wallet.bet(sess.player, st)
    if ok then
      sess.noteHub(nil)
      sess.setBalance(bal)
      self.round = "staked"; self.stakedId = sess.player; self.stakedStake = st
      return "staked"
    end
    if bal ~= nil then sess.balance = bal end   -- deny reply carries current balance
    -- A hub timeout and a real insufficient-funds deny BOTH fail closed -- that does not change.
    -- But they are not the same thing, and telling a player with $500 that they are INSUFFICIENT is
    -- a lie the machine tells about money. Keep them apart for the header.
    sess.noteHub(reason)
    self.denied = not sess.offline
    self.round = nil
    return "deny"
  end

  -- called at round resolution. Credits a win for a staked round; returns the payout paid (0 else).
  function self.settle(result)
    local won = 0
    if self.round == "staked" then
      local payout = self.pay.eval(result, self.stakedStake)
      if payout > 0 then
        local ok, bal = wallet.credit(self.stakedId, payout)
        if ok and bal then
          -- credit the STAKED id, but only move the display if that id is still the card on screen
          if self.stakedId == sess.player then sess.setBalance(bal) else sess.balance = bal end
        else
          sess.balance = (sess.balance or 0) + payout   -- queued to outbox; reflect locally
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
      player  = sess.player,
      balance = sess.balance,
      stake   = self.pay.STAKE,
      lastWin = self.lastWin,
      denied  = self.denied,
      offline = sess.offline,
    }
  end

  return self
end
```

`M.drawHeader(mon, s)` at the bottom of the file is **unchanged** — do not touch it.

- [ ] **Step 4: Run the tests**

Run: `luajit test/test_sp_econ.lua`
Expected: PASS — same count as the Step 2 baseline, `0 failed`. **Any assertion that now fails is a real regression in a shipped, in-world-verified station.** Do not edit the assertion to match the code; fix the code.

Run: `luajit test/test_card_session.lua`
Expected: PASS (the `isCardEvent` re-export must not break it).

- [ ] **Step 5: Check `slot.lua` still matches the API**

Run: `grep -n "econ\." src/slot/slot.lua`
Expected: every call is one of `tryBet`, `settle`, `onEvent`, `status`. If `slot.lua` reaches into `econ.player` / `econ.balance` / `econ.offline` directly (fields that moved onto the session), **fix `slot.lua` to use `status()`** and say so in the commit.

Run: `luajit -bl src/lib/sp_econ.lua /dev/null && luajit -bl src/slot/slot.lua /dev/null`
Expected: no output (exit 0).

- [ ] **Step 6: Commit**

```bash
git add src/lib/sp_econ.lua src/lib/card_session.lua test/test_sp_econ.lua
git commit -m "refactor(sp_econ): drive the shared card_session, behaviour unchanged

The slot is shipped and in-world verified, so this swaps the private card
machinery for the extracted session and changes nothing else. Every assertion
in test_sp_econ is unchanged -- they were the spec for this refactor, and
card_session is exercised for real underneath rather than stubbed.

offline now lives on the session; tryBet reports its own hub call via
noteHub() instead of keeping a second copy of the flag.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: `cage_econ` on `card_session` — and the drift dies

**Files:**
- Modify: `src/lib/cage_econ.lua`
- Test: `test/test_cage_econ.lua` (create — `cage_econ` has no tests today)

**Interfaces:**
- Consumes: `card_session.new{drive, flush}`, `session.noteHub(reason)`, `session.setBalance(b)` (Task 2).
- Produces: `cage_econ.new(cfg)` — **unchanged public API**: `tryDebit(amount)`, `deposit(amount)`, `refund(amount)`, `onEvent(ev)`, `status() -> {player, balance, denied, msg}`. **`status()` gains `offline`.**

**Context:** The cage is **shipped and in-world verified**. Same bar as Task 3: the card machinery is swapped out, nothing else moves — **except** the drift the spec calls out.

**The drift, precisely.** `cage_econ.tryDebit` does:

```lua
self.msg = (reason == "timeout") and "HUB OFFLINE" or ("NEED $" .. amount)
```

So a `debit_deny{reason="unknown"}` — a card whose ledger id was deleted — renders **`NEED $100`** at a player who is not broke and whose card is simply dead. That is the same lie-class as the `INSUFFICIENT` bug the freeze-fix branch killed one module over, and it is filed in `todo.md` under the cage's follow-ups. Adopting the session's `offline` makes it a three-line fix, so **close it here**.

- [ ] **Step 1: Write the failing test**

Create `test/test_cage_econ.lua`:

```lua
-- test_cage_econ.lua — the cage's gateway on the shared card_session.
--
-- Two jobs: pin the shipped behaviour through the extraction (the cage is in-world verified), and
-- kill the drift -- cage_econ folded hub-unreachable and insufficient-funds into one msg string, so
-- a card whose ledger id was deleted rendered "NEED $100" at a player who was not broke.
package.path = "src/lib/?.lua;test/?.lua;" .. package.path
local t = require("runner")

local stubCard = { _disk = nil, _mirror = nil }
function stubCard.read(drive) return stubCard._disk end
function stubCard.writeMirror(b, drive) stubCard._mirror = b end
function stubCard.isCardEvent(ev) return ev[1] == "disk" or ev[1] == "disk_eject" end

local stubWallet = { _query = {}, _debit = {}, _credit = {} }
function stubWallet.flush() end
function stubWallet.query(id) return stubWallet._query.balance, stubWallet._query.reason end
function stubWallet.debit(id, amt)
  stubWallet._lastDebit = { id = id, amount = amt }
  return stubWallet._debit.ok, stubWallet._debit.balance, stubWallet._debit.reason
end
function stubWallet.credit(id, d)
  stubWallet._lastCredit = { id = id, delta = d }
  return stubWallet._credit.ok, stubWallet._credit.balance, stubWallet._credit.reason
end

package.loaded["card"]   = stubCard
package.loaded["wallet"] = stubWallet
local ce = require("cage_econ")

local function reset()
  stubCard._disk, stubCard._mirror = nil, nil
  stubWallet._query, stubWallet._debit, stubWallet._credit = {}, {}, {}
  stubWallet._lastDebit, stubWallet._lastCredit = nil, nil
end

-- ---- no card: buttons inert, never a gate ----
do
  reset()
  local e = ce.new{}
  t.eq(e.tryDebit(100), "nocard", "no card -> nocard")
  t.eq(e.status().msg, "INSERT CARD", "and it says so")
  t.eq(stubWallet._lastDebit, nil, "and nothing was debited")
end

-- ---- a funded debit ----
do
  reset()
  stubCard._disk = { id = "alice", score = 500 }
  stubWallet._query = { balance = 500 }
  local e = ce.new{}
  stubWallet._debit = { ok = true, balance = 400 }
  t.eq(e.tryDebit(100), "ok", "a funded debit succeeds")
  t.eq(e.status().balance, 400, "balance updates")
  t.eq(stubCard._mirror, 400, "and the card mirror is written")
end

-- ---- insufficient: the honest message ----
do
  reset()
  stubCard._disk = { id = "alice", score = 50 }
  stubWallet._query = { balance = 50 }
  local e = ce.new{}
  stubWallet._debit = { ok = false, balance = 50, reason = "insufficient" }
  t.eq(e.tryDebit(100), "deny", "insufficient fails closed")
  t.eq(e.status().msg, "NEED $100", "insufficient says what you need")
  t.ok(e.status().denied, "and is denied")
  t.ok(not e.status().offline, "insufficient is NOT offline -- the hub answered")
end

-- ---- hub down ----
do
  reset()
  stubCard._disk = { id = "alice", score = 500 }
  stubWallet._query = { balance = 500 }
  local e = ce.new{}
  stubWallet._debit = { ok = false, balance = nil, reason = "timeout" }
  t.eq(e.tryDebit(100), "deny", "a hub timeout fails closed -- no metal moves")
  t.eq(e.status().msg, "HUB OFFLINE", "and says the hub is offline")
  t.ok(e.status().offline, "offline flag is set")
end

-- ---- THE DRIFT: a dead card id must not read as "you are broke" ----
do
  reset()
  stubCard._disk = { id = "ghost", score = 500 }
  stubWallet._query = { balance = 500 }
  local e = ce.new{}
  stubWallet._debit = { ok = false, balance = nil, reason = "unknown" }
  t.eq(e.tryDebit(100), "deny", "a dead card id fails closed")
  t.eq(e.status().msg, "BAD CARD", "a deleted ledger id says BAD CARD, NOT 'NEED $100'")
  t.ok(not e.status().offline, "and it is not offline -- the hub answered")
end

-- ---- deposit ----
do
  reset()
  stubCard._disk = { id = "alice", score = 500 }
  stubWallet._query = { balance = 500 }
  local e = ce.new{}
  stubWallet._credit = { ok = true, balance = 600 }
  t.eq(e.deposit(100), 600, "a deposit credits and returns the new balance")
  t.eq(stubCard._mirror, 600, "and mirrors it")
end

do
  reset()
  stubCard._disk = { id = "ghost", score = 500 }
  stubWallet._query = { balance = 500 }
  local e = ce.new{}
  stubWallet._credit = { ok = false, balance = nil, reason = "unknown" }
  t.eq(e.deposit(100), nil, "a deposit to a dead id is refused")
  t.eq(e.status().msg, "BAD CARD", "and says BAD CARD")
end

do
  reset()
  stubCard._disk = { id = "alice", score = 500 }
  stubWallet._query = { balance = 500 }
  local e = ce.new{}
  stubWallet._credit = { ok = false, balance = nil, reason = "queued" }
  t.eq(e.deposit(100), 600, "a hub-down deposit is outboxed and reflected locally -- never lost")
  t.eq(e.status().msg, "HUB OFFLINE", "and says so")
end

-- ---- refund follows the DEBITED id, not the live card ----
do
  reset()
  stubCard._disk = { id = "alice", score = 500 }
  stubWallet._query = { balance = 500 }
  local e = ce.new{}
  stubWallet._debit = { ok = true, balance = 400 }
  t.eq(e.tryDebit(100), "ok", "precondition: alice paid")

  stubCard._disk = { id = "bob", score = 20 }     -- alice ejected mid-shower, bob inserted
  stubWallet._query = { balance = 20 }
  e.onEvent({ "disk", "left" })
  t.eq(e.status().player, "bob", "precondition: bob's card is in the drive now")

  stubWallet._credit = { ok = true, balance = 450 }
  e.refund(50)
  t.eq(stubWallet._lastCredit.id, "alice", "the refund goes to whoever PAID, not the live card")
  t.eq(e.status().balance, 20, "and bob's displayed balance is untouched")
end

t.done()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `luajit test/test_cage_econ.lua`
Expected: FAIL — the `BAD CARD` assertions fail with `actual: NEED $100` (that is the drift, reproduced), and `status().offline` is `nil`.

- [ ] **Step 3: Refactor `cage_econ.lua`**

Modify `src/lib/cage_econ.lua`. Replace the requires, state and `refreshCard` with the session; keep `tryDebit`/`deposit`/`refund` shapes:

```lua
-- cage_econ.lua — the cage's economy gateway: a card session plus hub debit/credit, driven from
-- the station's play() loop. Sibling of sp_econ, on the same card_session+wallet core.
--
-- Why not sp_econ? That gateway is bet/settle-shaped (a wager round with a paytable). The cage has
-- no round, no result and no house evaluation — it debits and it credits. Both need the same card
-- SESSION, so they share that (lib/card_session), not each other.
--
-- Reuses the modem idle_runner already opened; never opens rednet itself.
local card_session = require("card_session")
local wallet       = require("wallet")

local M = {}

-- cfg.drive = which drive holds the card (nil = the first one).
-- cfg.zone is accepted for symmetry with the station's zone (unused today).
function M.new(cfg)
  cfg = cfg or {}
  local sess = card_session.new{ drive = cfg.drive }   -- flushes the outbox on entry

  local self = {
    session = sess,
    denied  = false,
    msg     = nil,   -- status line for the UI
    debitedId = nil, -- id the last successful tryDebit charged; refund() credits THIS, not the
                     -- live card. The player can eject mid-shower — the money owed goes back to
                     -- whoever paid it. (sp_econ's stakedId lesson, kb/economy.md.)
  }

  -- fold a raw os event into state. Call for EVERY event in the play loop.
  function self.onEvent(ev)
    if sess.isCardEvent(ev) then self.denied, self.msg = false, nil end
    sess.onEvent(ev)
  end

  -- Take `amount` off the card. Fail-closed: anything but "ok" means NO items may move.
  -- The caller must have already confirmed vault stock — ordering invariant is
  -- stock check -> debit -> move.
  function self.tryDebit(amount)
    self.denied, self.msg = false, nil
    if not sess.player then self.msg = "INSERT CARD"; return "nocard" end
    local ok, bal, reason = wallet.debit(sess.player, amount)
    if ok then
      sess.noteHub(nil)
      self.debitedId = sess.player     -- capture at commit: refund() must not follow the live card
      sess.setBalance(bal)
      return "ok"
    end
    if bal ~= nil then sess.balance = bal end   -- deny reply carries current balance
    sess.noteHub(reason)
    self.denied = true
    -- Three states, not two. A deleted ledger id is not a broke player, and saying "NEED $100" to
    -- someone holding a dead card is the same lie about money that `offline` exists to prevent.
    if sess.offline then
      self.msg = "HUB OFFLINE"
    elseif reason == "unknown" then
      self.msg = "BAD CARD"
    else
      self.msg = "NEED $" .. amount
    end
    return "deny"
  end

  -- Put `amount` on the card. Guaranteed: if the hub is down the credit is outboxed and the
  -- balance is reflected locally, so a deposit is never lost (wallet.credit's contract).
  function self.deposit(amount)
    self.denied, self.msg = false, nil
    if not sess.player then self.msg = "INSERT CARD"; return nil end
    local ok, bal, reason = wallet.credit(sess.player, amount)
    if ok and bal then
      sess.noteHub(nil)
      sess.setBalance(bal)
    elseif reason == "unknown" then          -- credit_deny: this card's id is gone from the ledger
      self.denied, self.msg = true, "BAD CARD"
      return nil
    else
      sess.noteHub("timeout")
      sess.balance = (sess.balance or 0) + amount   -- queued to outbox; reflect locally
      self.msg = "HUB OFFLINE"
    end
    return sess.balance
  end

  -- Give money back after a move came up short. Credits the id that was DEBITED, not whoever is in
  -- the drive now: the player may have ejected mid-shower, and a refund must never follow the card.
  -- Only touches the displayed balance / mirror when the debited id is still the one on screen.
  function self.refund(amount)
    if amount <= 0 or not self.debitedId then return end
    local ok, bal = wallet.credit(self.debitedId, amount)
    local live = (self.debitedId == sess.player)
    if ok and bal then
      if live then sess.setBalance(bal) end
    elseif live then
      sess.balance = (sess.balance or 0) + amount   -- outboxed; reflect locally
    end
    self.msg = "REFUNDED $" .. amount
  end

  function self.status()
    return {
      player  = sess.player,
      balance = sess.balance,
      denied  = self.denied,
      offline = sess.offline,
      msg     = self.msg,
    }
  end

  return self
end

return M
```

- [ ] **Step 4: Run the tests**

Run: `luajit test/test_cage_econ.lua`
Expected: PASS — including the two `BAD CARD` assertions that failed in Step 2.

- [ ] **Step 5: Check `cage.lua` still matches the API**

Run: `grep -n "econ\." src/cage/cage.lua`
Expected: only `tryDebit`, `deposit`, `refund`, `onEvent`, `status`. If it reaches into moved fields directly, fix `cage.lua` to use `status()` and say so in the commit.

Run: `luajit -bl src/lib/cage_econ.lua /dev/null && luajit -bl src/cage/cage.lua /dev/null`
Expected: no output (exit 0).

- [ ] **Step 6: Commit**

```bash
git add src/lib/cage_econ.lua test/test_cage_econ.lua
git commit -m "refactor(cage_econ): onto card_session, and kill the msg-string drift

The cage folded hub-unreachable and insufficient-funds into one msg string, so
a debit_deny{reason='unknown'} -- a card whose ledger id was deleted -- rendered
'NEED \$100' at a player who was not broke. Same lie-class the freeze fix killed
in sp_econ one module over; filed in todo.md under the cage follow-ups.

Adopting the session's `offline` makes it three states instead of two:
HUB OFFLINE / BAD CARD / NEED \$n. First tests cage_econ has ever had.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: `mp_econ.lua` — the pot engine

**Files:**
- Create: `src/lib/mp_econ.lua`
- Test: `test/test_mp_econ.lua` (create)

**Interfaces:**
- Consumes: `card.drives()` (Task 1); `card_session.new{drive, flush}` + `.player`, `.balance`, `.offline`, `.noteHub`, `.setBalance`, `.onEvent`, `.status` (Task 2); `wallet.debit(id, amt) -> ok, balance, reason`, `wallet.credit(id, delta) -> ok, balance, reason`, `wallet.flush()`.
- Produces: `mp_econ.new{drives, minSeats, maxSeats, ante} -> e` with `e.seats` (array), `e.phase`, `e.pot`, `e.onEvent(ev)`, `e.cardedCount() -> n`, `e.canStake() -> bool`, `e.start() -> "staked"|"free"|"deny", reason, seatIndex`, `e.finish(scores) -> {matchWinner, potWinner, potShare, pot}`, `e.status()`.

**Context:** This is the deliverable. Read the spec's `mp_econ` section before writing a line.

**The three rules that carry the money:**

1. **The ante is all-or-nothing.** A partial pot means somebody is about to win money that was never all there. Any debit failure refunds every ante already taken. (`kb/economy.md` lesson 6's ordering invariant, with "the pot is complete" as the stock check.)
2. **Pay `antedId`, never `session.player`.** The drive may be empty or hold a stranger by payout time. (`kb/economy.md` lesson 2, generalised to N seats.)
3. **Refunds and payouts use `wallet.credit`, never `creditNow`** — on a hub timeout the money outboxes and is flushed later. The player is owed it.

- [ ] **Step 1: Write the failing test**

Create `test/test_mp_econ.lua`:

```lua
-- test_mp_econ.lua — the pot engine: N seats, N cards, ante -> pot -> payout.
--
-- The money rules under test, in order of how much they would cost to get wrong:
--   1. the ante is ALL-OR-NOTHING (a partial pot pays out money that was never all there)
--   2. the payout follows the ANTED id, never the live card (pull yours mid-match, still get paid)
--   3. an anonymous seat can win the MATCH but never the POT (it never paid in)
package.path = "src/lib/?.lua;test/?.lua;" .. package.path
local t = require("runner")

-- ---- stubs -----------------------------------------------------------------
local stubCard = { _disks = {}, _mirrors = {}, _drives = {} }
function stubCard.drives() return stubCard._drives end
function stubCard.read(drive) return stubCard._disks[drive] end
function stubCard.writeMirror(b, drive) stubCard._mirrors[drive] = b end
function stubCard.isCardEvent(ev) return ev[1] == "disk" or ev[1] == "disk_eject" end

local stubWallet = { _balances = {}, _debit = {}, _credit = {}, _flushes = 0 }
function stubWallet.flush() stubWallet._flushes = stubWallet._flushes + 1 end
function stubWallet.query(id) return stubWallet._balances[id], nil end

-- per-id scripted debit outcomes: _debit[id] = { ok=, balance=, reason= }; default ok.
function stubWallet.debit(id, amt)
  local r = stubWallet._debit[id] or { ok = true, balance = (stubWallet._balances[id] or 0) - amt }
  stubWallet._calls[#stubWallet._calls + 1] = { op = "debit", id = id, amount = amt }
  return r.ok, r.balance, r.reason
end
function stubWallet.credit(id, delta)
  local r = stubWallet._credit[id] or { ok = true, balance = (stubWallet._balances[id] or 0) + delta }
  stubWallet._calls[#stubWallet._calls + 1] = { op = "credit", id = id, delta = delta }
  return r.ok, r.balance, r.reason
end

package.loaded["card"]   = stubCard
package.loaded["wallet"] = stubWallet
local mp = require("mp_econ")

local function reset()
  stubCard._disks, stubCard._mirrors, stubCard._drives = {}, {}, {}
  stubWallet._balances, stubWallet._debit, stubWallet._credit = {}, {}, {}
  stubWallet._calls, stubWallet._flushes = {}, 0
end

-- seat the given cards on drive_0..drive_(n-1). `nil` in the list = an empty drive (anon seat).
local function seat(cards)
  for i, c in ipairs(cards) do
    local d = "drive_" .. (i - 1)
    stubCard._drives[i] = d
    if c ~= "anon" then
      stubCard._disks[d] = { id = c, score = 500 }
      stubWallet._balances[c] = 500
    end
  end
end

local function creditsTo(id)
  local total = 0
  for _, c in ipairs(stubWallet._calls) do
    if c.op == "credit" and c.id == id then total = total + c.delta end
  end
  return total
end

-- ---- seats come from the drives, cards or not ----
do
  reset(); seat{ "alice", "anon" }
  local e = mp.new{ ante = 10 }
  t.eq(#e.seats, 2, "a drive is a seat, disk or not -- an empty seat is an anonymous player")
  t.eq(e.seats[1].session.player, "alice", "seat 1 reads drive_0")
  t.eq(e.seats[2].session.player, nil, "seat 2 is anonymous")
  t.eq(e.cardedCount(), 1, "cardedCount counts readable cards")
  t.eq(e.phase, "lobby", "starts in the lobby")
end

do
  reset(); seat{ "a", "b", "c", "d", "e" }
  local e = mp.new{ ante = 10, maxSeats = 4 }
  t.eq(#e.seats, 4, "maxSeats caps the seats created from drives")
end

do
  reset(); seat{ "alice", "bob" }
  local e = mp.new{ ante = 10, drives = { "drive_1", "drive_0" } }
  t.eq(e.seats[1].session.player, "bob", "cfg drives= overrides discovery AND sets seat order")
end

-- ---- the station flushes ONCE, not once per seat ----
do
  reset(); seat{ "alice", "bob", "carol", "dave" }
  mp.new{ ante = 10 }
  t.eq(stubWallet._flushes, 1, "4 seats flush the outbox ONCE, not four times")
end

-- ---- staked needs >= minSeats CARDED seats ----
do
  reset(); seat{ "alice", "anon" }
  local e = mp.new{ ante = 10 }
  t.ok(not e.canStake(), "1 carded seat cannot make a pot")
  t.eq(e.start(), "free", "1 carded seat -> a FREE match (it would ante and win its own ante back)")
  t.eq(e.pot, 0, "no pot")
  t.eq(#stubWallet._calls, 0, "and NOBODY is debited")
  t.eq(e.phase, "playing", "a free match still starts")
end

do
  reset(); seat{ "anon", "anon" }
  local e = mp.new{ ante = 10 }
  t.eq(e.start(), "free", "0 carded seats -> free (today's pong)")
  t.eq(#stubWallet._calls, 0, "nobody is debited")
end

-- ---- the happy path ----
do
  reset(); seat{ "alice", "bob" }
  local e = mp.new{ ante = 10 }
  t.ok(e.canStake(), "2 carded seats can stake")
  t.eq(e.start(), "staked", "2 carded seats -> staked")
  t.eq(e.pot, 20, "pot = ante * carded seats")
  t.eq(e.phase, "playing", "phase moves to playing")
  t.eq(e.seats[1].antedId, "alice", "seat 1 locked to the id that paid")
  t.eq(e.seats[2].antedId, "bob", "seat 2 locked to the id that paid")
  t.eq(e.seats[1].session.balance, 490, "and the balance reflects the debit")
  t.eq(stubCard._mirrors["drive_0"], 490, "and the card mirror is written")
end

-- ---- THE ALL-OR-NOTHING ANTE: seat 2 broke -> seat 1 refunded ----
do
  reset(); seat{ "alice", "bob" }
  stubWallet._debit["bob"] = { ok = false, balance = 5, reason = "insufficient" }
  local e = mp.new{ ante = 10 }
  local res, reason, seatIdx = e.start()
  t.eq(res, "deny", "one seat short denies the whole match")
  t.eq(reason, "insufficient", "and names the reason")
  t.eq(seatIdx, 2, "and names the seat")
  t.eq(creditsTo("alice"), 10, "ALICE IS REFUNDED IN FULL -- a partial pot is never left standing")
  t.eq(e.pot, 0, "no pot")
  t.eq(e.phase, "lobby", "back to the lobby")
  t.eq(e.seats[1].antedId, nil, "and seat 1 is unlocked")
end

do
  reset(); seat{ "alice", "bob", "carol" }
  stubWallet._debit["carol"] = { ok = false, balance = nil, reason = "timeout" }
  local e = mp.new{ ante = 10 }
  local res, reason, seatIdx = e.start()
  t.eq(res, "deny", "a hub timeout mid-ante denies the match")
  t.eq(reason, "timeout", "and reports the timeout")
  t.eq(seatIdx, 3, "at the seat that failed")
  t.eq(creditsTo("alice"), 10, "alice refunded")
  t.eq(creditsTo("bob"), 10, "bob refunded -- BOTH earlier seats, not just the last one")
  t.ok(e.seats[3].session.offline, "and the failing seat is marked offline, not broke")
end

-- ---- the payout ----
do
  reset(); seat{ "alice", "bob" }
  local e = mp.new{ ante = 10 }
  e.start()
  local r = e.finish{ [1] = 5, [2] = 3 }
  t.eq(r.matchWinner, 1, "highest score takes the match")
  t.eq(r.potWinner, 1, "and the pot")
  t.eq(r.pot, 20, "the pot was 20")
  t.eq(r.potShare[1], 20, "the winner is credited the whole pot")
  t.eq(creditsTo("alice"), 20, "alice got the money")
  t.eq(creditsTo("bob"), 0, "bob got nothing")
  t.eq(e.phase, "done", "match is done")
  t.eq(e.pot, 0, "and the pot is cleared")
end

-- ---- AN ANON CAN WIN THE MATCH BUT NOT THE POT ----
do
  reset(); seat{ "alice", "bob", "anon" }
  local e = mp.new{ ante = 10 }
  t.eq(e.start(), "staked", "2 carded + 1 anon is a staked match")
  t.eq(e.pot, 20, "the anon contributes nothing to the pot")
  local r = e.finish{ [1] = 3, [2] = 1, [3] = 9 }
  t.eq(r.matchWinner, 3, "the anon takes the MATCH -- glory is free")
  t.eq(r.potWinner, 1, "but the best CARDED seat takes the money")
  t.eq(creditsTo("alice"), 20, "alice gets the pot she paid into")
  t.eq(r.potShare[3], nil, "the anon is credited nothing")
end

-- ---- ties: split, remainder to the lowest seat, shares sum to the pot EXACTLY ----
do
  reset(); seat{ "alice", "bob" }
  local e = mp.new{ ante = 10 }
  e.start()
  local r = e.finish{ [1] = 4, [2] = 4 }
  t.eq(r.potShare[1] + r.potShare[2], 20, "an even tie splits the pot exactly")
  t.eq(r.potShare[1], 10, "10 each")
  t.eq(r.potShare[2], 10, "10 each")
end

do
  reset(); seat{ "alice", "bob", "carol" }
  local e = mp.new{ ante = 5 }
  e.start()                                     -- pot = 15
  local r = e.finish{ [1] = 4, [2] = 4, [3] = 4 }
  t.eq(r.potShare[1] + r.potShare[2] + r.potShare[3], 15, "a 3-way tie sums to the pot exactly")
end

do
  reset(); seat{ "alice", "bob", "carol" }
  local e = mp.new{ ante = 10 }
  e.start()                                     -- pot = 30
  local r = e.finish{ [1] = 4, [2] = 4, [3] = 0 }
  t.eq(r.potShare[1], 15, "a 2-way tie of a 30 pot splits 15/15")
  t.eq(r.potShare[2], 15, "15")
  t.eq(r.potShare[3], nil, "the loser gets nothing")
end

do
  reset(); seat{ "alice", "bob" }
  local e = mp.new{ ante = 5 }
  e.start()                                     -- pot = 10... make it odd:
  e.pot = 11                                    -- force an odd pot to pin the remainder rule
  local r = e.finish{ [1] = 2, [2] = 2 }
  t.eq(r.potShare[1] + r.potShare[2], 11, "an ODD pot still sums exactly -- no $ evaporates")
  t.eq(r.potShare[1], 6, "the remainder goes to the LOWEST seat index")
  t.eq(r.potShare[2], 5, "the other tied seat gets the floor")
end

-- ---- THE HEADLINE: the payout follows the ANTED id, not the live card ----
do
  reset(); seat{ "alice", "bob" }
  local e = mp.new{ ante = 10 }
  e.start()
  stubCard._disks["drive_0"] = nil                 -- alice pulls her card mid-match
  e.onEvent({ "disk_eject", "drive_0" })
  t.eq(e.seats[1].session.player, nil, "precondition: seat 1's drive is empty now")
  t.eq(e.seats[1].antedId, "alice", "but the seat is still locked to the id that paid")
  local r = e.finish{ [1] = 5, [2] = 1 }
  t.eq(creditsTo("alice"), 20, "ALICE IS PAID even though her card is gone")
  t.eq(r.potWinner, 1, "her seat won")
end

do
  reset(); seat{ "alice", "bob" }
  local e = mp.new{ ante = 10 }
  e.start()
  stubCard._disks["drive_0"] = { id = "carol", score = 0 }   -- a STRANGER takes the seat
  stubWallet._balances["carol"] = 0
  e.onEvent({ "disk", "drive_0" })
  t.eq(e.seats[1].session.player, "carol", "precondition: carol's card is in seat 1's drive")
  t.eq(e.seats[1].antedId, "alice", "the seat is STILL alice's -- carol is a spectator")
  e.finish{ [1] = 5, [2] = 1 }
  t.eq(creditsTo("alice"), 20, "alice is paid")
  t.eq(creditsTo("carol"), 0, "the spectator gets NOTHING -- she never paid in")
end

-- ---- a free match pays nobody ----
do
  reset(); seat{ "alice", "anon" }
  local e = mp.new{ ante = 10 }
  e.start()                                     -- free: only 1 carded
  local r = e.finish{ [1] = 5, [2] = 1 }
  t.eq(r.pot, 0, "a free match has no pot")
  t.eq(r.matchWinner, 1, "but it still has a winner -- glory")
  t.eq(r.potWinner, nil, "nobody wins money")
  t.eq(#stubWallet._calls, 0, "and no hub write ever happened")
end

-- ---- a second match clears the seats ----
do
  reset(); seat{ "alice", "bob" }
  local e = mp.new{ ante = 10 }
  e.start()
  e.finish{ [1] = 5, [2] = 1 }
  t.eq(e.start(), "staked", "a new match can start after one finishes")
  t.eq(e.pot, 20, "with a fresh pot")
  t.eq(e.seats[1].antedId, "alice", "and freshly locked seats")
end

do
  reset(); seat{ "alice", "bob" }
  local e = mp.new{ ante = 10 }
  e.start()
  local res = e.start()
  t.eq(res, "deny", "GO during a live match is refused -- it must not double-ante")
  t.eq(e.pot, 20, "and the pot is untouched")
end

t.done()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `luajit test/test_mp_econ.lua`
Expected: FAIL — `module 'mp_econ' not found`

- [ ] **Step 3: Write the implementation**

Create `src/lib/mp_econ.lua`:

```lua
-- mp_econ.lua — the multiplayer economy gateway: N seats, N cards, ante -> pot -> payout.
--
-- Sibling of sp_econ (a wager round against a house paytable) and cage_econ (debit/credit at a
-- kiosk). This one is pot-shaped: every carded seat pays in, one seat takes the lot. All three sit
-- on the same card_session + wallet core, and none is built on another -- a pot is a different
-- shape, not a bigger bet.
--
-- A SEAT IS A DRIVE. That is the whole model: a drive is a physical place a player stands, and it
-- exists whether or not there is a card in it (an empty seat is an anonymous player). The card in
-- it is read by that seat's card_session and nobody else's.
--
-- The three money rules, in order of what they would cost to get wrong:
--   1. The ante is ALL-OR-NOTHING. A partial pot means somebody is about to win money that was
--      never all there. Any failure refunds every ante already taken (kb/economy.md lesson 6).
--   2. Pay the ANTED id, never the live card. Players eject mid-match and strangers insert cards;
--      the money must follow whoever paid (kb/economy.md lesson 2, generalised to N seats).
--   3. Refund and pay with wallet.credit, never creditNow -- on a hub timeout the money outboxes
--      and is flushed later. The player is owed it.
local card         = require("card")
local card_session = require("card_session")
local wallet       = require("wallet")

local M = {}

-- cfg.drives   = seat order (peripheral names). nil = discover, sorted. The per-station .cfg
--                overrides it: CC does NOT hand identically-built stations identical peripheral
--                names ([[station-hardware-discovery]]).
-- cfg.minSeats = the minimum number of CARDED seats that makes a pot (default 2).
-- cfg.maxSeats = cap on seats built from the drives (default 4).
-- cfg.ante     = $ per carded seat (default 10).
function M.new(cfg)
  cfg = cfg or {}
  local self = {
    ante     = cfg.ante or 10,
    minSeats = cfg.minSeats or 2,
    maxSeats = cfg.maxSeats or 4,
    phase    = "lobby",   -- "lobby" | "playing" | "done"
    pot      = 0,
    seats    = {},
  }

  -- ONCE for the station, not once per seat: N seats would be N rednet round-trips at boot, and
  -- with the hub down that is N serialised LOOKUP_BACKOFF windows in the boot path (wallet.lua).
  wallet.flush()

  local drives = cfg.drives or card.drives()
  for i = 1, math.min(#drives, self.maxSeats) do
    self.seats[i] = {
      drive   = drives[i],
      session = card_session.new{ drive = drives[i], flush = false },
      antedId = nil,   -- id DEBITED this match. nil = this seat did not pay (anon, or lobby).
      anted   = 0,     -- $ this seat put in
    }
  end

  -- fold a raw os event into state. Call for EVERY event in the play loop.
  -- Each session filters on its own drive, so one insert refreshes exactly one seat.
  function self.onEvent(ev)
    for _, s in ipairs(self.seats) do s.session.onEvent(ev) end
  end

  function self.cardedCount()
    local n = 0
    for _, s in ipairs(self.seats) do
      if s.session.player then n = n + 1 end
    end
    return n
  end

  -- For the UI only. There is deliberately no occupancy quorum: an anonymous player is INVISIBLE
  -- (a seat is a drive; a human standing at one with no card emits nothing a computer can read),
  -- so GO is always live and start() decides staked-vs-free from the only thing observable -- how
  -- many cards are in.
  function self.canStake()
    return self.cardedCount() >= self.minSeats
  end

  -- Give back every ante in `list` (seat indices), in full. Rule 3: credit, so a hub outage
  -- outboxes it rather than losing it.
  local function refundSeats(list)
    for _, i in ipairs(list) do
      local s = self.seats[i]
      if s.antedId then
        local ok, bal = wallet.credit(s.antedId, s.anted)
        if ok and bal and s.antedId == s.session.player then s.session.setBalance(bal) end
        s.antedId, s.anted = nil, 0
      end
    end
  end

  -- The GO edge. Returns "staked" | "free" | "deny", reason, seatIndex.
  function self.start()
    if self.phase == "playing" then return "deny", "already playing" end

    for _, s in ipairs(self.seats) do s.antedId, s.anted = nil, 0 end
    self.pot = 0

    local carded = {}
    for i, s in ipairs(self.seats) do
      if s.session.player then carded[#carded + 1] = i end
    end

    -- A pot needs at least two contributors. One carded seat would ante and win its own ante back,
    -- which is a debit, a credit and a disk write to achieve nothing -- so that is a free match.
    if #carded < self.minSeats then
      self.phase = "playing"
      return "free"
    end

    local paid = {}
    for _, i in ipairs(carded) do
      local s = self.seats[i]
      local ok, bal, reason = wallet.debit(s.session.player, self.ante)
      s.session.noteHub(reason)
      if ok then
        s.antedId, s.anted = s.session.player, self.ante   -- capture at commit (rule 2)
        s.session.setBalance(bal)
        paid[#paid + 1] = i
      else
        if bal ~= nil then s.session.balance = bal end      -- deny reply carries current balance
        refundSeats(paid)                                   -- rule 1: never leave a partial pot
        self.phase = "lobby"
        return "deny", (reason or "unknown"), i
      end
    end

    self.pot = self.ante * #paid
    self.phase = "playing"
    return "staked"
  end

  -- Resolve. `scores` = { [seatIndex] = number }; a missing seat scores 0.
  -- Returns { matchWinner, potWinner, potShare = {[seat]=amount}, pot }.
  function self.finish(scores)
    scores = scores or {}
    local res = { potShare = {}, pot = self.pot }

    -- The match winner is the best of ALL seats -- an anonymous player can take the glory.
    -- A tie takes the lowest seat index; this is a debug harness, not a tournament.
    local best, bestScore
    for i = 1, #self.seats do
      local sc = scores[i] or 0
      if bestScore == nil or sc > bestScore then best, bestScore = i, sc end
    end
    res.matchWinner = best

    -- The pot goes to the best-scoring seat that actually PAID IN. Built ascending, so a tie list
    -- is already in seat order.
    local top, topScore = {}, nil
    for i = 1, #self.seats do
      if self.seats[i].antedId then
        local sc = scores[i] or 0
        if topScore == nil or sc > topScore then top, topScore = { i }, sc
        elseif sc == topScore then top[#top + 1] = i end
      end
    end

    if #top > 0 and self.pot > 0 then
      -- Integer $ only: ("%d"):format(10.5) silently prints "10" in Lua 5.1, so a fractional
      -- share would leave the ledger and every screen disagreeing. Split the floor and hand the
      -- remainder to the lowest seat, so the shares sum to the pot EXACTLY -- no $ evaporates.
      local share = math.floor(self.pot / #top)
      local rem   = self.pot - share * #top
      for k, i in ipairs(top) do
        local amt = share + (k == 1 and rem or 0)
        if amt > 0 then
          local s = self.seats[i]
          local ok, bal = wallet.credit(s.antedId, amt)   -- rule 2: the ANTED id
          if ok and bal and s.antedId == s.session.player then s.session.setBalance(bal) end
          res.potShare[i] = amt
        end
      end
      res.potWinner = top[1]
    end

    self.phase = "done"
    self.pot = 0
    return res
  end

  function self.status()
    local seats = {}
    for i, s in ipairs(self.seats) do
      local st = s.session.status()
      seats[i] = {
        player  = st.player,
        balance = st.balance,
        offline = st.offline,
        anted   = s.anted,
        antedId = s.antedId,
      }
    end
    return { phase = self.phase, pot = self.pot, seats = seats }
  end

  return self
end

return M
```

- [ ] **Step 4: Run the tests**

Run: `luajit test/test_mp_econ.lua`
Expected: PASS — `N passed, 0 failed`

- [ ] **Step 5: Syntax check + full suite**

Run: `luajit -bl src/lib/mp_econ.lua /dev/null`
Expected: no output (exit 0).

Run: `for f in test/test_*.lua; do echo "== $f"; luajit "$f" || exit 1; done`
Expected: every file `0 failed`.

- [ ] **Step 6: Commit**

```bash
git add src/lib/mp_econ.lua test/test_mp_econ.lua
git commit -m "feat(mp_econ): the pot engine -- N seats, ante, payout

A seat is a drive: it exists whether or not a card is in it, and an empty seat
is an anonymous player who can win the match but never the pot.

Three money rules, all tested: the ante is all-or-nothing (a partial pot pays
out money that was never all there, so any failure refunds every ante already
taken); the payout follows the ANTED id, so pulling your card mid-match or
handing your seat to a stranger cannot move it; refunds outbox on a hub
timeout rather than evaporating.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: Pong — the debug harness

**Files:**
- Modify: `src/pong/pong.lua`

**Interfaces:**
- Consumes: `mp_econ.new{drives, ante}`, `e.onEvent(ev)`, `e.start()`, `e.finish(scores)`, `e.status()`, `e.phase` (Task 5).
- Produces: nothing (leaf).

**Context:** **This is a throwaway harness, not a game.** No art, no advert, no pixelfont — the alphabet does not exist and is another session's job. Native `win.write` text only. The existing rally (`physics()`/`draw()`) is untouched; `ls`/`rs` already exist and are the scores.

**The two things that must be right:**

1. **`play()` may not exit with `phase == "playing"`.** `pong.lua:160` returns `"sleep"` the moment the zone empties. With a live pot that debits both players and credits nobody — **the $ evaporates.** Call `finish()` first, then sleep. Same for the operator's `Q`.
2. **Re-arm the tick timer after any handler that touches `mp_econ`.** `pong.lua` re-arms only in its timer branch — the exact shape that froze the slot (`[[event-pump-reentrancy]]`). `mp_econ` calls `wallet`, which pumps events; `wallet` stashes and re-queues them, so this is already safe — but the cage re-arms after every touch handler anyway because the guarantee is worth having unconditionally. Do the same.

- [ ] **Step 1: Add the cfg reader and econ wiring**

In `src/pong/pong.lua`, after the `config` block and before `local mon = peripheral.find("monitor")`, add:

```lua
-- ---- per-station wiring ----------------------------------------------------
-- pong.cfg is NOT in the package file list, so it survives `update pong` (which OVERWRITES
-- pong.lua). It is the ONLY place per-station wiring belongs. cfg always wins over discovery:
-- CC does not hand identically-built stations identical peripheral names.
--   drives=drive_0,drive_1     # seat order: left paddle first
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

local CFG   = readCfg()
local ANTE  = tonumber(CFG.ante) or 10
```

- [ ] **Step 2: Add the econ header, buttons and touch hit-test**

After the existing `draw()` function, add:

```lua
-- ===== DEBUG ECON HARNESS ===================================================
-- Native cell text on purpose. This is a harness for mp_econ, not a game: pong has no win
-- condition, no advert and no pixelfont alphabet to draw one with. Do not decorate it.
local econ                                   -- the mp_econ instance for this session
local GO_W, END_W = 6, 7                     -- button widths on the bottom row

local function btnHit(x, y)
  if y ~= H then return nil end
  if x <= GO_W then return "go" end
  if x > W - END_W then return "end" end
  return nil
end

-- top row, left: the seats. The score keeps the centre (draw() already put it there).
local function drawEcon()
  local st = econ.status()
  local parts = {}
  for i, s in ipairs(st.seats) do
    local who
    if s.antedId then who = s.antedId .. "*"          -- * = paid in; the seat is locked to this id
    elseif s.player then who = s.player
    else who = "anon" end
    if s.offline then
      parts[#parts + 1] = who .. " OFFLINE"
    elseif s.balance then
      parts[#parts + 1] = ("%s $%d"):format(who, s.balance)
    else
      parts[#parts + 1] = who
    end
  end
  win.setBackgroundColor(colors.black); win.setTextColor(colors.white)
  win.setCursorPos(1, 1)
  win.write(table.concat(parts, " | "):sub(1, W))
  if st.pot > 0 then
    local p = ("POT $%d"):format(st.pot)
    win.setCursorPos(math.max(1, W - #p + 1), 1)
    win.setTextColor(colors.yellow)
    win.write(p)
    win.setTextColor(colors.white)
  end
end
```

The button literals and the hit-test widths must stay in step: `" GO   "` is exactly `GO_W` = 6 characters and `" END   "` is exactly `END_W` = 7. If you change one, change the other, or the touch target drifts off the paint.

```lua
-- bottom row: [ GO ] ............... [ END ]
local function drawButtons()
  local gap = math.max(0, W - GO_W - END_W)
  win.setCursorPos(1, H)
  win.setBackgroundColor(colors.gray); win.setTextColor(colors.white)
  win.write(" GO   ")
  win.setBackgroundColor(colors.black)
  win.write(string.rep(" ", gap))
  win.setBackgroundColor(colors.gray)
  win.write(" END   ")
end
```

(`" GO   "` is exactly `GO_W` = 6 chars; `" END   "` is exactly `END_W` = 7. Keep the literals and the widths in step.)

- [ ] **Step 3: Rewrite `play()`**

Replace the whole `play` function in `src/pong/pong.lua`:

```lua
-- ACTIVE session: pong's physics loop, run by idle_runner while a player is present. Resets the
-- game each entry (fresh scores/ball). Returns "sleep" when the zone empties, or "quit" on Q.
local function play(mon, pres)
  ls, rs = 0, 0
  lp = math.floor((H - PADDLE_H) / 2) + 1
  rp = lp
  resetBall(math.random() < 0.5 and -1 or 1)

  econ = require("mp_econ").new{ drives = splitList(CFG.drives), ante = ANTE }
  local msg = nil                                  -- transient status line (deny reasons)

  local function render()
    draw()          -- the rally, unchanged
    drawEcon()
    drawButtons()
    if msg then
      win.setBackgroundColor(colors.black); win.setTextColor(colors.red)
      win.setCursorPos(1, 2); win.write(msg:sub(1, W))
      win.setTextColor(colors.white)
    end
    win.setVisible(true)
  end

  -- A live pot must never leave this loop unresolved. On the way out, whoever is ahead takes it --
  -- which is exactly what "the ante is forfeit" means when the player who walked off was losing.
  -- Without this, exiting mid-match debits both players and credits nobody: the $ evaporates.
  local function resolve()
    if econ.phase == "playing" then econ.finish{ [1] = ls, [2] = rs } end
  end

  local timer = os.startTimer(TICK)
  render()

  while true do
    local ev = { os.pullEvent() }
    if ev[1] == "timer" and ev[2] == timer then
      physics()
      render()
      if pres.gone() then resolve(); return "sleep" end
      timer = os.startTimer(TICK)

    elseif ev[1] == "monitor_touch" then
      local hit = btnHit(ev[3], ev[4])
      if hit == "go" then
        msg = nil
        local res, reason, seat = econ.start()
        if res == "deny" then
          if reason == "timeout" then msg = "HUB OFFLINE - nobody charged"
          elseif reason == "already playing" then msg = "MATCH ALREADY RUNNING"
          else msg = ("SEAT %d: %s - all antes refunded"):format(seat or 0, tostring(reason):upper()) end
        elseif res == "free" then
          msg = "FREE RALLY - 2 cards to play for a pot"
        end
        ls, rs = 0, 0                              -- a match starts from 0-0
        resetBall(math.random() < 0.5 and -1 or 1)
      elseif hit == "end" then
        local r = econ.finish{ [1] = ls, [2] = rs }
        if r.potWinner then
          msg = ("SEAT %d TAKES $%d"):format(r.potWinner, r.potShare[r.potWinner] or 0)
        else
          msg = ("SEAT %d WINS (no pot)"):format(r.matchWinner or 0)
        end
      end
      render()
      timer = os.startTimer(TICK)   -- re-arm unconditionally: a handler that touches the hub runs a
                                    -- nested event pump, and this loop only re-arms in its timer
                                    -- branch ([[event-pump-reentrancy]]). The cage does the same.

    elseif ev[1] == "disk" or ev[1] == "disk_eject" then
      econ.onEvent(ev)
      render()
      timer = os.startTimer(TICK)   -- refreshCard hits the hub: same reason as above

    elseif ev[1] == "rednet_message" then
      pres.fromEvent(ev)
    elseif ev[1] == "key" and ev[2] == keys.q then
      resolve(); return "quit"
    end
  end
end
```

**`draw()` currently ends with `win.setVisible(true)`.** Leave it — a second `setVisible(true)` in `render()` is harmless. But `draw()` also starts with `win.setVisible(false)`, so the econ overlay drawn *after* it would land in the same hidden buffer and flush on `render`'s `setVisible(true)`. That is the intended order; do not reorder.

- [ ] **Step 4: Syntax check**

Run: `luajit -bl src/pong/pong.lua /dev/null`
Expected: no output (exit 0).

Run: `for f in test/test_*.lua; do luajit "$f" || exit 1; done`
Expected: every file `0 failed` (pong has no unit tests — it is a harness of I/O; this is the regression check).

- [ ] **Step 5: Commit**

```bash
git add src/pong/pong.lua
git commit -m "feat(pong): debug harness for mp_econ -- seats, GO/END, pot

Explicitly throwaway: native text only, no art, no advert. Pong has no win
condition and this session is not the one that gives it one, so END resolves
the match and the highest score takes the pot.

play() may not exit with a live pot: pong returned 'sleep' the moment the zone
emptied, which with a pot on the table debits both players and credits nobody.
Zone-empty and Q both resolve first. The timer is re-armed after every handler
that touches the hub, as the cage does.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 7: `packages.lua` — the manifest

**Files:**
- Modify: `src/packages.lua`

**Interfaces:**
- Consumes: every file created in Tasks 1–6.
- Produces: nothing (deploy data).

**Context:** `update <pkg>` installs exactly the files listed here. **A missing module is not a code bug** — it presents as `unknown package` or a short install, and the raw-CDN lag makes it look like one anyway (`CLAUDE.md`). Verify the manifest against the tree, not against memory.

**What changed:** `slot` and `cage` now `require("card_session")`. `pong` requires `card`, `wallet`, `card_session` and `mp_econ` — **it has never had any of them** (it had no economy at all).

- [ ] **Step 1: Add `card_session` to slot and cage**

In `src/packages.lua`, in the `slot` file list, immediately after the `card` line:

```lua
      { name = "card",         path = "lib/card.lua" },
      { name = "card_session", path = "lib/card_session.lua" },
      { name = "wallet",       path = "lib/wallet.lua" },
      { name = "sp_econ",      path = "lib/sp_econ.lua" },
```

Same in the `cage` list:

```lua
      { name = "card",         path = "lib/card.lua" },
      { name = "card_session", path = "lib/card_session.lua" },
      { name = "wallet",       path = "lib/wallet.lua" },
      { name = "cage_econ",    path = "lib/cage_econ.lua" },
```

- [ ] **Step 2: Give pong the economy**

Replace the `pong` package entirely:

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
      { name = "pong_advert",  path = "pong/pong_advert.lua" },
      { name = "pong",         path = "pong/pong.lua" },
    },
  },
```

- [ ] **Step 3: Verify the manifest against the tree**

Run this — it lists every `require`d name per package's main file and every path in the manifest, so a missing entry is visible:

```bash
grep -n 'require(' src/pong/pong.lua src/slot/slot.lua src/cage/cage.lua src/lib/*.lua
```

Expected: every name in the output appears in the file list of every package whose station loads it. Specifically confirm: `card_session` is in **slot**, **cage** and **pong**; `mp_econ` and `wallet` and `card` are in **pong**.

Then confirm every manifest path exists:

```bash
lua -e 'for _,p in ipairs({"lib/card.lua","lib/card_session.lua","lib/wallet.lua","lib/mp_econ.lua","lib/sp_econ.lua","lib/cage_econ.lua"}) do local f=io.open("src/"..p) print(p, f and "OK" or "MISSING") if f then f:close() end end'
```

Expected: all `OK`.

Run: `luajit -bl src/packages.lua /dev/null`
Expected: no output (exit 0).

- [ ] **Step 4: Commit**

```bash
git add src/packages.lua
git commit -m "deploy: card_session for slot+cage, the whole economy for pong

pong has never had card/wallet -- it had no economy at all. slot and cage now
require card_session, so a missing entry here would install a station that
cannot boot.

No hub entry changes: the protocol did not change, so `update hub` is not part
of this deploy and none of lesson 7's hub-too-old trap applies.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 8: Docs — `todo.md`, `README.md`, `kb/economy.md`

**Files:**
- Modify: `todo.md`, `README.md`, `kb/economy.md`

**Context:** **`todo.md` and `README.md` are contended** — a parallel design session may be editing them. Do this **last**, in **one small commit**, and **rebase before merging**. `kb/economy.md` is not contended.

- [ ] **Step 1: Rebase onto the latest main first**

```bash
git fetch origin
git rebase origin/main
```

Expected: clean, or conflicts only in `todo.md`/`README.md` — resolve by **keeping both sides' content** (the other session's edits are about the pixelfont alphabet; yours are about the engine — they do not overlap semantically).

- [ ] **Step 2: Update `kb/economy.md`**

In the **Architecture — three layers** block, change the GATEWAY/CORE lines to:

```
GATEWAY   sp_econ.lua  (single-player: one card, house paytable)                    ← built
          cage_econ.lua (card session + hub debit/credit, sibling of sp_econ)       ← built
          mp_econ.lua  (N seats, ante -> pot -> payout)                             ← built
CORE      card_session.lua (ONE card on ONE drive)                                  ← built
          card.lua · wallet.lua (+outbox) · ledger.lua (hub)                        ← SP/MP-agnostic
```

Add to the bullet list under it:

```markdown
- **`lib/card_session.lua`** — **one card on one drive.** The machinery `sp_econ` and `cage_econ`
  each grew independently (read the card, ask the hub, fall back to the mirror, re-read on disk
  events, write the mirror back), extracted when `mp_econ` made it three. Bound to `drive = nil` it
  is the single-card behaviour slot and the cage always had; bind N to N named drives and you have N
  seats. `onEvent` filters by drive (`ev[2]`) — without that, one insert at a 4-seat station fires
  four `wallet.query` round-trips.
- **`lib/mp_econ.lua`** — the pot gateway: `start()` (ante), `finish(scores)` (payout),
  `onEvent(ev)`, `cardedCount()`, `canStake()`, `status()`. **A seat is a drive** — it exists with
  or without a card, and an empty seat is an anonymous player who can win the *match* but never the
  *pot*. Staked iff `>= minSeats` (2) carded seats. No protocol change: a pot is `debit` + `credit`.
```

Add a new lesson to **Hard-won lessons**:

```markdown
8. **A pot is all-or-nothing, and a live pot must never leave the play loop.** Two failure modes,
   both of which lose real money and neither of which any per-task review would catch:
   - **A partial ante** pays somebody money that was never all there — two seats paid, one didn't,
     and the winner takes a pot with a hole in it. `mp_econ.start` refunds every ante already taken
     the moment any debit fails. Lesson 6's ordering invariant with "the pot is complete" as the
     stock check.
   - **An unresolved pot evaporates.** `pong.lua` returned `"sleep"` the instant the zone emptied —
     correct when a round is a lever pull that resolves in one tick (the slot), catastrophic when a
     match lasts as long as the players do. Both players debited, `finish` never called, the $ gone.
     **`play()` may not exit with a live pot.** Still open in the worst case: a chunk unload or a
     crash mid-match runs no exit path at all (`[[unloaded-chunk-is-the-cheapest-sleep]]`) — that
     needs a persisted pot journal like the outbox, and it must exist before an MP game takes real
     players. Filed in `todo.md`.
```

- [ ] **Step 3: Update `README.md`**

In the **Components & roadmap** table, replace the **Multiplayer economy** row:

```markdown
| **Multiplayer economy**| engine ✓ (in-world pending) | `lib/card_session` (one card on one drive) + `lib/mp_econ` (N seats, ante→pot→payout). A seat is a drive; anon seats play but never win the pot. Pong is a debug harness only. |
```

- [ ] **Step 4: Update `todo.md`**

Replace backlog item **1** with a DONE section, and add the two new gaps. Insert this section immediately above `## Backlog`:

```markdown
## MP economy engine — BUILT 2026-07-17 ✓ (in-world verification PENDING)

The engine for 2–4 player staked games. Spec:
`docs/superpowers/specs/2026-07-17-mp-econ-engine-design.md`; plan:
`docs/superpowers/plans/2026-07-17-mp-econ-engine.md`. **Pong is a debug harness, not a game** —
native text, no art, no advert, and `END` resolves the match because pong has no win condition.

**The unlock: a card session is ONE CARD ON ONE DRIVE.** Bound to `drive = nil` it is the
single-card behaviour slot and the cage always had (zero regression); bind N to N named drives and
it is multiplayer. So `card.read()`-takes-the-first-drive (the blocker) and the `sp_econ`/`cage_econ`
rule-of-three extraction were **the same piece of work**, which is why this was one branch.

- **`card.drives()` returns EVERY drive, disk or not** — a drive is a seat, and an empty seat still
  exists. Filtering to drives-with-a-disk (the first draft) makes a cardless player vanish from the
  station instead of showing up as an anonymous seat.
- **There is no occupancy quorum, because an anonymous player is INVISIBLE.** A human standing at a
  cardless seat emits nothing a computer can read, so GO is always live and `start()` decides
  staked-vs-free from the only observable fact: how many cards are in. `minSeats` means *carded*
  seats, not bodies.
- **Owner-set policy:** ante is forfeit · seats lock at ante (a card inserted mid-match is a
  spectator) · anon seats play but never win the pot, and when an anon takes the match the **best
  carded seat** takes the money · touch `GO`.
- **The drift died:** `cage_econ` folded hub-unreachable and insufficient-funds into one `msg`, so a
  dead ledger id read as `NEED $100` at a player who wasn't broke. Now three states
  (`HUB OFFLINE`/`BAD CARD`/`NEED $n`), and `cage_econ` has tests for the first time.
- **No protocol change** — a pot is existing `debit` + `credit`, so **no `update hub`**, and none of
  `kb/economy.md` lesson 7's hub-too-old trap.

**New gaps this opened, filed not fixed:**
- **A chunk unload or crash mid-match evaporates the pot.** An unloaded chunk's computer is CLOSED,
  not sleeping (`[[unloaded-chunk-is-the-cheapest-sleep]]`), so no exit path runs, `finish` never
  happens, and the debited $ is gone. The window is small (a player present means the chunk is
  loaded) and the fix is a persisted pot journal like `wallet`'s outbox, replayed at boot.
  **Must be closed before an MP game takes real players.**
- **`getMountPath()` on a NETWORK drive is unverified** — the whole seat model assumes two drives on
  one computer both mount. It is a 2-minute in-world check and the design rests on it.

**In-world verification (PENDING):** `update slot` + `update cage` + `update pong`, reboot each ·
0 cards → free rally, **no regression** · 1 card → free, **no debit** · 2 cards → `GO` → both
debited, `POT $20` → `END` → higher score credited · **pull a card mid-match → the pot still pays
the anted id** · a *different* card mid-match → spectator gets nothing · seat 2 insufficient → `GO` →
**seat 1 not out of pocket** · hub down → `GO` → `HUB OFFLINE`, not `INSUFFICIENT`, nobody debited ·
**walk away mid-match → the pot resolves** · **slot + cage still work** (the extraction touched two
shipped stations — this is the regression that matters most).
```

Then in `## Backlog`, replace item 1 and item 2's cage follow-up:

```markdown
1. ~~**General multiplayer capabilities**~~ — **ENGINE BUILT 2026-07-17.** See the section above.
   What is left is a real MP *game* (pong is a harness): its own brainstorm→spec→build, and it must
   close the pot-journal gap first.
```

And in the cage follow-ups list under item 0, mark the extraction done:

```markdown
   - ~~**Extract `lib/card_session.lua`**~~ — **DONE 2026-07-17** with `mp_econ` (the rule-of-three
     trigger). `cage_econ`'s `msg`-string drift was reconciled onto `sp_econ`'s `offline`, which
     closed the "`NEED $x` for a dead card id" lie listed below.
```

- [ ] **Step 5: Commit**

```bash
git add todo.md README.md kb/economy.md
git commit -m "docs: the MP engine -- a card session is one card on one drive

Records the two gaps the branch opened and did not close: a chunk unload
mid-match evaporates the pot (needs a journal like wallet's outbox, and it must
exist before an MP game takes real players), and getMountPath() on a network
drive is unverified -- the whole seat model rests on it.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Final gate (before merge)

- [ ] `for f in test/test_*.lua; do echo "== $f"; luajit "$f" || exit 1; done` — every file `0 failed`. **16 files**: the 12 that were green at branch point, plus `test_card`, `test_card_session`, `test_cage_econ`, `test_mp_econ`.
- [ ] `for f in src/lib/*.lua src/*/*.lua src/*.lua; do luajit -bl "$f" /dev/null || echo "SYNTAX $f"; done` — no output.
- [ ] Whole-branch review (`superpowers:requesting-code-review`), with these asked explicitly:
  - Does any path pay `session.player` where it must pay `antedId`?
  - Can `start()` ever leave a partial pot standing?
  - Do the tie shares sum to exactly the pot for every `#top` and every pot value?
  - Can `play()` exit with `phase == "playing"` by any path?
  - Did anything new start pumping events outside `wallet`?
  - Did `sp_econ`'s or `cage_econ`'s observable behaviour change beyond the named drift fix?
- [ ] `git rebase origin/main` (todo.md/README.md are contended), then merge + push.
</content>
