# Per-station proximity — the hub as a position oracle — design

**Date:** 2026-07-17
**Status:** approved, pre-implementation
**Depends on / feeds:** completes the `zone` half of
`2026-07-16-idle-lag-model-design.md` ("per-station zones become a config-only upgrade").
Unblocks a floor of many stations, and stations placed **1000+ blocks out across the server**.

## Problem

The floor is **one zone**. `hub.lua`'s `presenceLoop` polls a single `player_detector` with
`isPlayersInRange(DET_RANGE)` and broadcasts `{kind="presence", zone="all", present=occ}`. Every
station matches `zone == "all"`, so a player at the **hub** wakes **every** station, and a player at
the **cage** wakes nothing unless the hub can see them. (This is why the cage sat on its advert for
a whole session — its GUI was never reached.)

## Owner intent that shapes this design

Established during brainstorming, and it changes the answer:

1. **Stations will be spread across the server, 1000+ blocks out** — not just a single floor.
2. **The base itself will hold a lot of stations** (a floor of ~10 slot machines, plausibly
   hundreds eventually). All of them sit inside simulation distance, i.e. permanently ticking.
3. **No wired cable networks exist today** outside the cage's vault/deposit island. Cross-station
   links are ender modems.
4. **Peripheral side-pressure is real:** monitor, disk drive, ender modem, and the computer must
   stay inaccessible from the front, leaving roughly the back/left for redstone.

(2) is the load-bearing one: **any design that costs one poll per station is a design whose cost
grows with exactly the thing the owner wants to grow.**

## Goals

1. **Per-station presence.** A player at the cage wakes the cage and nothing else.
2. **Cost is O(online players), not O(stations).** Adding the 100th station must add ~zero
   recurring cost.
3. **Deep sleep stays a true block.** No station polls anything while idle — `os.pullEvent`, as today.
4. **Works at 1000+ blocks.** A remote station is no harder than one next to the hub.
5. **Self-configuring positions where possible.** Hundreds of stations must not mean hundreds of
   hand-typed coordinates — but the GPS constellation that enables this must be **optional**, added
   whenever, with no code change.
6. **No regression.** A station that hasn't registered a position keeps working exactly as today.

## Non-goals

- Building the GPS constellation itself (CC ships `gps host`; it is a **build task**, not code).
- Zone *shapes* / overlapping zones. One position + one range per station.
- Presence for anything but waking: no analytics, no player tracking, no "who is playing".

## Decision

**The hub becomes a server-wide position oracle.** Once per poll it asks *who is online* and *where
each player is* — that is **O(players)** — then does all zone matching in **pure Lua** against a
persisted `computerID → position` map. It sends presence **directly to each station's computer ID**
(rednet addresses by computer ID, so no broadcast storm), on edges only.

Stations learn their own position at boot via `gps.locate()`, falling back to a `pos=` cfg line.

### Why not one player detector per station

It was the first recommendation and it was wrong. It is **O(stations)**: ten slot machines in the
base is ten main-thread calls per second forever, a hundred is a hundred — and every one of them is
`mainThread = true` (below). It also *degrades deep sleep*: a station with a local detector cannot
block on `os.pullEvent`, it must poll. The oracle keeps deep sleep at zero cost **and** scales.

Kept as the **documented fallback** if the spike (below) comes back bad, because it is the only
design that needs no server config cooperation at all.

### Why the "stations 1000 blocks out can't hear rednet" objection is void

A station only needs to hear the hub **when a player is near it** — and a player near it **has
already loaded its chunk**. Verified in CC:T source: chunk unload → `setRemoved()` → `unload()` →
`computer.close()`; chunk load → `on = startOn = nbt.getBoolean(NBT_ON)` → `serverTick` sees
`startOn` → `computer.turnOn()` → reboot → the `startup` supervisor → `idle_runner.deepSleep()` →
which **already** fires `queryPresence()` on entry. The hub answers with current state and the
station wakes. This path was built in the idle spec ("pull-able presence syncs boot-while-occupied")
and needs no change.

