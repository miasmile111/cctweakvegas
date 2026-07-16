# Per-station folders + shared idle runner — design

**Date:** 2026-07-16
**Status:** approved, pre-implementation
**Depends on / feeds:** the idle/lag model (`2026-07-16-idle-lag-model-design.md`, built). This
generalizes that model's per-station idle loop into ONE shared runner every station reuses, and
reorganizes `src/` so each station is self-contained.

## Problem

The idle model works, but its deep-sleep/wake/presence loop lives inside `slot.lua`. Every new
station would re-implement ~50 lines of it by hand (and `pong.lua` has no idle model at all — it
burns ticks forever). We want a station to be **just its play code + a static advert**, with all the
lag-critical idle machinery shared. We also want `src/` organized so each station's files live
together.

## Goals

1. **A station = a play file + a `<basename>_advert.lua`.** Nothing else. Idle-safety is inherited.
2. **One shared idle runner** owns: modem/rednet setup, deep sleep (draw advert once, block on
   `os.pullEvent` — zero cost), wake on hub `presence=true` or a local redstone edge, `presence?`
   query sync, quit/cleanup. On player-leave it draws `require("<name>_advert")`.
3. **Least-invasive to existing station loops.** A station keeps its own game loop, wrapped as a
   `play(mon, pres)` function; a tiny `pres` helper is the only presence code left in a station.
   No forced tick-callback framework.
4. **`src/` reorganized** into per-station folders + a `lib/` for cross-station modules. Deploy still
   flattens files by `name`, so **no `require()` call changes** — only `packages.lua` paths and the
   test harness `package.path`.
5. **Both stations adopt the runner** — slot (proof) and pong (finally gets idle-safety). The hub is
   not a station (always-on); only its file moves.

## Confirmed facts

- `update.lua:172-175`: `local path = file.path or (file.name..".lua")`, `body = fetch(path)`,
  `save(file.name, body)`. `path` is the repo location under `src/`; files are written **flat** by
  `name` onto the computer. So subfolders are repo-side only; in-game `require("subpixel")` etc. are
  unaffected. Only `packages.lua` `path` fields need updating.
- Local tests run under `luajit` with `package.path = "src/?.lua;test/?.lua;..."` — this must gain
  the new `src/lib/?.lua`, `src/slot/?.lua`, `src/pong/?.lua` entries.
- `os.pullEvent()` with no filter delivers rednet **and** redstone events — the runner's deep-sleep
  blocks on it and handles both wake causes with no timer (unchanged from the idle model).

## New `src/` layout

```
src/
  lib/                 cross-station shared modules
    subpixel.lua           (moved from src/lib/ — already here)
    idle_logic.lua         (moved from src/)
    idle_runner.lua        (NEW)
  hub/
    hub.lua
  slot/
    slot.lua  slot_logic.lua  slot_symbols.lua
    slot_advert.lua        (NEW)
  pong/
    pong.lua
    pong_advert.lua        (NEW)
  update.lua  mkinstaller.lua  hello.lua  packages.lua   (deploy tooling + manifest stay at src root)
```

## The idle runner — `lib/idle_runner.lua`

A single entry point. All shared, lag-critical machinery; no game logic.

```lua
-- run(cfg): drive a station's idle lifecycle.
--   cfg.name    (string)      basename; loads require(cfg.name .. "_advert")
--   cfg.monitor (peripheral)  wrapped monitor the advert and play draw on
--   cfg.zone    (string|nil)  presence zone (default "all")
--   cfg.wake    (table|nil)   optional local redstone-edge wake, { side=<str>, level=<int> }
--   cfg.play    (function)    play(monitor, pres) -> "sleep" | "quit"
```

Behavior:

```
open modem -> hasRednet   (broadcast presence? only if a modem exists)
advert = require(cfg.name .. "_advert")
loop:
  -- DEEP SLEEP (zero cost)
  advert.draw(monitor)                 -- static advert, drawn ONCE
  queryPresence()                      -- {kind="presence?", zone} broadcast; reply wakes if occupied
  block on os.pullEvent until:
      presence=true for cfg.zone  -> WAKE
      redstone rising edge on cfg.wake (idle.leverRose)  -> WAKE   [only if cfg.wake set]
      Q key                       -> QUIT
  -- ACTIVE
  pres = fresh presence handle (present=true)
  queryPresence()                      -- sync real presence on entry (lever-wake-outside-range sleeps back)
  r = cfg.play(monitor, pres)
  if r == "quit" -> break
  -- r == "sleep" -> loop back to advert
cleanup: mon black + clear + text scale 1
```

The `pres` handle passed to `play` is built by a **pure factory in `idle_logic`**,
`idle.newPresence(zone)` (so it is unit-testable without CC):

```lua
pres.present            -- boolean, last known presence (starts true)
pres.fromEvent(ev)      -- if ev is a presence message for our zone, update pres.present; returns pres.present
pres.gone()             -- returns (not pres.present)
```

`newPresence` / `presenceFor` / `leverRose` all come from `lib/idle_logic.lua`; the runner is their
I/O host and calls `idle.newPresence(cfg.zone or "all")` on each active-session entry. The runner uses
protocol `"ccvegas"` — the project constant.

