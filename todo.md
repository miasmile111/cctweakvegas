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
- [x] **In-world verification** — deployed; mint→insert→bet→win/lose→insufficient→eject(anon)→
      hub-offline-outbox all confirmed working. Hub + slot stations have disk drives.

## → NEXT: Lua UI deepdive + slot-machine finishing touches

The active next build (user-set 2026-07-16). Two intertwined threads:
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

## → NEXT queue (owner-set 2026-07-16, roughly in priority order)

0. ~~**Build the cage**~~ — **DONE + IN-WORLD VERIFIED 2026-07-17.** See the Cage section above.
   The economy is now a **loop**: `$` enters (slot paytable / `issue` mint) and finally *leaves*
   (metal out of the cage). Small follow-ups it earned, none blocking:
   - **`hub_version` / ping in the protocol** — a station can't distinguish "no hub" from "hub too
     old to know this message", so both read HUB OFFLINE (cost real debugging time this session).
     Every future protocol change has this failure mode. See `kb/economy.md` lesson 7.
   - **Extract `lib/card_session.lua`** — `sp_econ` + `cage_econ` are instances 1 and 2 of the same
     card-session machinery; `mp_econ` is the rule-of-three trigger (see #1 below).
   - **`cage test drop` doesn't exercise `play()`'s pulse path** — it pairs its edges, so it stayed
     green through a bug that lost 1 tap in 3. Any future hardware self-test should drive the real
     code path or say plainly what it doesn't cover.
   - Cosmetic, filed not fixed: `cage_econ.refund()` shows "REFUNDED $x" to whoever's card is in the
     drive (not necessarily the payer); `tryDebit` says "NEED $x" even for a dead card id; the dead
     `droppers` handle table in `cage_hw` (the wrap loop is the real fail-loud preflight).
1. **General multiplayer capabilities** — the core is already SP/MP-agnostic (`lib/ledger·card·wallet`).
   Build `lib/mp_econ` (multi-card pot / interactive wagers) + a first 2–4-player game or MP mode. Own spec.
2. **Economy bug — floppy-swap freeze (open).** Station *sometimes* freezes (no crash; reboot to clear)
   when swapping floppy disks; the `1a7d9d7` fix helped but didn't eliminate it. Repro + root-cause per
   `kb/economy.md` "Open follow-up" (likely a nested `os.pullEvent`/rednet path still reachable from
   `sp_econ.onEvent`/`disk_eject`). See `[[event-pump-reentrancy]]`.
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