Corollary, and it is free: **an unloaded remote station costs literally nothing — better than deep
sleep.** Chunk loading is already a coarse (~simulation-distance) proximity gate; this design adds
the fine one.

## Confirmed facts (research log — do not re-derive)

Every one of these was read from source or measured, not recalled.

1. **Every `player_detector` method is `mainThread = true`** — *all* of them, including the
   "cheap" `isPlayersInRange`. AP `release/1.21.1`, `PlayerDetectorPeripheral.java`. So ~50ms of
   parked coroutine per call; see `[[main-thread-peripheral-calls-cost-a-tick]]`. **Count the calls.**
2. **`playerDetMaxRange` defaults to `-1` (unlimited) in 1.21.1**, *not* 100 —
   `defineInRange("playerDetMaxRange", -1, -1, Integer.MAX_VALUE)`. Pre-1.21 AP defaulted to 100,
   which is where the KB's unverified item came from. At `-1` the hub's detector sees the **whole
   server**, which is what makes this design possible.
3. **`getPlayerPos` is config-gated three ways:** `enablePlayerPosFunction` (default `true`; if
   false the function **throws**), `enablePlayerPosRandomError` (default `false`; if true, positions
   past `playerPosPreciseMaxRange`=100 are fuzzed by up to 1000 blocks), and `morePlayerInformation`
   (default `true`; supplies the `dimension` field). All three defaults favour us. **All three are
   the spike.**
4. **Dimension filtering is free for range/box queries** —
   `CoordUtil.isPlayerInBlockRange` does `if (range != -1 && player.level() != world) return false;`
   and the box variant filters through `world.getNearbyPlayers` on the detector's own level. But
   **`getPlayerPos` does NOT filter** — at `maxRange = -1` with `playerDetMultiDimensional` (default
   true) it returns players in *any* dimension. **The hub must filter on `dimension` explicitly.**
   This is the todo's "a player in the Nether must not wake the floor", and it is real *only* on the
   path this design uses.
5. **AP's ranges are squares, not spheres** — `Math.abs(x-bx) <= range && Math.abs(z-bz) <= range`
   (Chebyshev in x/z) plus a feet/eye y rule. Irrelevant to our matching (which is pure Lua and
   defines its own shape) but relevant to the legacy `all` zone and to intuition.
6. **CC:T computers do not tick in unloaded chunks and reboot on load** — see "objection is void"
   above.
7. **GPS works with ender modems.** `WirelessNetwork.tryTransmit` calls
   `receiveSameDimension(packet, Math.sqrt(distanceSq))` whenever sender and receiver share a level
   — *even for interdimensional modems*. Distance is `nil` only across dimensions. So an ender-modem
   constellation covers the server, and **a successful `gps.locate()` proves the station is in the
   constellation's dimension.**
8. **`gps.locate` / `gps host` scan only the computer's SIX SIDES for a wireless modem**
   (`for _, sSide in ipairs(rs.getSides())` + `isWireless()`). **The ender modem must stay on a
   computer side** — mounting it on the cable (if that works at all) silently kills GPS.
9. **A single-chunk constellation is exact** — measured, `test/spikes/gps_constellation.lua`.
   CC distances are exact doubles (no measurement noise), so there is no dilution of precision and
   horizontal spread buys nothing. What matters is degeneracy: `trilaterate` rejects near-collinear
   hosts (`|â2b · â2c| > 0.999`) and three hosts yield a **mirrored pair** that `narrow()` can only
   resolve with a **fourth fix off their plane**. Measured reach for 3 hosts at a chunk's corners:

   | 4th host lift | exact out to |
   |---|---|
   | +5 y | 20,000 blocks |
   | +10 y | 50,000 blocks |
   | +40 y | 100,000 blocks |
   | all coplanar | **fails at any distance** (mirror unresolved) |
   | all collinear | **fails** (degenerate) |

10. **CC ships the host program** — `rom/programs/gps.lua`, `gps host <x> <y> <z>`. The
    constellation costs us **zero code**.
