# TODO

## Deploy & identity system — DONE (2026-07-16)

The whole code-delivery + station-identity backbone is built, pushed, and verified in-world.
Spec: `docs/superpowers/specs/2026-07-16-station-identity-and-deploy-design.md`.

- **`update <pkg>`** (`src/update.lua`) — self-updates (relaunches new copy in one run), pulls a
  package's files from `src/packages.lua` (cache-busted `http.get`, overwrites), registers with
  the hub → unique label (`slot2` / `slot2+pong1`), and writes an auto-run `startup` supervisor.
- **Hub v0 registrar** (`src/hub.lua`) — rednet `ccvegas` service; persistent `computerID→{pkg:n}`
  table; idempotent, collision-free naming. Hosts hostname `hub`. **Always-on** (force-load it).
- **Installer floppies** (`src/mkinstaller.lua`) — master tools disk (`/disk/update slot`) or a
  per-package auto-install-on-reboot disk. Web fetch of `update.lua` happens once, ever.
- **Auto-run supervisor** — station boots into its game + self-heals (crash / Ctrl+T /
  chunk-reload). Break-out: hold a key at boot, Ctrl+T, or a key in the 3s post-exit window.
- **Fail-loud preflight** — missing drive/modem = hard stop; hub offline = loud REGISTRATION
  FAILED (files still install).

## Idle / lag model + station framework — DONE (2026-07-16)

Built, deployed, verified in-world. Then generalized so every station inherits idle-safety.

- **Hub-driven presence** — the hub has an Advanced Peripherals **Player Detector** and runs the
  *only* forever-loop; it edge-broadcasts `presence` over rednet. Stations deep-sleep on
  `os.pullEvent` (zero cost) and wake on presence or a local lever edge. **Pull-able presence**
  (`presence?` query) syncs boot-while-occupied + lever-wake-outside-range.
  Spec: `docs/superpowers/specs/2026-07-16-idle-lag-model-design.md`.
- **Shared `lib/idle_runner.lua`** — owns deep-sleep/wake/presence and draws `<name>_advert`. A
  station is now just a play file + a `<basename>_advert.lua`. `src/` reorganized into
  `hub/ slot/ pong/ lib/` (deploy flattens by name, so `require()` is unchanged). **slot** and
  **pong** both run on it — pong gained idle-safety it never had.
  Spec: `docs/superpowers/specs/2026-07-16-station-folders-and-idle-runner-design.md`.
- Advanced Peripherals capabilities catalogued in `kb/advanced-peripherals.md`.
- Idle state = a static `COME PLAY / GET MONEY` advert (drawn once, zero cost); present = the game.
- (Not measured: exact tick-cost numbers — qualitatively confirmed idle stations cost ~nothing.)

## Known gaps / parked

- **No station reset/deregister.** `.installed` accumulates (merge-only) and the hub registry
  reserves `computerID → instance` forever (idempotent by immutable ID). No uninstall/reset command;
  `update <pkg>` just relabels from that run's packages. Harmless while self-contained (no
  collisions); revisit if recycling machines. Would need a hub `deregister` msg + a local `reset`.

## Hub economy — core loop DONE + in-world verified (2026-07-16). Currency = **M-Bucks (MB)**

Vertical-slice step 1 complete. Full reference: **`kb/economy.md`** (read it before extending the economy).
Currency is **M-Bucks** (full *Mia-Bucks*, abbrev **MB**) — the unit of every balance/stake/payout.
Spec: `docs/superpowers/specs/2026-07-16-hub-economy-design.md`;
plan: `docs/superpowers/plans/2026-07-16-hub-economy.md`. Bet-and-risk slot on a hub-authoritative
ledger, layered so a 2nd game reuses it: **core** (`lib/ledger` pure · `lib/card` · `lib/wallet`
+outbox) → **SP gateway** (`lib/sp_econ`) → tiny per-game payout (`slot/slot_pay`). All 8 code tasks
passed per-task review + a whole-branch review (deploy/package completeness + protocol end-to-end PASS).

- [x] **Member card read/write** — `lib/card` reads/writes floppy `{ id, score-mirror }`; no card = anonymous free-play.
- [x] **rednet economy protocol** — `bet{id,stake}→bet_ok|bet_deny`, `credit{id,delta}→balance`,
      `query{id}→balance`, `mint{name,balance}→minted`. Hub persists the ledger (`ledger.tbl`), sole writer.
- [x] **Slot payout model** — fixed stake, per-symbol paytable, triple-seven jackpot (`slot_pay`).
- [x] **Show balance** — economy header (player · balance · stake · win / INSUFFICIENT / FREE PLAY).
- [x] **Admin card issue** — `issue <name> [balance]` mints ledger id + writes the floppy (hub needs a drive).
- [x] **Admin card top-up** — `issue add <amount>` moves the balance of the id already on the inserted
      card (delta, may be negative). Sign picks the primitive (`+`→`wallet.creditNow`, `−`→`wallet.debit`)
      so a claw-back can't go below zero. No hub change → no reboot. Spec:
      `docs/superpowers/specs/2026-07-17-issue-topup-design.md`. **In-world verification pending.**
- [x] **In-world verification** — deployed; mint→insert→bet→win/lose→insufficient→eject(anon)→
      hub-offline-outbox all confirmed working. Hub + slot stations have disk drives.

## Lua UI deepdive + slot-machine finishing touches — DONE (2026-07-16) ✓

