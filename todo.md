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
    - **NEXT — in-world re-verify:** `update slot`, then **tap $10/$25/$100** to select (highlights,
      persists, resets to $10 after idle); confirm 3-symbol black window + variable payout. Polish later:
      big-digit win font, celebration art, text colours.
- **Slot finishing touches** — polish pass, including: **show `M-Bucks`/`MB` instead of `$`** in the
  economy header (`drawTopFrame` in `slot.lua`; `sp_econ.drawHeader` default); clean up the
  balance/stake/win header layout; any deny/row-2 visual nits.

Parked (each its own spec later):
- **Trading station** — transfer **M-Bucks between member cards** (players may hold multiple cards);
  hub-mediated (debit sender id, credit receiver id — two id-scoped ledger writes). Diegetic amount +
  confirm controls. Reuses the core; likely a small new gateway. Do after scoreboards + sink. See `kb/economy.md`.
- **Scoreboards** — display-only rednet subscribers rendering standings around the floor.
- **Diegetic sink** — what M-Bucks are FOR (redstone payout: dispense item / open door / lamp).
- **Multiplayer economy** (`lib/mp_econ`) — multi-card pot / interactive wagers; core already SP/MP-agnostic.

Non-blocking follow-ups from the final review (see the SDD ledger F1/F2):
- ~~**F1** `wallet.request` blocking event pump~~ **FIXED (1a7d9d7)** — it swallowed slot.lua's tick
  timer on a mid-session card hot-swap → frozen monitor. Now stashes + re-queues foreign events and
  caches the hub id (keeps `rednet.lookup` out of the hot path). The under-rated review finding, made real in-world.
- **F2** credit to an *unknown* id would be treated as acked (win silently lost). Unreachable in normal
  single-hub flow (ledger never deletes a just-debited id). Cheap fix: hub `credit_deny` reply.

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