11. **Wired networks exclude only wired modems** —
    `return peripheral instanceof WiredModemPeripheral ? null : peripheral;` and the
    `peripheral_hub_ignore` tag is exactly `{"values": ["#computercraft:wired_modem"]}`. So an ender
    modem is not rejected *by type*; whether a cable can pick one up is a mounting-geometry question
    (`WirelessModemBlockEntity.getPeripheral` only returns itself toward its support block) —
    **untested, and per (8) we don't want it anyway.**
12. **CC:T's Redstone Relay exists in 1.21.x** (`RedstoneRelayPeripheral extends RedstoneMethods
    implements IPeripheral`) and is the supported way to get redstone sides off the computer.

## BLOCKING spike — `hub test pos`

**This design collapses if the server config disagrees. Run this before writing anything else.**

`hub test pos` prints, for the running player: the raw `getPlayerPos` return, its `dimension`, and
whether the call threw. Run it **twice** — once standing at the hub, once from a station ~1000
blocks out.

| Observation | Meaning | Action |
|---|---|---|
| Throws "This function is disabled in the config" | `enablePlayerPosFunction = false` | Ask the server owner to enable it, **or** fall back to Plan B |
| Returns `nil` from 1000 blocks, works up close | `playerDetMaxRange` is capped | Ask for `-1`, **or** Plan B |
| Position wrong by tens/hundreds of blocks when far | `enablePlayerPosRandomError = true` | Ask for `false`, **or** Plan B |
| No `dimension` field | `morePlayerInformation = false` | Ask for `true` (else cross-dimension false wakes) |
| Exact position, correct dimension, both distances | **Green — build this design** | Proceed |

The owner expects to be able to get these changed either way; the spike tells us *whether we need to
ask*. **Plan B** = the per-station `player_detector` fallback (documented above), which needs no
server cooperation.

## Architecture

Three pieces. Only the first is new logic.

### 1. `src/lib/proximity.lua` — pure, unit-tested

No CC APIs, testable under luajit like `idle_logic`/`ledger`.

```lua
M.near(station, playerPos)        -- dimension equal AND |dx|<=range AND |dz|<=range AND |dy|<=yRange
M.evaluate(stations, positions)   -- -> { [computerID] = present }
M.edges(prev, now)                -- -> { {id=<computerID>, present=<bool>}, ... }  (changes only)
```

Zone shape is **ours** now, not AP's: an axis-aligned box, `range` (default 4) in x/z and `yRange`
(default 3) in y. Simple to reason about, simple to test, and it makes fact (5) a non-issue.

### 2. `src/hub/hub.lua` — `presenceLoop` rewritten

Per poll (`POLL = 0.3s` unchanged):

```
occ      = det.isPlayersInRange(DET_RANGE)      -- 1 call: the legacy "all" zone, UNCHANGED
names    = det.getOnlinePlayers()               -- 1 call
positions = {}                                  -- P calls, skipped entirely when names is empty
for each name: positions[name] = det.getPlayerPos(name)
now      = proximity.evaluate(stations, positions)   -- pure Lua, free, O(stations) but no calls
for each edge in proximity.edges(prev, now):
    rednet.send(edge.id, {kind="presence", zone=edge.id, present=edge.present}, PROTO)
