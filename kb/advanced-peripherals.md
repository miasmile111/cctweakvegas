# Advanced Peripherals 0.7 — reference (server findings)

Docs: https://docs.advanced-peripherals.de/0.7/ · Our target: **CC:Tweaked, MC 1.21.1**.
Peripherals attach to a computer over a **wired modem** and are found with
`peripheral.find("<type>")`. Types below use the **1.21.1+** block/registry names.

> **Version gotchas (1.21.1) — read first**
> - Player Detector block name is `player_detector` (was `playerDetector` pre-1.21.1).
>   `peripheral.find` uses the registry name — confirm in-world with `peripheral.getNames()`.
> - **Redstone Integrator was REMOVED in 1.21.1-0.7.50b** — superseded by CC:T's own
>   **Redstone Relay**. Do NOT design around AP's integrator; use the CC:T relay for
>   extra/remote redstone sides. (See cc-lua skill / tweaked.cc for the relay API.)
> - Signatures below are from the 0.7 docs; verify live before committing (docs lag the mod).

---

## Player Detector — THE proximity find (drives our idle model)

Centralize on the **hub** (always chunk-loaded): one detector = one always-running proximity
loop for the whole floor. Stations stay asleep; hub tells them who's near which zone.

Block: `player_detector`. Range cap via config `playerDetMaxRange` (**default `-1` = unlimited** in
1.21.1; verified not capped on Atlas — see Open questions).

> **EVERY method below is `@LuaFunction(mainThread = true)`** — *all* of them, including the "cheap"
> `isPlayersInRange`. Verified by reading `PlayerDetectorPeripheral.java` (AP `release/1.21.1`). Each
> call parks your coroutine ~50ms; see `[[main-thread-peripheral-calls-cost-a-tick]]`. **The call
> count is the budget** — this is why `hub.lua` polls `getOnlinePlayers` + `getPlayerPos` **per
> player** (O(players)) rather than a query per station (O(stations)).
>
> **`getPlayerPos` is the odd one out and needs care:**
> - It **throws** if `enablePlayerPosFunction = false` → always `pcall` it. Unguarded in the hub's
>   loop, it kills the hub and with it the whole floor.
> - It is the **only** query that does NOT dimension-filter. Range/box queries filter for free
>   (`CoordUtil`: `if (range != -1 && player.level() != world) return false`), but at `maxRange = -1`
>   with `playerDetMultiDimensional` (default true) `getPlayerPos` returns players in **any**
>   dimension — so a player at the same x/z in the Nether will wake an Overworld station unless you
>   check the `dimension` field yourself.
> - `enablePlayerPosRandomError` (default false) fuzzes positions past 100 blocks by up to 1000.
>   `morePlayerInformation` (default true) is what supplies `dimension`.
> - **AP ranges are SQUARES, not spheres:** `|x-bx| <= range && |z-bz| <= range` (Chebyshev in x/z)
>   plus a feet/eye y rule. `range 8` is a 17×17 column.

**Methods**
- `getPlayerPos(username) -> table|nil` (alias `getPlayer`) — full player object:
  `{ uuid, name, dimension, x, y, z, yaw, pitch, eyeHeight, health, maxHealth, airSupply,
     respawnPosition, respawnDimension, respawnAngle }`
- `getOnlinePlayers() -> table` — all online player names (0.7r+).
- `getPlayersInRange(range) -> table` — names within `range` of the detector.
- `getPlayersInCoords(posOne, posTwo) -> table` — names inside the box between two `{x,y,z}`.
- `getPlayersInCubic(w, h, d) -> table` — names in a cuboid centered on the detector.
- `isPlayerInRange(range, username) -> boolean`
- `isPlayerInCoords(posOne, posTwo, username) -> boolean`
- `isPlayerInCubic(w, h, d, username) -> boolean`
- `isPlayersInRange(range) -> boolean` — ANY player in range (cheap "zone occupied?").
- `isPlayersInCoords(posOne, posTwo) -> boolean`
- `isPlayersInCubic(w, h, d) -> boolean`

**Events** (`os.pullEvent`) — server-wide, NOT position-gated:
- `playerClick` → `username, device` (player right-clicks the detector block).
- `playerJoin` → `username, dimension`
- `playerLeave` → `username, dimension`
- `playerChangedDimension` → `username, fromDim, toDim`

**Design note:** the box/cubic queries let ONE hub detector define many named "zones" (one per
station) by coordinate. Poll `getPlayersInCoords` per zone, or `isPlayersInCoords` for a boolean
occupancy check. No per-station sensor needed. Proximity → hub rednet-wakes that station.

---

## Inventory Manager — direct player-inventory payout (diegetic prize actuator)

Binds to a player via a **Memory Card** item the player assigns to themselves, inserted into the
manager block (one card per manager). Lets a station **give/take items straight to the player's
inventory** — a real diegetic payout without hoppers/dispensers.

