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

## Next session — pick ONE

### Option A — Lag / idle-sleep model (unblocks safe auto-run at scale)

Auto-run is correct but **not lag-safe across many machines yet**: `slot.lua` animates its
gradient/bulbs continuously, so every booted slot burns tick budget. Implement the README's
3-tier idle model in `slot` (brainstorm first — new behavior):

- [ ] **Deep sleep** — when no player is in the zone, block on `os.pullEvent` (zero loop).
- [ ] **Attract** — a proximity input (pressure plate / player detector via redstone) wakes a
      Vegas "COME PLAY" advertisement animation; runs *only* while someone's near.
- [ ] **Armed round** — the lever starts a spin; fall back to attract/sleep after.
- [ ] Confirm the tick-cost drop (many idle slots should cost ~nothing). Log findings to `kb/`.

### Option B — Hub economy (member cards + scoring)

Extend the hub (which already knows every station) into the score ledger, and make the slot pay:

- [ ] **Member card read/write** — floppy in the station drive holds `{ id, score-mirror }`;
      station reads `id` on insert. (No card = anonymous, still playable.)
- [ ] **rednet economy protocol** — `station→hub` `credit {id, delta}` and `query {id}` →
      `balance {id, score}` (shapes already sketched in the spec + README). Hub persists the ledger.
- [ ] **Slot payout model** — win → score delta (flat? per-symbol paytable? triple-7 jackpot?).
- [ ] **Show winnings / balance** on the monitor (reserved TOP block of the 1×2).
- [ ] **Scoreboards** — display-only rednet subscribers that render standings around the floor.
- [ ] **Diegetic sink** — what score is FOR (redstone payout: dispense item / open door / lamp).

(These fold in the earlier "scoring / earnings system" notes; the hub-authoritative model means
the score lives on the hub, not the disk.)

## slot.lua tuning knobs (if revisited)

- Reel feel: `SPIN_SPEED0` / `DECAY` / `MIN_SPEED` (`slot_logic.lua`), stop ticks 12/20/28 (`slot.lua`).
- Gradient: `GRAD_DEEP` / `GRAD_TEAL` and drift rate `tick * 0.05` (`slot.lua`).
- Layout: viewport at `cv.h * 0.34`, `barH`, bulb spacing (`topLayout` in `slot.lua`).
- Config: `TOP_NAME`, `SPIN_SIDE`, `SPIN_LEVEL=13` (`slot.lua`).

## slot v1 — status (complete)

Lever-triggered spin on a 1×2 advanced monitor; 3 reels with downward scroll + deceleration;
palette-driven blue↔teal gradient; framed reel viewport (symbols clipped behind bars); 4-sided
animated bulbs; WIN/LOSE detection + banner + gold win flash. Files: `src/slot.lua`,
`src/slot_logic.lua`, `src/slot_symbols.lua`, `src/lib/subpixel.lua`.
