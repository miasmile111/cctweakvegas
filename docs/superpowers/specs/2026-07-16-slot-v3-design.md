# Slot v3 — design

Rebuild the slot machine's screen from the owner's mockup (`docs/mockups/slot-v3.json`,
decoded in `docs/slot-v3-mockup-handoff.md`) and add **three selectable stakes**. Keeps the
existing palette-drift gradient and bulb animations; first pass is all-white text.

Prereqs read: the mockup + handoff, `kb/monitor-resolution.md` (15×24 @ 0.5), `kb/economy.md`,
`README.md`, `todo.md`, `.claude/skills/cc-lua/kb/monitor-ui.md`.

## Scope

**In:** the new screen layout at the exact 15×24 / 30×72 target; a card-ID/balance header; a big
`WIN:` amount; a celebration zone; a diegetic 3-stake selector ($10/$25/$100); a Lose/Win banner
overlay; the small economy plumbing to bet a variable stake.

**Out (owner: "colour comes later"):** non-white text colours; a big-digit subpixel font; elaborate
celebration art. First pass = correct layout, legible white text, working stakes, reused gradient+bulbs.

## Decisions (from brainstorming)

1. **Stake control = one cycle button + the existing spin lever.** A second redstone input
   (`STAKE_SIDE`) rising-edge cycles the stake `$10 → $25 → $100 → $10`. The spin lever is unchanged.
   - The selected stake **persists across spins**.
   - It **resets to the smallest ($10) whenever the station goes idle** — free, because `idle_runner`
     re-enters `play()` fresh after each sleep, so the stake index is a `play()`-local initialised to 1.
   - Minecraft levers are **binary (0/15)**, so the rising-edge guard is the same `>= LEVEL` / `< LEVEL`
     re-arm pattern the spin lever already uses (`monitor-ui.md`). No analog dependency.
2. **Text over the gradient = flat-bg-per-frame, bg bound to the animated palette slot.** A text cell
   is one glyph + one flat bg and cannot animate the gradient *through* the letters. So: the subpixel
   gradient fills every cell's background as today; text is written on top with `fg = white` and
   `bg = GRAD[band]` (the palette **slot number** for that row's band). Because the gradient animates by
   redefining those slots, the text bg drifts with it for free — letters ride on the gradient, no box.
   Empty/non-text cells animate fully (both fg and bg are gradient). This is the mockup's "no background".

## Economy plumbing (small, pure, unit-tested)

- **`src/slot/slot_pay.lua`**
  - `eval(result, stake)` → triples only, `stake * MULT[sym]`. `stake` defaults to the module `STAKE`
    constant when omitted, so the existing `eval({...})` call sites and tests keep passing.
  - Export `STAKES = {10, 25, 100}` (the selectable ladder) alongside the existing `STAKE = 10`
    (kept as the default/back-compat stake) and `MULT`.
- **`src/lib/sp_econ.lua`**
  - `tryBet(stake)` → `local st = stake or self.pay.STAKE`; bet `st`; on success capture
    `self.stakedStake = st` (mirrors how `stakedId` is captured). Deny/free paths unchanged.
  - `settle(result)` → `self.pay.eval(result, self.stakedStake)`.
  - `status()` unchanged in shape (still returns `stake = self.pay.STAKE`); the game tracks and renders
    the *live selected* stake itself, so `status.stake` is no longer the display source of truth.
- Fail-closed bet gating, the credit outbox, and `stakedId` semantics are untouched.

## Render layout — fixed 15×24 (30×72 subpixels)

`slot.lua`'s `topLayout` fractional math is replaced with **hardcoded cell-row bands** — the target is
now an exact known size, so hardcoding matches the mockup and removes guesswork. Cell row `r` maps to
subpixel rows `(r-1)*3+1 .. r*3`; cell col `c` to subpixel cols `(c-1)*2+1 .. c*2`.

| Cell rows | Element | Render |
|-----------|---------|--------|
| 1 | clean gradient band | GRAD fill |
| 2–4 | `<id>: <bal> MB` header (cols 2–14) | white text, `bg = GRAD[band]`; centred single line |
| 5 | clean band | GRAD |
| 6–7 | `WIN:` centred (cols 7–9) | white text |
| 8–9 | win amount (cols 3–13) | white text, plain (big-digit font = later polish) |
| 9–10 | top red frame bar | RED |
| 11 | full-width bulb row | existing `bulb()` |
| 11–12 | celebration zone | simple palette/colour flash on a win (first pass) |
| 13–14, 18–20 | gradient rails / blue play area | GRAD |
| 15–17 | reel viewport (transparent) | reels drawn + clipped here (one symbol tall = 9 subpx) |
| 21 | orange bulb bar (`#o#o…`) | `bulb()` over a bar |
| 22 | red bar | RED |
| 23–24 | `$10` (cols 2–4) `$25` (7–9) `$100` (12–14) + banner overlay | white text; **selected stake highlighted**; WIN/LOSE banner drawn over this band on a result |
| cols 1 & 15, rows 12–21 | side bulbs | `bulb()` vertical |

- **Reuse verbatim:** `GRAD` / `updateGradient` (palette-drift gradient), `bulb()`, `drawSpriteClipped`,
  `drawReel`, the window+`setVisible` flush, and the palette save/restore.
- **Reels:** 3 symbols, 8 subpx wide, spread across cols 2–14; the viewport is one symbol tall (a
  classic single-line window). `slot_logic` reel stepping is unchanged.
- **Selected-stake highlight:** the chosen stake's label cell(s) get a distinct bg (e.g. a bright flat
  strip) so the choice is legible; the other two stay plain white-on-gradient.