(Was the active build 2026-07-16; everything below shipped and was verified in-world. The one item it
did **not** cover — the slot's idle advert screen — is now the OPEN phase's top item.) Two intertwined
threads:
- **Lua UI deepdive + workflow** — a patterns/toolkit pass on monitor UIs (the `lib/subpixel` canvas,
  layout, text, headers, advert screens) + a smoother build/iterate loop. Start from the cc-lua
  **`kb/monitor-ui.md`**. New behavior → brainstorm first.
  - **DONE — resolution lesson** (`docs/monitor-resolution-lesson.html`): interactive datasheet of the
    cell (6×9) / subpixel (2×3, 2-colour) / real-px model, taught through `slot.lua`. Verified: glyph
    6×9 (CraftOS-PC gfxmode + CC font), teletext behaviour (`src/lib/subpixel.lua`).
  - **DONE — mockup tool** (`tools/monitor-mockup.html`): browser subpixel pixel-art editor. Paint a
    whole-monitor screen freeform; a live `encodeCell` preview shows the 2-colour-per-cell truth;
    RGB-editable palette; tagged cell-grid text regions; JSON+PNG export (JSON = Claude's source of
    truth → regenerate Lua). Spec + plan in `docs/superpowers/`. **Iterate loop:** user draws → exports
    JSON → Claude reads it → generates `subpixel.lua` draw code. NOT in the `src/` deploy loop.
  - **DONE — resolution formula exact.** Block→cell pulled from CC `ServerMonitor.rebuild`; slot
    1×2 @0.5 = **15×24** (not 15×21). See `kb/monitor-resolution.md`. MB `$`→`MB` swap shipped (a05efce).
  - **DONE — slot v3 built** (spec `docs/superpowers/specs/2026-07-16-slot-v3-design.md`, plan
    `docs/superpowers/plans/2026-07-16-slot-v3.md`). Rebuilt `slot.lua` to fixed 15×24 bands: card
    header, `WIN:`+amount, red top/bottom frame bars, **solid-black reel window showing 3 symbols per
    reel**, side + bar bulbs, stake row with purple/gray bg art. Reuses GRAD gradient + `bulb()`; all
    text white; header/WIN text bg bound to the animated gradient slot. **3 selectable stakes**
    ($10/$25/$100) via **monitor_touch** — tap the on-screen stake labels; persists across spins,
    resets to $10 on wake. Economy stake-variable: `slot_pay.eval(result,stake)`+`STAKES`,
    `sp_econ.tryBet(stake)` captures `stakedStake`, `settle` pays against it. Tests 15/15; reviewed.
    - **Iteration after first in-world screenshot** (owner feedback): reel window was 1-symbol + showed
      the gradient (should be **black, 3 symbols**); stakes were an **unwired redstone cycle button**
      (switched to **touch** — owner drew them as buttons). Fixed both; layout translated more faithfully.
      Verified offline by rendering the subpixel layer to PNG (sim reuses real `subpixel.lua`+symbols).
    - **Operational v3 build DONE** (from `tools/slot-preview.html`, the approved on-screen design;
      built from `docs/mockups/slot-v3.json` → mockup(2)). New `src/lib/pixelfont.lua` (pure, unit-tested):
      the **WIN:** label bitmap + **slashed big-number font** (owner-drawn "0", 1-9 extrapolated).
      `slot.lua` rewritten: header (native CC text) row 2, WIN: + **count-up** amount (0→payout over
      ~1s), top red bar, **3×3 reel** rows 11-19 (only middle row black, top/bottom on gradient),
      bottom red bar, **stake buttons** rows 23-24 (native "$10/$25/$100" cell-text in the top cell,
      full-magenta selected / gray). **Celebration:** bars-only yellow flash on win. **Outcome overlay:**
      green(WIN)/red(Loss) over the stakes. **Stakes = monitor_touch** (tap the button; persists,
      resets to $10 on wake). `pixelfont` added to `packages.lua`. Tests 24/24; whole-file review clean.
    - **IN-WORLD VERIFIED (2026-07-16)** — owner confirmed "it works!". Post-verify fixes shipped:
      (a) stray corner bulb — side bulb lanes now start below the top red bar; (b) **reel rubber-band** —
      the reel snapped `pos=0` from an arbitrary position, so after `SYMBOL_PX` changed it jumped a
      symbol back; now `slot_logic.stepReel` **eases forward into the nearest aligned stop** (pos a
      multiple of `NUM_SYMBOLS*symbolPx` → final centred), no snap (tests updated). Free-play shows a
      static "0" by design (no card = no payout); insert a card to see the count-up.
    - **Workflow codified (owner's request):** the mockup → live `tools/slot-preview.html` preview →
      Lua → **offline PNG verify** → deploy loop is now the **golden standard** in
      `kb/monitor-ui-workflow.md` (+ SKILL pointer). SKILL's hard-rule reconciled: **`monitor_touch`
      IS diegetic** (physical in-world interaction), ban is keyboard/terminal-GUI only.
    - **Post-verify polish shipped:** reel-stop eased (no rubber-band); **currency reverted to `$`**
      (M-Bucks/MB retired — header shows `id: $bal`); leftmost red-bar bulb removed (it straddled the
      canvas-edge cells → `encodeCell` squashed it — see `kb/monitor-ui.md`); selected stake = **yellow**.
    - Parked slot polish: celebration art beyond the bar flash; text colours; **advert screen** (see NEXT).

## Cage — v1.1: stutter + responsiveness + edge gradient (2026-07-17) ✓

In-world verified via the new `cage debug`. All three fixed; the kiosk GUI was reached for the first
time this session (see the proximity section below for why it hadn't been).

- **The monitor stutter was never the redstone.** Monitors don't read redstone at all, and terminal
  writes are computer-thread (~free). Every `inventory` call is `mainThread = true` = **~50ms of
  frozen play loop**, and `loadDroppers` re-listed the vault *per dropper*: 8 calls ≈ 400ms per tap.
  One listing + a local slot mirror → 9 calls to 5. Measured after: `stock=26ms debit=19ms
  load=190ms`. Full rule + the trap in the fix: `[[main-thread-peripheral-calls-cost-a-tick]]`.
- **20x never cost more than 5x** (225ms vs 226ms) — the call count is per-dropper, not per-item. The
  "worse at 20x" feel was the longer *shower* (5 cycles vs 2), not a longer stall.
- **Responsiveness:** the green press-flash was *set* at ~45ms but not *drawn* until `withdraw()`
  returned at ~226ms. Now renders at the point it's decided → 226ms to ~45ms perceived. Deliberately
  NOT hoisted above the debit: a denied tap would flash "paid" at a player who wasn't.
- **The left gradient column read black** between the red bars. Not the layout — canvas and render were
  provably symmetric. The outer gradient columns were **1 subpixel** where every divider was 2, and a
  lone subpixel at the extreme edge doesn't survive the monitor's edge (the money band was fine because
  its edge cell is *uniform* gradient, not a half/half split). All five columns are now 2 wide.
- **`cage debug`** — per-tap timings + frame gaps >100ms on the computer's terminal. Idle gaps of
  121–200ms show up on a quiet floor; owner calls these server hitches, not worth chasing.
- **Not done:** ~250ms per tap remains (4 pushes × ~50ms). Next lever is fanning the pushes across
  coroutines (~250ms → ~100ms), but `parallel` eats the tick timer and touch events unless foreign
  events are stashed — see `[[event-pump-reentrancy]]`.

## Cage (diegetic sink) — v1 shipped + **IN-WORLD VERIFIED (2026-07-17)** ✓

The `$` exit. A kiosk where a member card's `$` becomes real metal (droppers spitting ingots on the
floor) and metal becomes `$`. Bidirectional, flat rate, hub-authoritative.
Spec: `docs/superpowers/specs/2026-07-16-diegetic-sink-cage-design.md`;
plan: `docs/superpowers/plans/2026-07-16-diegetic-sink-cage.md` (all 10 tasks done, per-task +
whole-branch review clean). Owner-approved layout: `tools/cage-preview.html` (clickable; it IS
the source of truth for the built UI).

**What shipped:** `src/cage/` station (`cage.lua` play loop + UI, `cage_rates`/`cage_vault` pure
logic, `cage_hw` peripheral I/O, `cage_symbols` ingot sprites, `cage_advert` idle face) on the
existing `idle_runner` framework, plus `lib/cage_econ.lua` (card-session gateway, sibling of
`sp_econ`). Deploy: `cage` package added to `src/packages.lua` (manifest verified against the tree).
All 10 plan tasks landed; per-task + whole-branch review clean.

**Three bugs stood between "all reviews clean" and a working machine — all found AFTER the plan was
green, and none catchable by a per-task review.** They are the session's real lesson: a faithful
implementation of a wrong plan is a wrong program.
1. **The pulse never fired** (`[[redstone-pulse-needs-a-yield]]`) — `setOutput(true)` then `(false)`
   in one tick is a silent no-op; **the spec and plan mandated it verbatim**. Every withdrawal would
   have debited the card and dropped nothing, and `getOutput` reads CC's internal state so the machine
   could not have told you. Caught by the whole-branch review reading the CC:Tweaked source.
2. **The shower lost ~1 tap in 3** — the queue decremented on a falling edge that had never risen.
   Worse: `cage test drop` pairs its edges, so **the diagnostic reported success while the game shred-
   ded taps**. Fixed with a `pulsed` flag + a `pulseOff()` on entry (CC persists output past exit).
3. **The ender modem was never opened** (`[[open-every-modem]]`) — "prefer wired" opened the peripheral
   cable, which has no hub on it → `REGISTRATION FAILED — HUB OFFLINE` against a healthy hub. **The hub
   had the same bug**, so fixing only the station would have changed nothing.

**Hardware self-discovers** (`[[station-hardware-discovery]]`), so cage #2 is wire-it-and-run.

**Tuning knobs:** `cage_rates.DENOMS` (denomination table — item, `$` value, label; **≤6 entries**,
see the CEILING note in the file — a 7th collides with the idle advert's rate-table rows vs. the
bottom bar); `cage_rates.QTYS = {1, 5, 20}` (the withdraw multiplier ladder, resets to 1x on wake);
dropper count (**any count ≥2**, all on one shared redstone line, never the modem's side — more
droppers = faster shower drain; the first real build uses 4); shower cadence (tick-driven via
`cage_vault.pulseLoads` on a **6-tick phase cycle** — 2 high, 4 low = 0.3s/item/dropper, pacing the
dropper's 4-tick rising-edge cooldown. On/off MUST straddle a yield and it must never become a
blocking `sleep()` loop — see `[[redstone-pulse-needs-a-yield]]`, `[[event-pump-reentrancy]]`).

**Hardware is DISCOVERED, not configured (2026-07-17).** Network names are **not stable across
identically-built cages** — CC hands out `<type>_<n>` from the lowest free index on that network and
any attach/detach burns a number (the first real build's droppers came up **1-4, not 0-3**). So a
cage finds its own kit by TYPE at boot: droppers = every `minecraft:dropper`; **deposit = the
lowest-named non-dropper inventory** (attach the player-facing one first), vault = the next; monitor
= the one that is **36×24 @0.5** (by SIZE, not `peripheral.find("monitor")` — a cage with two
monitors attached was a coin flip). A standard build needs **no `cage.cfg` at all**.

> **`cage.cfg` exists because `update cage` OVERWRITES `cage.lua`.** It is not in the package file
> list, so it survives a push — it is the ONLY place per-station wiring belongs. Never put wiring in
> `cage.lua`'s config block; the next `update` deletes it. cfg always wins over discovery. `side` is
> the one thing that can't be discovered.

**`cage test`** — the setup tool. `cage test` lists attached peripherals, every monitor's size, the
resolved config **and where each value came from** (`(auto)` / `(cage.cfg)` / `(NOT FOUND)`), and the
vault's contents; it runs *before* the boot hard-stops so it can diagnose a cage that won't start.
`cage test drop <metal> [qty]` showers real metal **debiting nobody** — the one check only the server
can answer. Fails loud (not a crash) on a grey modem, >2 non-dropper inventories (a hopper would
otherwise sort ahead of the barrels and become the deposit box), or a wrong-sized `monitor=`.

**Verified in-world setup (first real cage):** Sophisticated Storage barrels work — they expose
`inventory`, so `list()`/`pushItems()` need no special handling. `barrel_0` = deposit, `barrel_1` =
vault, `dropper_1..4`, modem on the **right** (kept reachable), redstone out on **back**, drive on
the left, monitor `monitor_0`.

**In-world verification: PENDING.** Post-merge+push checklist (per the plan's post-plan section):
walk-up wake → card insert → mixed deposit incl. junk → withdraw each denom at 1x/5x/20x →
spam-tap overlap → vault-empty deny → insufficient deny → hub-offline both directions (fail-closed
withdraw, outboxed deposit) → eject mid-shower.

- **Rates (flat, symmetric):** copper $25 · iron $100 · gold $250 · diamond $1000. `cage/cage_rates.lua`.
- **Hardware:** computer + advanced monitor **2×2 @0.5 = 36×24 cells** + disk drive + wired modem +
  deposit chest + vault chest + 2–3 droppers (each a modem, all sharing ONE redstone line).
- **Vault fed by deposits** — the metal players cash in IS the metal others cash out. Empty ⇒ deny.
- **Kiosk, no confirm:** qty (1x/5x/20x) + tap a metal = immediate debit + shower. Spam = overflow.
- **Core additions that pay forward to `mp_econ`:** `wallet.debit` (the honest debit primitive — an MP
  pot is "debit each player, credit the winner"; the trading station is the same pair), `credit_deny`
  (**closes latent F2**), `pixelfont` scale + the owner's two `$` glyphs.
- **Known MP blocker, named not built:** `card.read()` takes the **first** drive with a disk.
  Single-card-per-station is baked in; `mp_econ` needs `card.readAll()`/`card.read(drive)`.
- **Card-session extraction is a rule-of-three call** — `sp_econ` + `cage_econ` are instances 1 and 2;
  extract `lib/card_session.lua` when `mp_econ` makes three.

### UI patterns settled here (reusable — see also `kb/monitor-ui-workflow.md`)

- **The palette, not screen space, is the scarce resource.** 16 slots, global to the monitor: cage
  spends 4 on the gradient, 10 on content, 2 free. A station affords **one** bevel ramp shared by all
  its buttons — which makes a bevel a station's signature, not decoration.
- **Bevel button** (`drawBevel`, light top/left + dark bottom/right, swapped when pushed). **Steel is
  the only true ramp in CC's stock 16** (white 240 / lightGray 153 / gray 76 = +87/−77): the greens
  are 161/132/17 (no highlight) and red 114 / brown 106 are 8 apart (no shadow). Costs no slots.
  Corner cells see 3 colours and squash — a 2-cell price, accepted.
- **Delta-tinted counter** — a rolling number tints by direction: **gold up, pink down**, white at
  rest. The tint is the feedback. **Pink, not red:** stock red is luminance 114 against the gold
  band's ~118, so a red number vanishes on half the drift, and a cell holds 2 colours so no outline
  can save it.
- **`monitor_touch` has no release event** — every "pressed" look is a timed flash (`FLASH_TICKS = 8`).
- **Two `$` glyphs = two SIZES, not two scales** (`pixelfont.SIGN_SM` 5×10 / `SIGN_LG` 7×14). `scale`
  doubles pixels; hand-drawn detail beats doubling. Scale stays orthogonal.
- **Open question for in-world verification:** do server-thread peripheral calls (`chest.list`,
  `pushItems`) pump the event queue and eat a pending tick timer? tweaked.cc is silent on timing.
  `cage.lua` re-arms the timer after every touch handler to guarantee liveness regardless.

## Per-station proximity — BUILT + LIVE 2026-07-17 ✓ (GPS constellation up; full checklist not walked)

> **Status, precisely.** Merged, pushed, deployed. The **GPS constellation is built and working** —
> `gps locate` returns exact integer positions, so stations self-locate and register with the hub.
> Default wake radius **10** (owner-set once it was live and felt, not guessed). What has **not** been
> ticked off item by item is the wake checklist at the end of this section — above all *"walk to the
> hub → the cage does NOT wake"*, which is the whole point of the feature. Do that before the floor
> opens; it is one walk.

The floor was ONE zone: `hub.lua` broadcast `{zone="all"}` and every station matched, so a player at
the **hub** woke **every** station and a player at the **cage** woke nothing. (That is why the cage
sat on its advert for the whole v1 session — its GUI was never reached.) Now the hub is a
**position oracle** and each station wakes on its own.
Spec: `docs/superpowers/specs/2026-07-17-per-station-proximity-design.md`;
plan: `docs/superpowers/plans/2026-07-17-per-station-proximity.md`. All 6 tasks + per-task reviews +
a whole-branch review; three Important findings fixed (below).

**The design, and why it is not the obvious one.** A `player_detector` per station was the first
answer and it was wrong: it is **O(stations)** — 10 slots = 10 main-thread calls/sec forever, 100 =
100 — and it *degrades deep sleep*, because a station with a local detector must poll instead of
blocking. Instead the hub asks `getOnlinePlayers()` + `getPlayerPos()` **per player** — **O(players),
independent of station count** — and matches zones in pure Lua (`lib/proximity.lua`, 53 unit tests).
Stations keep a true zero-cost `os.pullEvent` deep sleep. Owner's call; he was right.

**Cost:** `2 + P` main-thread calls per 0.3s poll (P = online players), never per station. P is every
player online *server-wide* (at `playerDetMaxRange = -1`) — fine for a friends floor; revisit past
~20 concurrent. If `proxOff` latches it drops to 1 call/poll.

**Stations self-locate.** `gps.locate()` at boot → `pos=x,y,z` in `<station>.cfg` → neither = stay on
the legacy `"all"` zone (not an error). Zone = `os.getComputerID()`: already unique, already the
registrar's key, and rednet addresses BY computer ID, so per-station presence needs no broadcast.

**The GPS constellation is a BUILD task, not code — and it is cheap.** CC ships `gps host <x> <y> <z>`;
we wrote none of it. **Four computers in the hub's force-loaded chunk: three at the chunk's corners,
ONE LIFTED ~40 blocks off their plane.** Measured (`test/spikes/gps_constellation.lua`, 13 tests):
CC's GPS distances are **exact** (no measurement noise), so there is no dilution of precision and
horizontal spread buys **nothing** — a one-chunk constellation is exact out to 100,000 blocks with a
+40y lift, and even +5y clears 20,000. Four **coplanar** hosts fail at ANY distance (trilateration's
mirror is unresolvable); collinear fails too. **The ender modem must stay on a computer SIDE** —
`gps.locate` scans `rs.getSides()` only, never the cable, so moving it onto the network kills GPS.
Until the constellation exists, `gps.locate(2)` burns its full **2s on every station boot** (the cage
avoids this via `pos=` in cage.cfg; the slot has no cfg and pays it) — a good reason to build it.

**Verified in-world:** `hub test pos` returns exact positions for a player **500+ blocks** away →
`enablePlayerPosFunction` is on and `playerDetMaxRange` is NOT the old 100 cap.
`enablePlayerPosRandomError` is **off too** — `hub test pos` run twice while standing still gave
identical coordinates, and the error is re-rolled per call, so that is proof (no F3 compare needed).
**All three config values confirmed clean; Atlas is on the 1.21.1 defaults.** The hub still warns once
if `getPlayerPos` returns nil for an *online* player — the only tell that the range is capped, and
otherwise perfectly silent.

**Three Important findings, none catchable by a per-task review — the session's real lesson.**

1. **The plan itself made the feature a no-op**, and every task would have passed review building it.
   The spec claimed this was "a config-only upgrade: `presenceFor` unchanged". But `presenceFor`
   matched `msg.zone == "all"` **unconditionally**, so a station registered to zone 5 *still* woke on
   the floor-wide broadcast — a player at the hub still woke the cage 1000 blocks away, **the exact
   bug the feature exists to kill**. The plan's own checklist step ("walk to the hub → the cage does
   not wake") was unpassable against the code the plan specified. The trap: the property that makes a
   half-built branch safe (everything still matches `"all"`, nothing stranded) is the **same** property
   that makes the finished feature useless. Fix: `presenceFor` drops the `"all"` clause — an
   unregistered station's zone *is literally* `"all"`, so it still matches (no regression) while a
   registered one stops. **Coupled half:** the hub's `presence?` reply must then answer a registered
   station with ITS zone, or the boot resync the whole 1000-blocks-out design rests on dies silently.
2. **Adding GPS at boot lost lever pulls.** `slot.lua` is the only station with a wake lever. Its zone
   went auto, so every boot ran `gps.locate(2)` *before* `deepSleep` sampled the lever — and CC's
   `gps.locate` is a bare `os.pullEvent()` loop that **discards** the redstone event. Worse, `prevLvl`
   then sampled the lever **already high**, so `leverRose(15,15,13)` was false forever: dead until the
   player toggled twice. Stash/re-queue does NOT fix it (it saves the event, not the baseline).
   Fix: sample the lever *before* the blocking calls and re-check on entry — **pull, don't trust push**,
   the same shape as `queryPresence()`. That first fix then caused a *spurious* wake on the ordinary
   "walk up, spin, leave" path (a MC lever is a TOGGLE and stays high; the presence wake path never
   updated the baseline) → made it a **one-shot** for the first sleep after boot only.
3. **`proxOff` bricked every registered station.** On a `getPlayerPos` throw the hub latched and fell
   back to the `"all"` broadcast — which registered stations now *ignore*. No pushes, and no pulls
   either (`zonePresent` never populated). The cage has no lever: **bricked**, while the hub printed
   "Falling back to the floor-wide 'all' zone" — a promise it could not keep. Fix: drive registered
   stations from the hub's own `occ` (genuinely the pre-feature behaviour, delivered to the zone they
   actually listen on).

**Reusable facts pulled from mod source (do not re-derive):**

- **Every AP `player_detector` method is `mainThread = true`** — *all* of them, including the "cheap"
  `isPlayersInRange`. See `[[main-thread-peripheral-calls-cost-a-tick]]`. Count the calls.
- **`playerDetMaxRange` defaults to `-1` in 1.21.1, not 100** (pre-1.21 default — the KB's old
  unverified item was chasing a stale number). At -1 the hub's detector sees the **whole server**.
- **`getPlayerPos` does NOT dimension-filter** (range/box queries do, for free). The hub must — a
  player at the same x/z in the Nether would otherwise wake the floor. It is gated three ways:
  `enablePlayerPosFunction` (throws if off), `enablePlayerPosRandomError`, `morePlayerInformation`.
- **An unloaded chunk's computer is CLOSED, and reboots into `startup` on chunk load.** So a remote
  station costs **literally nothing** when nobody is near — better than deep sleep — and chunk loading
  is already a coarse (~simulation-distance) proximity gate. It also kills the "stations 1000 blocks
  out can't hear rednet" objection: a station only needs to listen when a player is near it, and a
  player near it has already loaded its chunk.

**In-world checklist (PENDING):** `update hub`
+ `update cage`, put `pos=` in cage.cfg, reboot · `hub test zones` lists it · walk to the cage → only
the cage wakes · walk to the hub → the cage does **NOT** wake (the whole point) · walk away → sleeps ·
reboot the cage while standing at it → wakes (the pull path) · the slot (no `pos=`) still wakes on
`"all"` → no regression · Nether at the cage's x/z → does **not** wake · hub terminal quiet while
nobody moves (edge-only).

## GPS constellation — the build guide (owner task, zero code)

**What it buys:** a station learns its **own** position at boot, so a floor of hundreds never needs
hundreds of hand-typed coordinates. Without it everything still works — a station just needs `pos=`
in its `.cfg`, or it stays on the floor-wide `"all"` zone. **It is optional infrastructure; nothing
blocks on it.** Facts + the measurements behind the rules: `[[gps-constellation-geometry]]`.

**Shopping list:** 4 computers + 4 **ender modems**, all in a **force-loaded** chunk (the hub's is
already force-loaded — put them there).

### The two rules that matter

1. **The 4th host MUST be at a different `y` from the other three.** Three hosts only ever narrow a
   station's position to a **mirrored pair** about their plane; the 4th breaks the tie only if it sits
   **off** that plane. Four hosts all at the same y **fail at every distance** — and they fail
   *silently*, as `gps.locate()` simply returning nil. This is the one way to build it wrong.
2. **The modem goes on a SIDE of the computer, never on a cable.** `gps host` and `gps.locate` both
   scan `rs.getSides()` only. A modem on the wired network is invisible to GPS.

Everything else is forgiving. **Making A→B / A→C longer buys literally nothing — measured, not
assumed** (`test/spikes/gps_constellation.lua` asserts it). At a fixed +40y lift, growing the triangle
from 5 blocks to 10,000 blocks — **2,000×** — leaves the reach at 200,000 blocks, unchanged. Lift
alone moves it 50× (+5y → 10,000; +100y → 500,000, then saturating).

Why, and it is the one real-GPS intuition that **inverts** here: A, B and C define a *plane*, and three
exact distances always narrow to a **mirrored pair reflected across it**. A bigger triangle does not
move the plane, so the mirror is identical — only the 4th host's distance *off* the plane separates the
two candidates. Baseline length is the lever in real GPS purely because it averages down *measurement
noise*; CC has none, so exactness takes that lever away. Lift saturates near +100 and the world height
limit caps it anyway — **+40 is already ~200× more reach than any station will ever need.**

They also don't *have* to share a chunk — any force-loaded chunks will do. One chunk is simply enough,
which is the useful part: **one chunk to force-load.**

### Layout

Three at one height, spread out (a right angle, not a line — chunk corners are ideal), and the fourth
**~40 blocks up**:

```
        D  (+40 y)          three at y=Y, one at y=Y+40
        ·
   A ---------- B           A, B, C: NOT in a line (trilaterate rejects near-collinear)
   |                        D: any x/z; the LIFT is the whole job
   C
```

+5 y already works to 20,000 blocks; +40 y reaches 100,000. Take the 40 — it's free.

### Steps

1. Place the 4 computers as above, an **ender modem on a side of each**.
2. For each, get its **own block coordinates**: point at the computer and read F3's
   **"Targeted Block: X Y Z"** (*not* the player XYZ line — that is where you are standing).
   > **Sight it from a face WITHOUT the modem.** The modem is its own block stuck to the computer, so
   > pointing at the computer *from that side* puts your crosshair on the **modem** and F3 hands you
   > a position one block off. This bit us on 2 of the first 4 hosts. See "a GPS fix is ALWAYS whole
   > numbers" in `[[gps-constellation-geometry]]` — decimals in `gps locate`'s answer mean a host is
   > lying about where it is, and `gps locate` prints enough to work out *which*.
3. On each computer, make it host **on boot**, so a server restart or chunk reload brings it back:
   ```
   edit startup
   ```
   one line, with **that computer's** numbers:
   ```lua
   shell.run("gps", "host", "105", "64", "-238")
   ```
   Ctrl → Save → Exit, then `reboot`. It should print `Opening channel on modem ...` and sit there
   serving. **That is a running program — leave it running.** A host that isn't running is invisible,
   and a missing 4th host looks exactly like no GPS at all.
4. Repeat for all four, each with its own coordinates.

> **Why `startup` and not just running `gps host` by hand:** these must survive a server restart. A
> dead constellation is **silent** — stations quietly fall back to `"all"`, and nothing announces it.
> We write no code for this: CC ships `gps host` (`rom/programs/gps.lua`).

### Verify

On any computer with a wireless modem on a side (a station is fine):
```
gps locate
```
Expect a position within ~2s, and **expect it to be whole numbers** — a computer sits at an integer
block position, so **decimals in the answer are the error message**, not imprecision. It means at
least one host is broadcasting the wrong coordinates.

- **nil / nothing** ⇒ rule 1 (are all four at the same y? that fails at every distance), then rule 2
  (modem on a computer side?), then: are all four actually *running*?
- **Decimals, or a plainly wrong spot** ⇒ a host is lying about its position. `gps locate` already
  runs in debug mode and prints `<distance> metres from <claimed pos>` per host — that is enough to
  solve for which one. Square each distance (clean integers ⇒ the distances are fine and it is NOT
  jitter — there is no GPS equivalent of AP's randomError), find the two hosts that agree, solve the
  station's true position, then check each claim against it. Worked method + a solved example:
  `[[gps-constellation-geometry]]`.
- Note a 1-block error is **loud on a short baseline and nearly invisible on a long one** — so how
  wrong the answer looks tells you nothing about how big the mistake was.

### Then: hand the stations over to it

- **Cage:** delete the `pos=` line from `cage.cfg` and reboot. **cfg always wins over discovery**, so
  while `pos=` is there GPS is never consulted. `hub test zones` should show the same position it did
  before — now derived, not typed.
- **Slot:** nothing to do. It has no `.cfg`, so it has been falling back to `"all"`; on its next boot
  it self-locates and gets a zone of its own. **This is the moment the slot stops waking when someone
  walks past the hub.**
- **Every station after this one:** wire it, `update <pkg>`, done. No coordinates, ever.
- **Bonus:** the 2s `gps.locate` stall on every station boot disappears — that delay was the timeout
  expiring with no constellation to answer.

## Floppy-swap freeze — ROOT-CAUSED + FIXED 2026-07-17 ✓ (in-world verification PENDING)

The standing bug is dead. Merged + pushed (`aee8715`). Spec:
`docs/superpowers/specs/2026-07-17-hub-lookup-pump-freeze-design.md`; plan:
`.../plans/2026-07-17-hub-lookup-pump-freeze.md`. 4 tasks, per-task + whole-branch review, 382 tests.

**It was `rednet.lookup`, and it was never a mystery once we read the rom.** From CC's own
`rom/apis/rednet.lua` (blob `8107a46`), `lookup` runs `local event, p1, p2, p3 = os.pullEvent()` —
**no filter** — and silently discards every event that is not a dns reply or its own timer. Default
timeout **2s**. So: hub unreachable → card swap → `disk` event → `sp_econ.refreshCard` →
`wallet.query` → `getHub` → **2 full seconds of eating events**, including `slot.lua`'s pending tick
timer. `slot.lua` re-arms its timer *only in the timer branch*, and the swap arrived on the `disk`
branch. Timer gone, nothing re-arms it, next `os.pullEvent` blocks forever. Frozen, no crash, reboot
to clear — **and intermittent, because it tracked whether the hub's chunk happened to be loaded.**

> **The owner's fix (force-load the hub + reboot it) removed the TRIGGER, not the bug** — and it was
> a genuinely good call, it made the floor usable. But a hub reboot, a server restart, or a chunk
> unload re-arms it, and a public floor swaps cards constantly. Worse, `wallet.lua`'s
> `if result == nil then hubId = nil end` drops a good hub id after **any** timeout, so a single
> server hitch re-armed the pump *even against a healthy force-loaded hub*.

**The three-part fix** (drop any one and the bug lives): `_pumpSafe` drives `lookup` as a coroutine
and re-queues what it drops · cache the hit · **back off the miss** (`LOOKUP_BACKOFF = 5`).
**A cache alone was never enough** — it only populates when the lookup *succeeds*, so it was absent
in exactly the case that froze. That gap is now written into `[[event-pump-reentrancy]]`, whose old
advice ("cache blocking lookups") was followed exactly and still let this through.

**It also killed a lie.** `wallet.bet` already returned `reason="timeout"`; `sp_econ` **dropped the
third return** and set `denied`, so a hub-down slot rendered **`INSUFFICIENT`** at a player holding
$500. Now `sp_econ.offline` is threaded through and the header says **`HUB OFFLINE`**. Fail-closed on
money is unchanged — only what the player is *told* changed.

**`HUB OFFLINE` is sticky until you interact, BY DESIGN — do not "fix" it with a poller.** Nothing
polls: `offline` clears via `refreshCard` (disk events), a successful `tryBet`, or sleep→wake (a fresh
`econ` per `play()`). A failed lookup stalls the loop ~1.5s and the backoff is 5s, so polling = a
**~30% duty cycle of frozen reels** — a worse machine than a stale word. An idle offline station
pumps *nothing*.

**In-world verification (PENDING — the only thing left):** it requires **deliberately breaking the
hub** (stop `hub.lua` or unload its chunk), because the chunkload fix normally prevents that state.
`update slot`, reboot, insert card · break the hub · **swap the floppy repeatedly → pre-fix this
froze; now the reels keep animating and the header reads `HUB OFFLINE`** · pull the lever while
offline → denied, says `HUB OFFLINE`, **not** `INSUFFICIENT` · bring the hub back, pull the lever or
re-swap → recovers, no reboot · a win banked while offline still lands (outbox regression check).

**Two Minors filed, not fixed:** `rednet.lookup`'s 3rd `timeout` arg landed in CC:Tweaked **1.118.0**
and the server's jar version is not pinned anywhere in the repo — on an older build the arg is
silently dropped and the hitch is 2s, not 1.5s (harmless; worth one in-world check). And the
`bet_deny{reason="unknown"}` lie, filed in the OPEN list above.

## → NEXT: **the OPEN phase** — polish the floor until it can take real players (owner-set 2026-07-17)

**The build phase is over. Everything needed to open exists and works in-world:** the economy is a
loop (`$` in via slot/`issue`, out via the cage's real metal), stations sleep until you walk up to
*them*, and a new station is wire-it-and-run. **Scope for opening: the cage + the slot machine only.**
No new games, no new subsystems — this phase is about the floor being *good* rather than *complete*.

**The question that decides every item below:** *would a player who has never seen this notice, and
would it embarrass us?* Anything else is a distraction from opening.

**Known rough edges, in rough priority — brainstorm before building any of them:**

- ~~**The adverts — and the real deliverable under them is a PIXELFONT ALPHABET.**~~ **BUILT +
  IN-WORLD VERIFIED 2026-07-17** (`feat/pixelfont-alphabet`, merged to main; spec + plan in
  `docs/superpowers/`). Owner confirmed both idle faces read well from across the floor ("perfect");
  the confusable pairs (`S`/`5`, `I`/`T`) are "not bad in context" — left as-is.
  - **Cage advert got an owner-driven second pass** (2026-07-17): `THE CAGE` title + its banner bar
    dropped; `METAL IN` / `CASH OUT` lifted ~12% higher; background is now the cage's **own** green→gold
    "casino" gradient, sampled static (matches the active screen). Safe on the shared palette — advert
    and play never run at once, and the play loop re-sets those slots on wake. See
    `[[monitor-ui]]` ("an idle advert may reuse the play screen's palette slots").
  - **Cage empty-deposit toast fixed** (2026-07-17): the withdraw button labels (native text) were
    bleeding over the toast panel (subpixel). Root cause + rule now in `[[monitor-ui]]` — native cell-
    text always layers over the whole subpixel canvas; a subpixel popup can't cover it. Gated the
    labels while the toast is up. **In-world confirmation of this one fix is pending (owner's).**
  - **`pixelfont` now has an alphabet.** A-Z + `! : - . ,` + a **space** went into `M.BIG` (one table
    with the digits, so a mixed string like `COPPER $25` is one `drawText` call and every existing
    call site is untouched). Base 4 wide, `M`/`W` at 5 — matches the owner's square slashed digits.
    `pixelfont` was already variable-width and scale-aware, so this was **data, not new code**; the
    27 pre-existing tests stayed green (now 125).
  - **The space is 3 subpixels wide, not 4 — and it is load-bearing.** At 4, `METAL IN` @2x measures
    **73** against the cage's 72-wide canvas and the copy would have had to change; at 3 it is 71.
    (Also: a *missing* glyph has width 0, so before this a space advanced 1 subpixel and words
    collided — a latent bug nothing had hit.)
  - **`slot_style.lua` was extracted** from `slot.lua` so the idle face and the play face share ONE
    gradient/bulb/colour kit instead of drifting apart. `slot.lua` changed by deletion + require only.
  - **Slot copy: `GET` @2x / `MONEY` @1x / big `$`.** `COME PLAY` was dropped — it fits at no scale
    (44 @1x on a 30-wide canvas). Fitting `MONEY` big beat fitting `COME PLAY` small (owner's call).
  - **Cage: `THE CAGE` / `METAL IN` / `CASH OUT` @2x**, with the **rate table kept native** (it is
    long small print — the native-vs-subpixel rule; native is also denser, 3 subpx/row vs 6). The
    PNG-verify step caught the two signage lines merging with no gap and it was fixed there.
  - Verified offline the golden-standard way (`kb/monitor-ui-workflow.md`): both screens rendered to
    PNG through `encodeCell` (`docs/mockups/slot-advert.png`, `cage-advert.png`); `tools/font-preview.html`
    is the owner's glyph-review surface. **Owner: review the confusable pairs there** — `S`/`5`,
    `I`/`T`, `G`/`6` differ by only 1-2 subpixels, a real far-legibility risk; redraw any you dislike
    (`I`/`T` is the live one — `METAL IN`/`CASH OUT`/`THE CAGE` all contain both).
- **Nothing tells a new player what any of this IS.** No card, no idea what `$` is, no idea the cage
  exists. The membership card is deliberately optional (README principle 4) — but "optional" only
  works if a player can *discover* it. Consider signage, a `chat_box` bark on approach (AP has one),
  or an attract-mode explainer. Diegetic only.
- **Getting a card is an admin action.** `issue <name>` runs on the hub. To open, a player needs a
  path to their first card that does not involve the owner typing. Own brainstorm; the trading
  station (parked, below) may be the same machinery.
- ~~**Floppy-swap freeze (open bug, #2 below).**~~ **ROOT-CAUSED + FIXED 2026-07-17** (in-world
  verification pending — see the section below). It was `rednet.lookup`, and the owner's
  hub-chunkloading had already removed the *trigger*.
- **Verify the proximity checklist end to end** (todo's proximity section) — the walk-to-the-hub test
  in particular. It is the difference between "built" and "known good".
- **`hub_version` / ping** — a station cannot distinguish "no hub" from "hub too old", so both read
  HUB OFFLINE. Cost real debugging time twice now. Cheap, and every future protocol change has this
  failure mode.
- **A `bet_deny{reason="unknown"}` still renders `INSUFFICIENT`** (`sp_econ.lua:65-66`) — the same
  lie-class the freeze fix killed, one slot over. A card whose ledger id was deleted (`hub.lua:246`)
  tells the player they are broke rather than that the card is dead. Pre-existing; the `offline`
  machinery now makes it a 2-line fix (a third state), so it is cheap to close. Found by the
  hub-lookup branch's whole-branch review, filed not fixed (out of that branch's scope).
- **`cage_rates.DENOMS` ceiling is now FOUR, not six** (tightened by the alphabet branch 2026-07-17).
  `cage_advert`'s 2× signage pushed the native rate table down to cell rows 18-21; a **6th** metal
  lands on the bottom red bar (a 5th fits but with no breathing room). The CEILING note in
  `cage_rates.lua` has the exact geometry. `DENOMS` ships exactly 4, so nothing breaks — but a 5th
  metal needs `cage_advert`'s bands re-laid out first.
- **`pixelfont.M.SIGN_SM` is dead code** (found by the alphabet branch). Zero call sites — only
  `SIGN_LG` ships (`cage.lua:170`, paired with `BIG`@2x). Its "pairs with 1× digits" comment is
  unverified and looks wrong (`SIGN_SM` is 10 tall, `BIG`@1x is 6, so their baselines were never
  worked out). It is the owner's drawing, so it was filed, not deleted. Decide: pair it with
  something, or drop it.

**Not in the open phase** (parked deliberately — they are how the floor *grows*, not how it opens):
multiplayer/`mp_econ`, more games, scoreboards, the trading station.

## MP economy engine — CODE COMPLETE + merged 2026-07-17 ✓ · **ZERO in-world testing** ⚠️

> **Nothing multiplayer has been run in-world — not once.** The engine is built, unit-tested (77
> mp_econ tests + a whole-branch review), merged to main and pushed, but **no card has been inserted
> into a real 2-drive pong station, no pot has been anted, nothing.** Every claim below is
> verified-in-tests-only. The refactors of the two SHIPPED stations (slot, cage) are the highest
> regression risk and are *also* unverified in-world since the merge. Deploy + walk the checklist
> before trusting any of it. **This is the whole job of the next MP session's first hour.**

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
  **Owner's call 2026-07-18: accepted risk, not closed** — the window realistically requires a full
  server crash mid-match. Reconsider if it is ever observed in the wild.
- **`getMountPath()` on a NETWORK drive is unverified** — the whole seat model assumes two drives on
  one computer both mount. It is a 2-minute in-world check and the design rests on it.

**Deploy attempt 2026-07-17 — pong wouldn't start, no ender modem (`c17d7f8`).** The pong station was
built **wired-only** (wired modem for the monitor, no ender modem on a side). Pong wakes ONLY on GPS
proximity, and `gps.locate` needs an **ender modem on a computer SIDE** to self-locate + register a
zone — wired-only falls to zone `"all"`, normal per-station presence never wakes it, and pong had
**no fallback** (slot has its lever, cage has `pos=` in cfg). Fixed by adding an **additive local
redstone wake** (`wake_side=`/`wake_level=` in pong.cfg, default side `left`, mirrors slot's lever):
step on a plate to wake with no ender modem. **Blocked until an ender modem is added** (owner lacked
materials): full pot money flow + GPS sleep/wake need the station to reach the remote hub. What the
local wake unblocks offline: the 2-drive `getMountPath` seat read (seats show `id OFFLINE` off the
card mirror), the seat UI, and the `HUB OFFLINE` deny path. **In-world verification of the wake +
seat read is still PENDING** — pushed, not yet tested.

**In-world verification (PENDING):** `update slot` + `update cage` + `update pong`, reboot each ·
0 cards → free rally, **no regression** · 1 card → free, **no debit** · 2 cards → `GO` → both
debited, `POT $20` → `END` → higher score credited · **pull a card mid-match → the pot still pays
the anted id** · a *different* card mid-match → spectator gets nothing · seat 2 insufficient → `GO` →
**seat 1 not out of pocket** · hub down → `GO` → `HUB OFFLINE`, not `INSUFFICIENT`, nobody debited ·
**walk away mid-match → the pot resolves** · **slot + cage still work** (the extraction touched two
shipped stations — this is the regression that matters most).

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
- **A FLASH phase sits between play and results — the machine is four screens, not three.** After
  the rally ends, a ~1s panel draws OVER the finished board (it doesn't clear it, so the rally stays
  visible underneath) naming the winner by card id (`alice WON!`), falling back to the seat label for
  an anonymous winner (`LEFT WON!`) — it must never render `anon WON!`. It lives in `match`, not in
  the game, so every future game inherits it for free. It's pumped, not slept — a bare `sleep(1)`
  would swallow presence and the quit key for a full second.
- **The results screen REPLAYS money that already moved** — the ante debits at GO, the pot credits
  at finish. Balances are captured *before* `mp_econ.start()`; animating from the post-ante number
  would hide the drain entirely.
- **The results screen shows a verdict headline on BOTH staked and free matches.** Once the counters
  settle to white a staked screen would otherwise carry no statement of who actually won. A free
  match shows the headline plus a `FREE MATCH` label where the counters would be.
- **`mp_econ.reset()`** — `"done"` was terminal, so a station played exactly one match per boot.
  That was the observed in-world reset bug.
- **`lib/controls`** — plates moved onto a `redstone_relay`, whose methods are name-identical to the
  built-in `redstone` API (verified: tweaked.cc, CC:Tweaked 1.114.0+). Wiring lives in `pong.cfg`;
  the relay is discovered BY TYPE; every failure is loud at boot.
- **`pong test` works with NO `pong.cfg`.** It shows the six raw sides — what you watch while
  stepping on plates — alongside the logical mapping if one exists. That's the commissioning path:
  `update pong` → `pong test` → step on each plate → write `pong.cfg` from what you saw → reboot.
  Normal boot still hard-stops on a missing mapping; only the diagnostic is exempt.
- **The local redstone wake was REMOVED.** It only existed because the station had no ender modem.
  With the plates on a relay no computer side ever changes, so it would have failed *silently* —
  and removing it means `idle_runner` was not touched at all.
- **Screens are debug-grade native text on purpose.** The art pass for all four screens (plus
  `pong_advert`, still an 18-line stub) is a separate effort against the spec's UI contract:
  57×24 cells, 3×2 blocks @0.5.

### Filed by the whole-branch review — read before building game #2

- **`match` supports exactly TWO seats today, whatever `maxSeats` says — and `lobby.lua` is why.**
  `match.lua` and `match_logic.lua` are genuinely N-agnostic (`nSeats = #seatLabels`, `newReady(n)`,
  `bestSeat(n)`, `resultRows` over `#status.seats`). `lobby.lua` is not: `M.READY` holds exactly 2
  rects and `hitTest` does `math.min(nSeats, #M.READY)`, so **seats 3–4 can never toggle READY, so
  `allReady` is never true, so GO is permanently dead**. `M.INFO` likewise has 2 columns and
  `infoWrite` silently returns for `i > 2`, so those seats render nothing. All the geometry mirrors
  about the net at col 29 — a 2-seat premise, not a layout. Nothing is broken (pong is 2-player),
  but **a seat-count-driven lobby layout is the named prerequisite for any 3–4 player game.**
- **Highest-score-wins is baked in** (`match_logic.bestSeat` *and* `mp_econ.finish`). A lowest-wins
  game — a race scored by time, golf — cannot express its own comparator. It needs a `compare`/
  `winnerOf` hook threaded through both.
- **`ctx` is deliberately thin** (`win`, `controls`, `seats`, `target`, `tick`). A game cannot read
  econ status mid-play or receive extra per-game cfg. Fine for pong; likely the first thing game #2
  asks for.
- **`"HUB OFFLINE - nobody charged"` can be false in the partial case.** `mp_econ.start` checks
  `reason == "timeout"` first, so if seat 1's debit succeeded and seat 2 then timed out, the screen
  says nobody was charged while seat 1 *was* charged and refunded **via the outbox** — guaranteed but
  not yet applied, so seat 1's lobby balance still reads the debited figure until the next `flush()`.
  Self-heals. Honest enough to ship; worth knowing when someone reports it.
- **`controls.sideOf(name)` returns nil for an unmapped name** instead of erroring the way `get()`
  does — the one place the fail-loud rule isn't carried through. Diagnostics-only path; `pong test`
  reads `CFG[name]` directly rather than going through it. Filed, not fixed.

**In-world verification (PENDING):** `update pong`, reboot · wakes on presence, no plate needed ·
all four paddles respond (`pong test`) · `pong test` on a station with no `pong.cfg` lists all six
raw sides and reacts to each plate · 0 cards → both READY → GO → free rally to 5 → `LEFT/RIGHT
PLAYER WON`, no counters, nobody debited · the win flash appears for ~1s over the finished board and
names the winner by card id (or the seat label when the winner is anonymous) · 1 card → free, no
debit · 2 cards → GO → both debited, `POT $20` → first to 5 → counters drain the loser and climb the
winner → winner credited · a rematch tap on the results screen returns to the lobby with **READY
cleared**, and a second GO does nothing until both seats re-ready · results auto-returns after ~8s ·
eject a card mid-match → the pot still pays the anted id · a different card mid-match → spectator ·
seat 2 insufficient → seat 1 not out of pocket · hub down → `HUB OFFLINE`, nobody debited · walk away
mid-match → the pot resolves · **regression: slot + cage still work.**

**Open question, to check in-world rather than assume:** does a `redstone_relay` input change raise
the computer's `redstone` event? tweaked.cc is silent. Nothing here depends on it (presence is the
wake, paddles are polled), but a future design that leans on it would fail silently.

## Backlog (behind the OPEN phase — owner-set 2026-07-16, roughly in priority order)

0. ~~**Build the cage**~~ — **DONE + IN-WORLD VERIFIED 2026-07-17.** See the Cage section above.
   The economy is now a **loop**: `$` enters (slot paytable / `issue` mint) and finally *leaves*
   (metal out of the cage). Small follow-ups it earned, none blocking:
   - **`hub_version` / ping in the protocol** — a station can't distinguish "no hub" from "hub too
     old to know this message", so both read HUB OFFLINE (cost real debugging time this session).
     Every future protocol change has this failure mode. See `kb/economy.md` lesson 7.
   - ~~**Extract `lib/card_session.lua`**~~ — **DONE 2026-07-17** with `mp_econ` (the rule-of-three
     trigger). `cage_econ`'s `msg`-string drift was reconciled onto `sp_econ`'s `offline`, which
     closed the "`NEED $x` for a dead card id" lie listed below.
   - **`cage test drop` doesn't exercise `play()`'s pulse path** — it pairs its edges, so it stayed
     green through a bug that lost 1 tap in 3. Any future hardware self-test should drive the real
     code path or say plainly what it doesn't cover.
   - Cosmetic, filed not fixed: `cage_econ.refund()` shows "REFUNDED $x" to whoever's card is in the
     drive (not necessarily the payer); `tryDebit` says "NEED $x" even for a dead card id; the dead
     `droppers` handle table in `cage_hw` (the wrap loop is the real fail-loud preflight).
1. ~~**General multiplayer capabilities**~~ — **ENGINE BUILT 2026-07-17.** See the section above.
   What is left is a real MP *game* (pong is a harness): its own brainstorm→spec→build, and it must
   close the pot-journal gap first.
2. ~~**Economy bug — floppy-swap freeze (open).**~~ **FIXED 2026-07-17** — see the section below.
3. **Slot advert-screen UI session** — the idle `slot_advert.lua` (COME PLAY / GET MONEY) is a plain
   default-palette screen. Give it the full treatment via the golden-standard loop (`kb/monitor-ui-workflow.md`):
   owner mockup → `tools/slot-preview.html`-style preview → subpixel art / `pixelfont` → deploy. It's the
   station's face while idle, so it matters. Reuse `pixelfont` + the gradient/bulb kit.
4. **More minigames** — 1–4 player, monitor / Create-contraption / hybrid. Each its own brainstorm→spec→build.

Parked (each its own spec later):
- **Trading station** — transfer **`$` between member cards** (players may hold multiple cards);
  hub-mediated (debit sender id, credit receiver id — two id-scoped ledger writes). Diegetic amount +
  confirm controls. Reuses the core; `wallet.debit` (built for the cage) is already its primitive.
  See `kb/economy.md`.
- **Scoreboards** — display-only rednet subscribers rendering standings around the floor.
- **Multiplayer economy** (`lib/mp_econ`) — multi-card pot / interactive wagers; core already SP/MP-agnostic.

Non-blocking follow-ups from the final review (see the SDD ledger F1/F2):
- ~~**F1** `wallet.request` blocking event pump~~ **FIXED (1a7d9d7)** — it swallowed slot.lua's tick
  timer on a mid-session card hot-swap → frozen monitor. Now stashes + re-queues foreign events and
  caches the hub id (keeps `rednet.lookup` out of the hot path). The under-rated review finding, made real in-world.
- ~~**F2** credit to an *unknown* id would be treated as acked (win silently lost)~~ **FIXED** (the
  cage task) — hub now replies `credit_deny{id, reason="unknown"}`; `wallet.credit`/`flush` treat it
  as a terminal deny, never re-outboxed. See `kb/economy.md`.

## slot.lua tuning knobs (if revisited)

- Reel feel: `SPIN_SPEED0` / `DECAY` / `MIN_SPEED` (`slot_logic.lua`), stop ticks 12/20/28 (`slot.lua`).
- Gradient: `GRAD_DEEP` / `GRAD_TEAL` and drift rate `tick * 0.05` (`slot.lua`).
- Layout: viewport at `cv.h * 0.34`, `barH`, bulb spacing (`topLayout` in `slot.lua`).
- Config: `TOP_NAME`, `SPIN_SIDE`, `SPIN_LEVEL=13`, `STAKE_SIDE`, `STAKE_LEVEL=13` (`slot.lua`).
- Layout (v3): fixed 15×24 cell-row bands in `topLayout` (`R(row)` helper); reel viewport = rows 15–17.
- Stakes: `STAKES={10,25,100}` (`slot/slot_pay.lua`); cycle button on `STAKE_SIDE`, `stakeIdx` a `play()`-local.
- Payout: per-symbol multiplier `cherry 3× · bell 5× · bar 8× · seven 25× (jackpot)`; payout = `stake × mult`
  (`slot/slot_pay.lua`, `eval(result,stake)`). Starting card balance default `100` (`issue`).

## slot v1 — status (complete)

Lever-triggered spin on a 1×2 advanced monitor; 3 reels with downward scroll + deceleration;
palette-driven blue↔teal gradient; framed reel viewport (symbols clipped behind bars); 4-sided
animated bulbs; WIN/LOSE detection + banner + gold win flash. Files: `src/slot.lua`,
`src/slot_logic.lua`, `src/slot_symbols.lua`, `src/lib/subpixel.lua`.