**Palette ownership:** the runner does NOT touch monitor palette. `<name>_advert.lua` draws with
**default palette colours only** (static — it does not need the drifting custom slots), so deep sleep
never modifies palette. A station's `play` owns any custom palette (e.g. slot's gradient) and restores
it before returning `"quit"`. On a deep-sleep quit (Q while advert shows) there is nothing to restore;
the runner's generic clear suffices.

## Advert contract — `<basename>_advert.lua`

One job: draw the static advert. Returns a module with `draw(monitor)`.

```lua
-- slot_advert.lua
local M = {}
function M.draw(mon)
  -- static "COME PLAY / GET MONEY" using DEFAULT palette colours; drawn once. No animation, no timer.
end
return M
```

- `slot_advert.draw` — the COME PLAY / GET MONEY sign (ports the current `drawIdleSign`, but using
  default colours instead of the GRAD slots).
- `pong_advert.draw` — a static pong advert (e.g. "PONG" + "STEP ON A PLATE"), plain text.

## Station conversions

### slot (`slot/slot.lua`)
- Keep config, `slot test` mode, monitor/window/canvas setup, `updateGradient`, `drawTopFrame`
  (already banner-free for active), `newSpin`, reel/bulb draw, `gradOrig` capture.
- Remove: `drawIdleSign` (moves to `slot_advert.lua`), `findModem`/`rednet.open`/`queryPresence`
  (now the runner's), `deepSleep`, and the outer sleep/wake loop (now the runner's).
- Wrap the former `runActive` body as `local function play(mon, pres) ... end`:
  - Presence: on `rednet_message`, call `pres.fromEvent(ev)`; in the `attract` branch,
    `if pres.gone() then return "sleep" end`.
  - On `Q`: `restorePalette()` then `return "quit"`.
- Replace the bottom of the file with:
  `require("idle_runner").run{ name="slot", monitor=topMon, zone=ZONE,
                               wake={ side=SPIN_SIDE, level=SPIN_LEVEL }, play=play }`

### pong (`pong/pong.lua`)
- Keep config, `pong test` mode, monitor setup, physics/draw.
- Wrap the game loop as `local function play(mon, pres)`:
  - Reset ball/scores at entry (fresh game each wake).
  - On `rednet_message`, `pres.fromEvent(ev)`; each tick, `if pres.gone() then return "sleep" end`
    (pong has no round to finish — sleeping immediately when empty is correct).
  - On `Q`: `return "quit"`.
- No `cfg.wake` (pong has no lever; hub presence is the only wake). Add `require("idle_runner").run{...}`.
- Pong must open rednet to receive presence — the runner handles that.

### hub (`hub/hub.lua`)
- File moves only. Hub is not a station and keeps its own always-on loop (registrar + presenceLoop).
  It still `require("idle_logic")`. It does NOT use `idle_runner`.

## `packages.lua` updates

Set explicit `path` (repo location under `src/`) for every relocated file; `name` (flat in-game
name) is unchanged. Shape:

```lua
slot = { station = true, files = {
  { name = "subpixel",    path = "lib/subpixel.lua" },
  { name = "idle_logic",  path = "lib/idle_logic.lua" },
  { name = "idle_runner", path = "lib/idle_runner.lua" },
  { name = "slot_logic",   path = "slot/slot_logic.lua" },
  { name = "slot_symbols", path = "slot/slot_symbols.lua" },
  { name = "slot_advert",  path = "slot/slot_advert.lua" },
  { name = "slot",         path = "slot/slot.lua" },
}}
pong = { station = true, files = {
  { name = "idle_logic",  path = "lib/idle_logic.lua" },
  { name = "idle_runner", path = "lib/idle_runner.lua" },
  { name = "pong_advert", path = "pong/pong_advert.lua" },
  { name = "pong",        path = "pong/pong.lua" },
}}
hub = { station = false, files = {
  { name = "idle_logic", path = "lib/idle_logic.lua" },
  { name = "hub",        path = "hub/hub.lua" },
}}
```

## Testing / verification

- **Local (luajit):** update every test file's `package.path` to include
  `src/lib/?.lua;src/slot/?.lua;src/pong/?.lua`. Extend `test/test_idle_logic.lua` to cover the new
  pure `newPresence(zone)` factory: a fresh handle has `present == true`; `fromEvent` on a matching
  `{kind="presence",zone,present=false}` message flips `present` to false and `gone()` to true; a
  presence message for a different zone leaves it unchanged; a non-presence event is ignored. All
  existing `idle_logic` asserts stay green (the module only moved folders). No separate runner test —
  the runner is pure I/O orchestration over already-tested `idle_logic` helpers; it is covered by the
  syntax check plus in-game verification.
- **Syntax:** `luajit -bl` on every moved/new `.lua`.
- **In-game (user):** `update slot` + `update pong` + `update hub`; verify slot behaves exactly as
  before (advert when empty, reels when present, lever spins, mid-round finish); verify pong now
  sleeps when empty and wakes on approach with its advert; confirm the folder move didn't break the
  deploy (files land flat, programs run).

## Non-goals / YAGNI

- No generic multi-hook plugin framework — one `run(cfg)` with a single `play` callback and the
  advert-by-convention. That's the whole surface.
- No per-zone/GPS changes (still deferred; `zone` carried through).
- No economy/card work.
- Advert visuals stay simple (static, default colours). Fancy per-station adverts can come later.