- **Banner overlay:** on `result == "win"/"lose"`, draw the WIN/LOSE banner over rows 23–24 (it shares
  the stake band, as the mockup shows — the banner takes over during the result window).

## New config (top of `slot.lua`)

```
STAKE_SIDE  = "left"   -- computer side the stake-cycle button feeds (set via `slot test`)
STAKE_LEVEL = 13       -- rising-edge threshold for the cycle button (binary lever: 0/15)
STAKES      = {10, 25, 100}
```

`slot test` already prints live per-side analog levels; it's the tool to find `STAKE_SIDE`.

## play() loop changes

- Add locals: `stakeIdx = 1` (resets to 1 on every fresh `play()` = on wake), `armedStake = true`.
- Each tick, read `STAKE_SIDE`: on a rising edge past `STAKE_LEVEL`, `stakeIdx = stakeIdx % #STAKES + 1`;
  re-arm when it drops below. (Same shape as the spin-lever guard, independent `armedStake` flag.)
- On the spin edge, pass the live stake: `econ.tryBet(STAKES[stakeIdx])`.
- Render passes `STAKES[stakeIdx]` (and the win amount from `status.lastWin`) into `drawTopFrame` so the
  stake row can highlight the selection and the header/`WIN:` area can show live values.

## Build approach

- **`slot.lua` render:** one cohesive file with shared canvas state → **build inline** (per CLAUDE.md's
  SDD carve-out for single-file shared-state work), then a **whole-file code-review pass**.
- **`slot_pay.lua` / `sp_econ.lua`:** pure + small → **unit tests**. Extend `test/test_slot_pay.lua`
  (variable-stake `eval`, back-compat `eval` with no stake, `STAKES` ladder). `sp_econ` variable-stake
  bet/settle covered if a lightweight test harness fits its `card`/`wallet` deps; otherwise assert the
  `slot_pay` contract it depends on and verify `sp_econ` in-world.
- **Gates:** all `.lua` pass `luajit -bl` (syntax); unit tests green. In-world verification happens
  **after** merge+push (the deploy loop pulls from the repo).

## Non-goals / risks

- The layout is tuned for 15×24; on a different monitor size it still renders but positions won't match
  the mockup. Acceptable — the slot's monitor is fixed at 1×2 @ 0.5.
- The single-symbol-tall viewport is a deliberate change from v2's taller window (the mockup's viewport
  is rows 15–17 only). Reels still scroll; only the visible window shrinks.
