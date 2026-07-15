# TODO

## Slot machine — status

**Working (v1 complete):** lever-triggered spin on a 1×2 advanced monitor; 3 reels with
downward scroll + deceleration; full-canvas animated blue↔teal gradient (palette-driven);
framed reel viewport with symbols clipped behind top/bottom bars; 4-sided animated bulbs;
WIN/LOSE detection + banner text + gold marquee/bulb win flash. Reusable `src/lib/subpixel.lua`
teletext canvas + `.claude/skills/cc-lua/references/` docs.

Files: `src/lib/subpixel.lua`, `src/slot.lua`, `src/slot_logic.lua`, `src/slot_symbols.lua`.

## Next: scoring / earnings system

Design + build in a future session (brainstorm first — this is new behavior):

- [ ] **Winnings detection & payout model** — how a win maps to a score/credit amount
      (flat per win? per-symbol paytable? jackpot on triple-7?). Currently win = 3 matching, no value.
- [ ] **Showing winnings** — how the amount earned from a spin is displayed on the monitor
      (banner number, running credit counter, animation). Uses the reserved top area of the 1×2.
- [ ] **High-score / earnings persistence** — a scoreboard of highest earnings. Persist across
      restarts (CC `settings` API or a file on the computer). Where it renders: the reserved
      TOP block of the monitor (with a margin gap above the play area — see original design).
- [ ] **Using / "spending" earnings** — what earnings are FOR: a redstone output on a win/payout
      (dispense an item, open a door, light a lamp)? A cash-out lever? Decide the diegetic sink.
- [ ] **Credits/betting (optional, deferred from v1)** — cost-per-spin + credit balance, if the
      earnings loop needs a stake.

## Notes / tuning knobs (if revisited)

- Reel feel: `SPIN_SPEED0` / `DECAY` / `MIN_SPEED` (`slot_logic.lua`), stop ticks 12/20/28 (`slot.lua`).
- Gradient: `GRAD_DEEP` / `GRAD_TEAL` and drift rate `tick * 0.05` (`slot.lua`).
- Layout: viewport at `cv.h * 0.34`, `barH`, bulb spacing (`topLayout` in `slot.lua`).
- Config: `TOP_NAME`, `SPIN_SIDE`, `SPIN_LEVEL=13` (`slot.lua`).
