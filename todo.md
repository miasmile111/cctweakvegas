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

## Hub economy — core loop BUILT + reviewed (2026-07-16), in-world pending

Branch `feat/hub-economy`. Spec: `docs/superpowers/specs/2026-07-16-hub-economy-design.md`;
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
- [ ] **In-world verification (Task 9, user-run)** — deploy `update hub|slot|issue`; mint→insert→bet→
      win/lose→insufficient→eject(anon)→hub-offline-win→outbox-flush. Hub + slot stations each gain a disk drive.

Parked (each its own spec later):
- **Scoreboards** — display-only rednet subscribers rendering standings around the floor.
- **Diegetic sink** — what score is FOR (redstone payout: dispense item / open door / lamp).
- **Multiplayer economy** (`lib/mp_econ`) — multi-card pot / interactive wagers; core already SP/MP-agnostic.
- **Lua UI deepdive + workflow** — monitor-UI patterns/toolkit pass (start from the cc-lua monitor-ui kb).

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
- Config: `TOP_NAME`, `SPIN_SIDE`, `SPIN_LEVEL=13` (`slot.lua`).
- Payout: `STAKE=10`; per-symbol multiplier `cherry 3× · bell 5× · bar 8× · seven 25× (jackpot)`
  (`slot/slot_pay.lua`). Starting card balance default `100` (`issue`).

## slot v1 — status (complete)

Lever-triggered spin on a 1×2 advanced monitor; 3 reels with downward scroll + deceleration;
palette-driven blue↔teal gradient; framed reel viewport (symbols clipped behind bars); 4-sided
animated bulbs; WIN/LOSE detection + banner + gold win flash. Files: `src/slot.lua`,
`src/slot_logic.lua`, `src/slot_symbols.lua`, `src/lib/subpixel.lua`.
