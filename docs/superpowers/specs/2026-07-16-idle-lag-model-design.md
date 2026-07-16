# Idle / lag model — hub-driven 3-tier sleep — design

**Date:** 2026-07-16
**Status:** approved, pre-implementation
**Depends on / feeds:** the hub registrar (`src/hub.lua`, already built) and README §"Idle =
truly asleep". Unblocks lag-safe auto-run across many stations. Feeds the future economy (same
hub, same rednet bus).

## Problem

Auto-run boots every station into its game, but `slot.lua` runs a 0.05s timer loop **always** —
the gradient drifts and bulbs chase even when idle, and it polls its own lever every tick. Ten
booted slots = ten always-on loops burning server tick budget while nobody plays. Not lag-safe at
floor scale.

README's fix is a 3-tier idle model (deep sleep → attract → armed round). The original sketch put
a proximity sensor (pressure plate) at *each* station. The Advanced Peripherals **Player Detector**
(see `kb/advanced-peripherals.md`) lets us do better: **one detector on the hub** drives presence
for the whole floor, so the hub owns the *only* forever-loop and stations sleep at ~zero cost.

## Goals

1. **Idle = zero cost.** A station with no player in its zone runs no timer — it blocks on a single
   `os.pullEvent()`. Many idle stations cost ~nothing.
2. **Centralize the loop to the hub, and only the hub.** The chunk-loaded hub polls one Player
   Detector and pushes presence to stations. No station polls anything while asleep.
3. **Wake quietly on approach.** A player entering the zone wakes the station into an attract
   animation before they touch a control — no "press to start" ask.
4. **Never bricked.** A station also self-wakes on its own lever's redstone edge, so it's playable
   even if the hub is momentarily absent (the hub is chunk-loaded, so this is a cheap safety net,
   not a watchdog — no heartbeat machinery).
5. **Forward-compatible with per-zone (GPS) later.** v1 uses one hardcoded detector range; the
   protocol already carries a `zone`, so per-station zones become a config-only upgrade.

## Confirmed facts

- **Player Detector** (`kb/advanced-peripherals.md`): block `player_detector` (1.21.1+), attached
  over a wired modem, found with `peripheral.find`. `isPlayersInRange(range) -> boolean` is the
  cheap "zone occupied?" call for v1. `getPlayersInRange(range)`, `getPlayersInCoords(p1,p2)`, and
  `getPlayerPos(name) -> {x,y,z,...}` enable per-zone matching later.
- **Redstone Integrator is REMOVED in 1.21.1** — irrelevant here; stations read their lever with
  plain `redstone.getAnalogInput` as today.
- CC `os.pullEvent()` with no filter returns rednet messages **and** `redstone` events, so one
  blocking call covers both wake causes with no timer.
- `parallel.waitForAll` / `waitForAny` runs the registrar loop and the presence loop as coroutines
  in one program.

## Architecture

### Two macro-states per station

```
        hub presence=true (my zone)   OR   local redstone rising edge
DEEP SLEEP  ───────────────────────────────────────────────────────►  ACTIVE
 (no timer, blocks on os.pullEvent,     ◄───────────────────────────  (0.05s timer loop)
  monitor cleared)                       hub presence=false AND idle
                                         (a spin always finishes first)
```

- **DEEP SLEEP** — a **static "COME PLAY / GET MONEY" advertisement** is drawn ONCE (frozen
  gradient + centered text), then the loop body is a single `os.pullEvent()`. Zero loop cost — the
  sign advertises but costs the same as a black screen (no timer, no redraw). Transitions to ACTIVE on:
  - `rednet_message` where `msg.kind=="presence"`, `msg.present==true`, and the zone matches
    (`msg.zone == ZONE or msg.zone == "all"`); **or**
  - a `redstone` event whose `SPIN_SIDE` analog level rose to `SPIN_LEVEL` (cold lever pull /
    hub-down fallback).
- **ACTIVE** — the existing 0.05s timer loop, with substates:
  - `attract` — the animated game view: drifting gradient + chase bulbs + the **reels** (the
    COME PLAY advert is NOT shown here; it belongs to the idle screen). Polls the lever each tick.
  - `spinning` / `result` — unchanged from slot v1 (WIN/LOSE banner on result).
  - Exit to DEEP SLEEP when a `presence=false` for this zone has been received **and** the machine
    is in `attract` (idle). If `present=false` arrives mid-`spinning`/`result`, finish the round,
    then sleep. On sleep: draw the static idle advert (which sets its own palette) and block again.

  **Idle vs active render (refined during in-game verification):** empty zone shows the static
  COME PLAY sign; a present player sees the reels only. The two are mutually exclusive — the advert
  is the "come hither" seen from afar, the reels are what you get when you walk up.