```

- **Cost: `2 + P` main-thread calls per poll, independent of station count.** At P=3 that is ~4
  calls/0.3s ≈ 1.2 tasks/tick — well inside the 5ms/computer budget, and the registrar coroutine
  keeps running while `presenceLoop` is parked on `task_complete`.
- **Known bound, named not fixed:** P is *all online players server-wide* (at `maxRange = -1`), not
  just nearby ones. Fine for a close-friends server (README's trust model). If Atlas ever runs 20+
  concurrent players, raise `POLL` or cluster-gate with `getPlayersInRange` first. Do not
  pre-optimize.
- **The legacy `all` broadcast is untouched**, so every station that hasn't registered a position
  behaves exactly as today. This is the no-regression guarantee: `slot` and `issue` keep working
  with zero changes. **But see the CORRECTION below** — "untouched broadcast" is only safe *because*
  `presenceFor` stops treating `"all"` as a wildcard; leaving both as originally specified is what
  makes the feature a no-op.
- `getPlayerPos` is wrapped in `pcall`. On throw: print a **loud, once** "PROXIMITY DISABLED —
  getPlayerPos is disabled in the server config", and stop reading positions. Registered stations do
  **not** go dark: every one of them is driven from the hub's own floor-wide detector reading instead
  (the same `occ` the legacy `all` zone uses), addressed to its own zone so it still matches
  `presenceFor`. A misconfigured server degrades to today's behaviour — anyone near the hub wakes every
  station — it does not brick.
- `DIM` (default `"minecraft:overworld"`) filters positions. Stations are assumed to be in it unless
  their cfg says otherwise. There is no CC API for "what dimension am I in", so this is config —
  but per fact (7) a successful `gps.locate()` already proves the constellation's dimension.

### 3. Station registration — `zone` = `os.getComputerID()`

The registrar **already** keys everything by the immutable `os.getComputerID()`. Reuse it: a
station's zone *is* its computer ID. No new names, no collisions, no cfg for the common case, and
the hub can `rednet.send` straight to it because **rednet addresses by computer ID**.

At boot the station resolves its position, in order:

1. `gps.locate(2)` — self-configuring, needs the constellation and an ender modem on a side (fact 8).
2. `pos=x,y,z` in `<station>.cfg` — the escape hatch; also the answer before the constellation exists.
3. Neither → **register no position** → the hub leaves it on the legacy `all` zone. Not an error.

Then: `rednet.send(hub, {kind="station_pos", computerID=..., pos=..., dim=..., range=...})`. The hub
persists `computerID → {pos, dim, range, label}` in the existing registry store, so a station that is
unloaded (or that loses GPS later) keeps its zone.

`idle_runner` changes by exactly one line of intent: `cfg.zone` defaults to `os.getComputerID()`
instead of `"all"` **when a position was registered**, else stays `"all"`.

### CORRECTION (2026-07-17, found by the whole-branch review — read this before touching zones)

**This spec originally claimed `idle_logic.presenceFor` was already correct and needed no change:
"a config-only upgrade". That claim was WRONG, and it would have shipped a feature that does
nothing.** `presenceFor` matched:

```lua
if msg.zone == "all" or msg.zone == myZone then
```

The `"all"` clause matches **unconditionally**. So a registered station answering to zone `5` would
*still* wake on the hub's floor-wide `zone="all"` broadcast — a player at the hub would wake the cage
1000 blocks away, which **is the original bug, untouched**. The in-world checklist step "walk to the
hub → the cage does not wake" is unpassable against the code this spec originally described.

The trap is that the property making the half-built branch safe (every station still matches `"all"`,
so none can be stranded asleep) is the *same* property that makes the finished feature useless. No
per-task review can see that fork — each verifies its own diff correctly. This is the cage lesson
repeating: **a faithful implementation of a wrong plan is a wrong program.**

**The fix has two halves and they must land together:**

1. **`idle_logic.presenceFor` drops the `"all"` clause** → `if msg.zone == myZone then`. This works
   because an unregistered station's zone *is literally the string* `"all"`, so it still matches the
   broadcast — no regression — while a registered station stops matching it. `test/test_idle_logic.lua`
   asserts the old contract and must be updated with it.
2. **The hub's `presence?` reply (`registrar()`) must answer a registered station with ITS zone**, not
   `"all"`. Miss this and a registered station's boot-time `queryPresence()` gets an answer it no
   longer matches — silently killing the boot resync that the entire "stations 1000 blocks out"
   argument rests on (see "objection is void" above). This means `presenceLoop`'s per-station state
   must be shared with `registrar()` exactly as `occupied` already is.

## Data flow

```
   player walks toward cage (1000 blocks out)
        |
        v  their own simulation distance loads the chunk
   [ cage computer ] boots -> startup -> idle_runner.deepSleep()
        |  advert drawn once; blocks on os.pullEvent (ZERO cost)
        |  presence? {zone=<computerID>}
        v
   ============================ rednet ================================
        ^                                        |
        |  presence {zone=<computerID>, present} v   (edges only, addressed)
   [ Hub ] --- stations: computerID -> {pos, dim, range}   (persisted)
        |  poll: isPlayersInRange (1) + getOnlinePlayers (1) + getPlayerPos * P
        |  match: pure Lua, O(stations), zero peripheral calls
        v
   [ player_detector ]   maxRange = -1  =>  server-wide oracle