**Methods**
- `addItemToPlayer(direction, item) -> number` (count added)
- `removeItemFromPlayer(direction, item) -> number` (count removed)
- `getItems() -> table` · `getArmor() -> table`
- `getItemInHand() -> table` · `getItemInOffHand() -> table`
- `getOwner() -> string|nil` · `isPlayerEquipped() -> boolean` · `isWearing(slot) -> boolean`
- `getFreeSlot() -> number` (-1 if full) · `isSpaceAvailable() -> boolean` · `getEmptySpace() -> number`

**Item table:** `{ name, count, maxStackSize, displayName, slot, tags, nbt }`.
`direction` is the side of the manager the source/target container sits on.

**Design note:** candidate for the "diegetic sink" (Option B) — pay winnings as physical items
(coins/tokens). Also note it exposes a player↔card binding we could reuse for identity, but our
card model is a floppy in a disk drive; keep them separate unless we unify later.

---

## Chat Box — announcements & command input (no monitor needed)

Broadcast or DM chat, push toasts, and READ player chat as an event. Good for hub-wide
"COME PLAY" barks, balance replies, and text commands ("!balance", "!issue <name>").

**Methods** (all `-> true | nil, errString`)
- `sendMessage(msg [, prefix, brackets, bracketColor, range, utf8]) ` — broadcast (default prefix "AP").
- `sendMessageToPlayer(msg, username [, ...]) ` — DM.
- `sendToastToPlayer(msg, title, username [, ...]) ` — toast popup.
- `sendFormattedMessage(json [, ...])` / `sendFormattedMessageToPlayer(json, username [, ...])` — raw JSON text component.
- `sendFormattedToastToPlayer(msgJson, titleJson, username [, ...])`
- `range` param limits who hears it (proximity announcements per station!).

**Event:** `chat` → `username, message, uuid, isHidden, messageUtf8`. Lets the hub accept
typed commands diegetically (still not a gameplay GUI — chat, not a terminal).

---

## Environment Detector — world state (ambiance / scheduling)

Read time, light, weather, biome, dimension. Use for "neon only at night", weather-driven
attract themes, or gating events. **No events** — poll it.

**Methods:** `getTime()->n`, `getBiome()->s`, `getDimension()->s`, `getDimensionPaN()->s`,
`getBlockLightLevel/getDayLightLevel/getSkyLightLevel()->n`, `getMoonId()->n`, `getMoonName()->s`,
`isRaining/isSunny/isThunder()->bool`, `isDimension(d)->bool`, `isMoon(id)->bool`,
`isSlimeChunk()->bool`, `listDimensions()->table`, `getRadiation*` (Mekanism only),
`scanEntities(range) -> table` (entities near the detector — mobs too, not just players).

---

## Rest of the AP 0.7 catalog (not yet deep-dived — know they exist)

Reach for these when a problem smells like a peripheral already solves it:

**Peripherals**
- **Block Reader** — read an adjacent block's state/NBT (contraption/redstone introspection).
- **NBT Storage** — persist arbitrary NBT data on a block (alt to disk files for hub state).
- **Geo Scanner** — scan surrounding blocks/ores in a radius.
- **Energy Detector** — measure FE/energy throughput (Create/Powah power gating).
- **AR Controller** (+ **AR Goggles** item) — draw a HUD overlay in a player's vision
  (non-diegetic — clashes with our "monitors only" principle; note but avoid for gameplay).
- **ME Bridge / RS Bridge** — AE2 / Refined Storage access (not installed unless those mods are).
- **Colony Integrator** — MineColonies (irrelevant here).

**Turtles:** Chatty / Chunky / Environment / Player / Geoscanning, + Metaphysics automata
(Weak/Husbandry/End/Overpowered). Chunky turtle = mobile chunkloading if ever needed.

**Items:** AR Goggles, **Chunk Controller** (chunk loading control — relevant to keeping the hub
loaded), Computer Tool, **Memory Card** (player binding for Inventory Manager), Pocket Computers.

**Mod integrations present:** Minecraft, Create, Botania, Draconic Evolution, Immersive
Engineering, Integrated Dynamics, Mekanism, Powah, Storage Drawers.

---

## Open questions to verify in-world
- [ ] Exact registry names via `peripheral.getNames()` (confirm `player_detector` vs `playerDetector`).
- [x] **`playerDetMaxRange` — ANSWERED 2026-07-17. It is NOT capped on Atlas** (`hub test pos` returns
      exact positions for a player 500+ blocks out; a 100 cap would have returned nil). **And the
      default is `-1` (unlimited) in 1.21.1, not 100** — `defineInRange("playerDetMaxRange", -1, -1,
      Integer.MAX_VALUE)`. The 100 in this file's earlier note was the **pre-1.21 default**, and
      chasing it wasted real design time: it does not cap our zones, and at -1 the hub's one detector
      is a **server-wide oracle**, which is what makes per-station proximity possible at all.
- [ ] Which of these peripherals are actually enabled/craftable on the server.
- [ ] CC:T Redstone Relay API (the AP integrator's replacement) — pull from tweaked.cc.