### Hub — the only forever-loop

`src/hub.lua` gains a presence loop, run alongside the existing registrar via `parallel`:

- `registrar()` — the current `while true rednet.receive` register handler, **unchanged**.
- `presenceLoop()` — every `POLL` seconds (default 0.3):
  - `local occ = det and det.isPlayersInRange(DET_RANGE) or false`
  - On **transition only** (`occ ~= lastOcc`): `rednet.broadcast({kind="presence", zone="all",
    present=occ}, PROTO)`. Edge-triggered — no per-tick spam.
- Detector is **optional**: `local det = peripheral.find("player_detector")`. Absent ⇒ hub logs
  "no player detector — presence disabled" and still serves as registrar (bench without the block).

Config knobs (top of `hub.lua`): `DET_RANGE` (blocks, default e.g. 8), `POLL` (seconds, 0.3).

### Rednet protocol addition

One new message shape on the existing `ccvegas` protocol:

```
hub → stations (broadcast):  { kind = "presence", zone = "all", present = true|false }
```

- v1 hub always sends `zone="all"` (single hardcoded range).
- Station config `ZONE = "all"`. It reacts iff `msg.zone == ZONE or msg.zone == "all"`.
- **GPS upgrade path (later, config-only on stations):** hub computes per-zone occupancy from
  `getPlayerPos` vs each station's AABB and broadcasts `zone="slot1"` etc.; stations already filter
  by `ZONE`, so only their code's config changes.

### Station loop (slot.lua) shape

```
-- config: ZONE (default "all"); SPIN_SIDE / SPIN_LEVEL as today
present = false
while true do
  -- DEEP SLEEP
  clearMonitor()
  repeat
    local e = { os.pullEvent() }
    if e[1]=="rednet_message" and presenceMsgForMe(e) then present = e.present end
    if e[1]=="redstone" and leverRose() then present = true end   -- local fallback wake
  until present
  -- ACTIVE (existing timer loop; attract/spinning/result)
  runActive()   -- returns when present==false AND state=="attract"
end
```

`runActive()` is the current `while` loop, extended to: (a) listen for `rednet_message` presence
updates and set a `present` flag; (b) draw the attract banner in `attract`; (c) break out to the
outer loop when `present==false` and `state=="attract"`.

## Files touched

- `src/slot.lua` — split into DEEP SLEEP / ACTIVE; add attract banner; add rednet presence handling
  + local redstone-edge wake; clean monitor on sleep. Reel/gradient/bulb code reused as-is.
- `src/hub.lua` — add `presenceLoop()` + optional `player_detector`; run it and `registrar()` under
  `parallel.waitForAll`. `DET_RANGE` / `POLL` config.
- `src/packages.lua` — no new files (slot + hub already listed); verify no manifest change needed.
- `kb/advanced-peripherals.md` — already written; add measured tick-cost findings after testing.

No changes to `update.lua`, the installer, or the auto-run supervisor — this is behavior inside the
programs they already deploy.

## Testing / verification

1. **Detector wiring:** extend `slot test` (or a `hub test`) to print
   `peripheral.find("player_detector")` presence and live `isPlayersInRange(DET_RANGE)` as you walk
   in/out — confirm the range and block name in-world.
2. **Wake/sleep by proximity:** with hub running, walk into range → slot wakes to attract; walk out
   → after `POLL`, slot clears and sleeps. Pull the lever cold (or with hub off) → slot self-wakes.
3. **Mid-round safety:** start a spin, walk out during it → round finishes, banner shows, *then*
   it sleeps.
4. **Tick-cost payoff:** boot several slots; with all zones empty, confirm idle slots hold **no**
   `os` timer / burn no loop (server tick profiler or `/forge tps`/`/spark` before vs after adding
   the sleep model). **Log the measured drop to `kb/`.**

## Non-goals / YAGNI

- Per-station GPS zones (deferred; protocol is ready for them).
- Heartbeat / watchdog for hub-down (hub is chunk-loaded; the redstone-edge fallback is enough).
- Any economy / card / scoreboard work (that's the separate hub-economy track).
- Attract theming by time/weather (Environment Detector exists — future flavor, not now).