```

## Error handling

| Failure | Behaviour |
|---|---|
| `getPlayerPos` throws (config off) | Loud once; per-station matching stops, but every registered station is still sent an addressed `presence` from the hub's own `occ` reading — degraded to legacy behaviour, not stranded |
| `getPlayerPos` returns `nil` (player left mid-poll, or out of a capped range) | Treated as absent. **The capped-range case is silent** — hence the blocking spike |
| Station never registers a position | Stays on the legacy `all` zone. Works exactly as today |
| Hub offline | No station wakes on approach (**already true today**); the local lever edge still wakes a station — the existing safety net |
| Player in another dimension | Filtered by `dim`. Fact (4): this is the one path where it is a real risk |
| Two stations at one position | Both wake. Correct, not a bug |
| Station moved without updating `pos` | Stale zone until it re-registers. `gps.locate` at every boot means a reboot fixes it |

## Testing

- **`test/test_proximity.lua`** (luajit, pure): `near` boundaries in x/z/y, dimension mismatch,
  `evaluate` over multiple stations/players, `edges` emitting **only** changes (the edge-only
  contract is what keeps rednet quiet), empty-player fast path, nil positions.
- **`test/spikes/gps_constellation.lua`** — the trilateration spike from fact (9), kept as a
  regression test of the constellation-geometry rule (lifted 4th host passes; coplanar and collinear
  fail). It is the reason we know one chunk is enough.
- **In-world checklist** (after merge+push, per the deploy loop):
  1. `hub test pos` up close and from 1000 blocks — **the blocking spike**.
  2. Walk to the cage → only the cage wakes. Walk to the hub → the cage does **not** wake.
  3. Walk away → cage sleeps and redraws its advert.
  4. Reboot the cage while standing at it → it wakes immediately (the `presence?` pull path).
  5. A station with no `pos` registered still wakes on the `all` zone (no regression).
  6. Fly to the Nether at the cage's x/z → the cage does **not** wake (fact 4).
  7. `hub` prints per-station edges; confirm rednet is quiet while nobody moves.

## Build order

0. **`hub test pos` spike.** Gate. Bad result → renegotiate config or switch to Plan B.
1. `lib/proximity.lua` + `test/test_proximity.lua` (pure, no hardware).
2. Hub: `station_pos` handler + persistence + `hub test pos`.
3. Hub: `presenceLoop` rewrite (legacy `all` kept intact).
4. Station: position resolution (`gps.locate` → cfg → none) + registration; `idle_runner` zone default.
5. `packages.lua` manifest update (`proximity` is a new `lib/` file — the deploy loop needs it, and a
   missing manifest entry is a class of bug this project has already paid for).
6. Merge + push, then the in-world checklist.

**The constellation is a build task, not a code task**, and it is not on this critical path: every
station works via cfg `pos=` without it, and picks up GPS the moment it exists. Four computers in
the hub's force-loaded chunk, each running `gps host <x> <y> <z>`, three at the chunk's corners and
**one lifted ~40 blocks** (fact 9).

## Open questions / follow-ups

- **Can a cable carry an ender modem?** Untested (fact 11). Per fact (8) we don't want it — but if
  it works it changes the station wiring guidance, so it's worth a 2-minute in-world check.
- **Peripheral side-pressure** (owner's real problem) is solved *outside* this spec: one wired modem
  on the computer + cable moves monitor, disk drive, and anything else off the computer's sides
  entirely, and a **Redstone Relay** (fact 12) adds six redstone sides anywhere on the network. The
  ender modem stays on a side (fact 8). That is a station-wiring change, not a proximity change —
  its own task.
- **`hub_version` / ping** (already in `todo.md`) bites again: an old hub will silently ignore
  `station_pos` and the station will look like it registered. Not blocking; worth the reminder.
