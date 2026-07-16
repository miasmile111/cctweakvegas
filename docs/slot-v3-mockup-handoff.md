# Slot v3 — mockup handoff

**For the next session.** The owner drew a full slot-screen mockup in `tools/monitor-mockup.html` and
exported it. Build slot **v3** from it. Read this, then the mockup JSON, then the KB, before designing.

## Read first (workflow step 0)

- **The mockup:** `docs/mockups/slot-v3.json` — the exported drawing (subpixel buffer + text-region
  annotations). It IS the design source; decode it, don't guess.
- **`kb/monitor-resolution.md`** — the cell/subpixel model + the exact block→cell formula. Slot's
  monitor is **1×2 @ scale 0.5 = 15 cols × 24 rows** (canvas 30×72 subpixels). This mockup is at that
  exact size.
- **`kb/economy.md`** — the M-Bucks economy; stakes/payouts flow through `sp_econ` + `slot/slot_pay`.
- **`docs/monitor-resolution-lesson.html`** + the cc-lua **`kb/monitor-ui.md`** — rendering rules.
- **Current slot:** `src/slot/slot.lua`, `slot_logic.lua`, `slot_symbols.lua`, `slot_pay.lua`,
  `src/lib/subpixel.lua`, `sp_econ.lua`. Tuning knobs listed in `todo.md`.

## Decoded layout (15 cols × 24 rows, top → bottom)

| Rows | Element | Source |
|------|---------|--------|
| 2–4  | **`<Card ID>: <Money amount>`** header | text region (no bg) |
| 6–7  | **`WIN:`** centered label | text region |
| 8–9  | **large `<win-amount>`** | text region ("large text") |
| 9–11 | **top red frame bar** + row-11 full-width **bulb animation** | painted + text tag |
| 11–12| **celebration animation** zone | text tag |
| 13–17| **reel viewport** (rows 15–17 transparent) — reels spin here | empty band |
| 18–20| blue play area | painted |
| 21   | **bottom bar with orange bulbs** (`#o#o#o…`) | painted |
| 22   | **red bar** | painted |
| 23–24| **3 stakes:** `$10` (cols 2–4), `$25` (7–9), `$100` (12–14) + **Lose/Win banner overlay** | text + painted purple/gray |
| c1 & c15, rows 12–21 | **side bulb animations** | text tags |

## Owner's directives (explicit)

1. **Keep the SAME gradient and bulb animations** from the current `slot.lua` — reuse the existing
   palette-drift gradient (`GRAD`/`updateGradient`) and the bulb logic; do not reinvent them. The blue
   in the mockup = "the existing gradient goes here."
2. **Top header text has no background** (transparent) — it sits over the gradient. (Note the cell
   tradeoff below.)
3. **First pass: ALL text WHITE** — get everything legible before touching text colours. Colour comes later.
4. Everything else per the decoded layout above.

## What's NEW vs current slot (v2)

- **Card header** showing `<id>: <balance>` (v2 shows player + balance already — extend to this layout).
- **Big `WIN: <amount>`** display (v2 only shows a small `win N`).
- **Celebration animation** zone on a win.
- **Three selectable stakes** `$10 / $25 / $100` (v2 is a fixed `STAKE=10` in `slot_pay`). ← biggest change.
- **Lose/Win banner overlay** (v2 has WIN!/LOSE — extend).

## Open design questions (resolve in brainstorming)

1. **Stake selection — diegetic.** v2 has one lever (spin). Picking $10/$25/$100 needs a control:
   options — a second lever/button to cycle stake; use the analog lever *level* to pick stake then a
   button to spin; three pressure plates; etc. Must stay diegetic (no GUI). Decide before building.
   `slot_pay.eval` already multiplies per-symbol × stake, so variable stake is a small economy change
   (`sp_econ.tryBet` takes the chosen stake instead of the fixed `pay.STAKE`).
2. **Text vs. gradient (the cell tradeoff).** A text cell shows one glyph + one flat bg — it cannot
   also carry the drifting gradient (see the lesson / `kb/monitor-resolution.md`). "No background" for
   the header means transparent *bg colour*, but those glyph cells still won't animate the gradient
   through the letters. Two build options: (a) accept the header text on the gradient's current cell
   colour (set text bg per-frame, or a flat strip), or (b) draw letters as subpixel art to composite
   into the gradient (blockier font). Pick one; (a) is simpler and matches how v2 already works.

## Gradient-freedom map (where the gradient stays smooth)

`g` = single flat colour (gradient-smooth-capable), `X` = 2 colours already spent (art edge),
`T` = text cell (flat bg), `.` = empty/transparent (viewport). 150 free / 30 edge / 141 text of 360.

```
     123456789012345   (cols)
   1 ggggggggggggggg   full clean band
   2 gTTTTTTTTTTTTTg
   3 gTTTTTTTTTTTTTg
   4 gTTTTTTTTTTTTTg
   5 ggggggggggggggg   full clean band
   6 ggggggTTTgggggg
   7 ggggggTTTgggggg
   8 ggTTTTTTTTTTTgg
   9 XgTTTTTTTTTTTgX
  10 ggggggggggggggg   full clean band
  11 TTTTTTTTTTTTTTT
  12 TTTTTTTTTTTTTTT
  13 TgggggggggggggT
  14 TgggggggggggggT
  15 T.............T   viewport (reels)
  16 T.............T
  17 T.............T
  18 TgggggggggggggT
  19 TgggggggggggggT
  20 TgggggggggggggT
  21 TXXXXXXXXXXXXXT   bulb bar (spent)
  22 XXXXXXXXXXXXXXX   red bar (spent)
  23 gTTTTTTTTTTTTTg
  24 gTTTTTTTTTTTTTg
```

Cleanest gradient canvas: full rows **1, 5, 10**, plus cols **2–14 on rows 13–14 & 18–20** and the
col **1/15** lanes. The `X`/`T` cells are locked (art/text already spent their colour budget).

## Build path

Follow the project build workflow (brainstorm → spec → plan → build → merge+push). The mockup replaces
most of the "what does it look like" brainstorming; focus brainstorming on the two open questions above.
The mockup tool round-trips: if the design shifts, redraw + re-export, and re-decode with the same method
(`node` over the JSON: per-cell distinct-colour + text-region overlay).
