# Pixelfont alphabet + the two advert screens — design

**Date:** 2026-07-17
**Branch:** `feat/pixelfont-alphabet`
**Status:** spec

## The problem, stated correctly

`src/lib/pixelfont.lua` has **no letters**. It holds exactly four tables:

| table | contents | drawn for |
| --- | --- | --- |
| `M.WIN` | `W` `I` `N` `:` — four literal glyphs, variable width, 4 tall | the slot's one `WIN:` label |
| `M.BIG` | digits `0`-`9`, 4×6 square, slashed `0` | the slot's win count-up |
| `M.SIGN_SM` | one `$`, 5×10 | **nothing — zero call sites** |
| `M.SIGN_LG` | one `$`, 7×14 | `cage.lua:170`, paired with `BIG`@2x |

That is the whole font. Both `slot_advert.lua` and `cage_advert.lua` therefore fall back to native
CC cell text — which is *why* they read as default-palette placeholders. **This is not "restyle the
adverts". It is "build an alphabet"; the two screens land on top of it.**

## Owner's decisions (2026-07-17 — settled, do not relitigate)

1. **Big type is a requirement, not taste.** An advert is designed to be read from far across the
   floor. Use the biggest font that fits, as much as possible.
2. **Glyph box: 4-wide base, `M`/`W` at 5.** Matches `BIG`'s square 4×6 digits so letters and digits
   are one font. `pixelfont` is *already* variable-width (`glyphW` reads `#g[1]`; `M.WIN` is 5/3/4/1),
   so this costs **zero code change**.
3. **Glyph set: A–Z + `!` `:` `-` `.` `,`** (+ space). Digits already exist and are owner-approved —
   **do not redraw `M.BIG`'s digits**; that would regress the slot's shipped win count-up.
4. **Claude drafts all glyphs; owner reviews in the preview tool** and redraws any that are wrong.
   `BIG`'s digits already pin the style, so there is less for a hand-drawn sample to establish than
   there was for `0`.
5. **Slot copy: `GET` @2x / `MONEY` @1x / big `$`.** `COME PLAY` is dropped — it fits at no scale
   (see the width budget), and fitting `MONEY` big beats fitting `COME PLAY` small.
6. **Cage: signage big, small print native.** The three signage lines go 2x pixelfont; the rate table
   stays native text and is restyled, not rebuilt.

## The width budget — the constraint everything obeys

Per `[[monitor-resolution]]`, @0.5 text scale:

| station | cells | **subpixels** |
| --- | --- | --- |
| slot (1×2 monitor) | 15×24 | **30 × 72** |
| cage (2×2 monitor) | 36×24 | **72 × 72** |

A glyph is 4 wide (M/W: 5), 6 tall, with a **1-subpixel gap that is NOT scaled** (`textWidth`:
`w + glyphW*scale + gap`). So:

| scale | glyph | letters/line, slot (30) | letters/line, cage (72) |
| --- | --- | --- | --- |
| 1x | 4×6 | 6 | 14 |
| 2x | 8×12 | **3** | 8 |

Measured strings (`sum(glyphW * scale) + gaps`):

| string | scale | width | canvas | fits |
| --- | --- | --- | --- | --- |
| `GET` | 2x | 26 | 30 | ✓ |
| `MONEY` | 1x | 25 | 30 | ✓ |
| `MONEY` | 2x | 46 | 30 | ✗ |
| `COME PLAY` | 1x | 44 | 30 | ✗ — dropped |
| `THE CAGE` | 2x | 69 | 72 | ✓ |
| `METAL IN` | 2x | **71** | 72 | ✓ — *only with a 3-wide space* |
| `CASH OUT` | 2x | 69 | 72 | ✓ |

### The space glyph is 3 wide, and that is load-bearing

**Today a space is a latent bug:** `glyphW` returns `0` for a missing glyph, so `drawText(font, "A B")`
advances only `0*scale + gap` = **1 subpixel** for the `" "` — words collide. The alphabet must add
a real space glyph.

Its width is not arbitrary. At **4 wide**, `METAL IN` @2x = `(5+4+4+4+4+4+4+4)*2 + 7` = **73 of 72 —
one subpixel over**, and the cage's copy would have to change. At **3 wide** it is **71**. A space
narrower than a letter is ordinary typography, so this costs nothing and saves the copy verbatim.

## Component 1 — `src/lib/pixelfont.lua`: the alphabet

**The alphabet goes INTO `M.BIG`.** Not a new `M.ALPHA` table. Reasons, in order:

- One `drawText` call renders a mixed string (`"COPPER $25"`, `"WIN 100"`). Two tables make that
  impossible — `drawText` takes one `font`.
- Every existing call site is untouched: `slot.lua:139` (`drawCentered(font.BIG, "250")`) and
  `cage.lua:171` (`drawText(font.BIG, digits, …, 2)`) still resolve digits out of the same table.
- All 27 existing assertions in `test/test_pixelfont.lua` still pass unchanged.
- `BIG` is already *the* big square font; it simply becomes complete rather than digits-only.

**No API change.** `textWidth` / `drawGlyph` / `drawText` / `drawCentered` already handle variable
width and scale. The module stays **pure** (no CC globals) so it keeps unit-testing under luajit.

### Style rules the glyphs obey (derived from the owner's `0`)

`M.BIG["0"] = { "####", "#..#", "#.##", "##.#", "#..#", "####" }` — read off it:

- **Full-width horizontal bars** top and bottom (`####`), not rounded bowls.
- **1-subpixel vertical stems**, square corners.
- Diagonals only where the letterform demands one.
- 6 rows tall, always.

### The draft glyphs

Base 4 wide; `M` and `W` are 5. Owner reviews these in `tools/font-preview.html` and redraws any.

```
A ####  B ###.  C ####  D ###.  E ####  F ####  G ####
  #..#    #..#    #...    #..#    #...    #...    #...
  ####    ###.    #...    #..#    ####    ####    #.##
  #..#    #..#    #...    #..#    #...    #...    #..#
  #..#    #..#    #...    #..#    #...    #...    #..#
  #..#    ###.    ####    ###.    ####    #...    ####

H #..#  I ####  J ####  K #..#  L #...  M #...#  N #..#
  #..#    .##.    ..#.    #.#.    #...    ##.##    ##.#
  ####    .##.    ..#.    ##..    #...    #.#.#    ##.#
  #..#    .##.    ..#.    ##..    #...    #...#    #.##
  #..#    .##.    #.#.    #.#.    #...    #...#    #.##
  #..#    ####    .##.    #..#    ####    #...#    #..#

O ####  P ####  Q ####  R ####  S .###  T ####  U #..#
  #..#    #..#    #..#    #..#    #...    .##.    #..#
  #..#    ####    #..#    ####    ####    .##.    #..#
  #..#    #...    #.##    ##..    ...#    .##.    #..#
  #..#    #...    ####    #.#.    ...#    .##.    #..#
  ####    #...    ...#    #..#    ###.    .##.    ####

V #..#  W #...#  X #..#  Y #..#  Z ####
  #..#    #...#    #..#    #..#    ...#
  #..#    #...#    .##.    .##.    ..#.
  #..#    #.#.#    .##.    .##.    .#..
  .##.    ##.##    #..#    .##.    #...
  .##.    #...#    #..#    .##.    ####
```

Notes on the three that needed a decision:

- **`S` vs `5`.** `BIG["5"]` is `####/#.../####/...#/...#/####`. A naive square `S` is *identical* to
  it. `S` is therefore **chamfered** at top-left and bottom-right (`.###` … `###.`) so the two differ
  at four corners. This is the same problem the owner's **slashed `0`** already solves for `0` vs `O`
  — precedent says it is worth solving, not tolerating.
- **`Q` is 4 wide, not 5.** Its tail pokes out of the bottom-right (`...#` on row 6) rather than
  needing an extra column, so only `M` and `W` are 5. **Known cost, flag it in the review:** this
  squeezes `Q`'s bowl into 5 rows where every other letter's body is 6, so `Q` will read slightly
  short. No advert copy contains a `Q`, so it is accepted rather than solved — but it is the first
  glyph to redraw if the owner dislikes it.
- **`Y`'s stem is 2 wide** (`.##.` repeated). A 1-wide stem under a 4-wide top is off-centre in an
  even-width box; a 2-wide stem is symmetric.

`I`, `N` and `W` are drawn to match `M.WIN`'s existing hand-drawn versions in spirit (bars top and
bottom on `I`; `N`'s stepped diagonal), but at the 6-tall `BIG` box rather than `WIN`'s 4-tall one.
**`M.WIN` is left exactly as it is** — it is the owner's drawing, it is 4 tall, and `slot.lua:138`
ships it. Do not delete it or redirect that call site.

### Punctuation and space

```
"!" 1 wide  { "#", "#", "#", "#", ".", "#" }
":" 1 wide  { ".", "#", ".", ".", "#", "." }
"-" 4 wide  { "....", "....", "####", "....", "....", "...." }
"." 1 wide  { ".", ".", ".", ".", ".", "#" }
"," 2 wide  { "..", "..", "..", "..", ".#", "#." }
" " 3 wide  { "...", "...", "...", "...", "...", "..." }   -- see the budget above
```

### Tests (`test/test_pixelfont.lua`, extend — do not rewrite)

The existing 27 assertions stay green untouched. Add:

- Every glyph in `M.BIG` is **exactly 6 rows tall** (loop the table — catches a typo'd glyph).
- Every glyph's rows are all the **same width** as each other (a ragged glyph mis-measures forever).
- `M.BIG[" "]` exists and `textWidth(BIG, " ", 1) == 3`.
- `textWidth(BIG, "A B", 1) == 4 + 1 + 3 + 1 + 4 == 13` (the space actually advances).
- The four budget numbers, as regression locks — these are the whole design:
  `textWidth(BIG,"GET",1,2) == 26`, `textWidth(BIG,"MONEY",1,2) == 46` (proves it does *not* fit 30),
  `textWidth(BIG,"MONEY",1) == 25`, `textWidth(BIG,"THE CAGE",1,2) == 69`,
  `textWidth(BIG,"METAL IN",1,2) == 71`, `textWidth(BIG,"CASH OUT",1,2) == 69`.
- `M` and `W` are 5 wide; a sample of others are 4.
- `S` and `5` are **not** the same bitmap.

## Component 2 — `src/slot/slot_style.lua` (new): the shared visual kit

`slot_advert` needs `slot.lua`'s gradient to look like the same machine. Those constants live inside
`slot.lua` today:

```lua
local GRAD = { 2048, 512, 8, 1024, 64 }     -- slot.lua:39
local GRAD_DEEP = { 0.00, 0.10, 0.65 }
local GRAD_TEAL = { 0.00, 0.75, 0.65 }
```

Duplicating them into the advert means the idle face and the play face drift apart the first time
either is tuned. **Extract them**, plus the two helpers both screens need:

```lua
-- slot_style.lua — the slot station's shared look: the gradient palette slots, the bulb, the bars.
-- Pure except applyGradient (which takes the monitor as an argument), so it tests under luajit.
M.GRAD, M.GRAD_DEEP, M.GRAD_TEAL   -- the 5 slots + the two endpoints
M.RED, M.YELLOW, M.WHITE, M.BLACK, M.GREY
M.applyGradient(mon, t)            -- set the 5 palette slots to the deep->teal ramp at phase t
M.bandFill(cv)                     -- paint the 5 gradient bands across the whole canvas
M.bulb(cv, x, y, on)               -- a 2x2 dot; on = YELLOW, off = GREY
```

`slot.lua`'s side of this is **pure deletion + a require** — it keeps its own `updateGradient`
animation loop and its own layout; only the constants and `bulb` move. Do not restructure
`topLayout` or the play loop; this branch does not touch gameplay.

> **`slot_style` is the ONLY reason this branch touches `src/packages.lua`.** One line, in the
> `slot` package's file list, in the **last** commit — see Parallel work below.

## Component 3 — `src/slot/slot_advert.lua`: rewrite

**Hard constraint, from README principle 2 and `idle_runner.lua:125`:** `advert.draw(mon)` is called
**once**, then the station blocks on `os.pullEvent`. This is a **single static frame** — no
animation, no palette drift, no timer. Idle must cost nothing. (The gradient is fine: it is a
*static* ramp set once with 5 `setPaletteColour` calls.)

Text scale needs no handling — `slot.lua:179` sets `setTextScale(0.5)` at module load, before
`idle_runner.run`, so the advert inherits it.

**Layout** (30×72 subpixels; `Rl(row) = (row-1)*3 + 1`, cell rows 1–24 — mirror `slot.lua`'s helper):

| band | subpixel y | content |
| --- | --- | --- |
| rows 1–2 | 1–6 | red bar + bulb row |
| rows 4–7 | 11–22 | **`GET` @2x**, white, centred (26 of 30) |
| rows 10–11 | 28–33 | **`MONEY` @1x**, white, centred (25 of 30) |
| rows 14–18 | 41–54 | **`SIGN_LG` `$`**, 7×14, centred |
| rows 23–24 | 67–72 | red bar + bulb row |
| cols 1 & 29 | 8–64 | side bulb lanes |

Background: `slot_style.bandFill` (the static gradient), then bars, then bulbs, then type, then
`cv:render()`. Draw order = layering, per `[[monitor-ui]]`.

**Bulb placement obeys `[[monitor-ui]]`'s cell-straddle rule:** bar-row bulbs start at **x=6**, not
x=2 — a 2×2 dot at the extreme edge column straddles cells and `encodeCell` renders it as a squashed
sliver. This already cost the slot a debugging round; do not re-derive it. Side lanes at x=1 and
x=`cv.w-1` are the *aligned* case (subx 1–2 and 29–30 each sit inside one cell column) and are what
`slot.lua` already ships.

Exact y values are a **starting point**, to be tuned against the preview and the PNG — the band
table is the contract, the pixel rows are not.

## Component 4 — `src/cage/cage_advert.lua`: rewrite

72×72. Same single-static-frame constraint. `cage.lua:589` sets scale 0.5 before `idle_runner.run`.

**The split is by role, and it follows `[[monitor-ui-workflow]]`'s own native-vs-subpixel rule:**
signage is short, precise and large → subpixel pixelfont. The rate table is long strings of small
print → **native**, which is also the *denser* option (a native row is 3 subpixels tall; a pixelfont
1x row is 6). Rendering the table at 1x would cost a whole 2x signage line for a worse-looking table.

| band | cell rows | subpixel y | content |
| --- | --- | --- | --- |
| bar | 1–2 | 1–6 | red |
| `THE CAGE` @2x | 3–6 | 7–18 | white, centred (69 of 72) |
| bar | 7–8 | 19–24 | red |
| `METAL IN` @2x | 9–12 | 25–36 | white, centred (71 of 72) |
| `CASH OUT` @2x | 13–16 | 37–48 | white, centred (69 of 72) |
| rate table | 18–21 | 52–63 | **native**, one row per `cage_rates.DENOMS` entry |
| bar | 23–24 | 67–72 | red |

Draw the subpixel canvas, `cv:render()`, **then** write the native rows on top — that is the real CC
order (`[[monitor-ui-workflow]]`) and what `slot.lua` does with its header.

**The rate table keeps its existing contract**, restyled only:

- Source of truth stays `cage_rates.DENOMS`; the row loop stays.
- Keep the `("%-9s%5s"):format(d.label, "$" .. d.value)` alignment — it is what keeps the `$` column
  straight regardless of label width.
- **The `≤6 denominations` ceiling moves.** `cage_rates.lua` carries a CEILING note pinned to
  `row = 13 + i` colliding with the bar at row 20. The new table starts at row 18 with the bottom bar
  at row 23, so the ceiling is now **4 denominations** (rows 18–21). `DENOMS` ships exactly 4
  (copper/iron/gold/diamond) so nothing breaks today — but **`cage_rates.lua`'s CEILING comment must
  be updated in the same commit**, or the next person adds a 5th metal and it lands on the bar.
  This is a real tightening and it is the price of the 2x signage.
- Set each row's `setBackgroundColor` to the black behind it so it seams cleanly.

## Component 5 — `tools/font-preview.html`: the review surface

Self-contained page (no CDN — the deploy loop never sees it; it is not in `src/`). Per
`[[monitor-ui-workflow]]` step 3, it renders **the actual Lua layout**, and it is what the owner's
glyph review happens in. Two panels:

1. **Specimen** — every glyph in `M.BIG` (letters, digits, punctuation) at 1x and 2x, on a grid,
   labelled with its width. Plus the `$` glyphs and `M.WIN`. This is where a bad `S` gets caught.
   Include the alphabet as running text (`THE QUICK BROWN FOX…`, `METAL IN - CASH OUT`) so glyphs are
   judged **next to each other**, not in isolation — that is where pixel fonts actually fail.
2. **Screens** — the slot advert (30×72) and the cage advert (72×72) side by side, each with an
   `encodeCell` **truth panel** beside it (port of `subpixel.lua`'s `encodeCell`, same as
   `slot-preview.html`). The cage's native rate rows are a browser text overlay — native `write` is
   not subpixel and not subject to `encodeCell`.

The glyph tables in the page are a **transcription** of `pixelfont.lua`'s, which is a duplication
risk: if the owner redraws a glyph in the preview, it must land in the Lua. Mitigate by keeping the
JS glyph table a verbatim paste of the Lua rows and nothing else — no reformatting.

## Component 6 — offline PNG verify

`[[monitor-ui-workflow]]` step 5, non-negotiable before deploy. A luajit harness that `require`s the
**real** `subpixel.lua` + `pixelfont.lua` + `slot_style.lua`, calls the **real**
`slot_advert.draw` / `cage_advert.draw` against a stub monitor
(`{ getSize, setCursorPos, blit, write, setBackgroundColor, setTextColor, setPaletteColour, clear }`),
dumps `cv.buf`, and renders it to PNG — **through `encodeCell`, not the raw buffer.** The raw buffer
hides the cell-straddle bug because it is not collapsed to 2 colours per cell; that is exactly how
the phantom corner bulb survived.

The PNG shows the subpixel layer only (native overlays are not in `cv.buf`), so reason about the
cage's rate table separately. Gotcha from the KB: luajit's `io.open` wants a Windows path, not
`/c/…`; write to the cwd.

## Out of scope

- **Do not redraw `M.BIG`'s digits** or `M.WIN`. Shipped, owner-approved, in-world verified.
- **Do not touch `slot.lua`'s play loop, `topLayout`, or `cage.lua`.** `slot.lua` changes only by
  deleting the constants that move to `slot_style` and requiring it back.
- **Do not delete `M.SIGN_SM`.** It has zero call sites and its "pairs with 1x digits" comment is
  unverified (it is 10 tall; `BIG`@1x is 6). It is the owner's drawing. **File it, do not fix it** —
  add a note to `todo.md` and leave the glyph alone.
- No animation anywhere. No lowercase. No new stations. No economy changes.

## Parallel work — a second session is live on this repo

Another session is building multiplayer (`lib/mp_econ`, `card.readAll`, a 2–4 player game).

- **Branch:** everything lands on `feat/pixelfont-alphabet`. **Nothing goes to `main` until merge.**
- **SDD ledger:** `.superpowers/sdd/progress-alphabet.md` — **not** `progress.md`, which is contended.
- **Ours:** `src/lib/pixelfont.lua`, `src/slot/slot_style.lua`, `src/slot/slot_advert.lua`,
  `src/cage/cage_advert.lua`, `src/cage/cage_rates.lua` (comment only), `test/`, `tools/`, `docs/`.
- **Theirs:** `src/lib/card*.lua`, `src/lib/mp_econ.lua`, a new game folder.
- **Shared, expect conflicts:** `src/packages.lua`, `todo.md`, `README.md`. Touch them **last, in one
  small commit**, and **rebase before merging**. `packages.lua` needs exactly one line
  (`slot_style` in the `slot` package) — `subpixel` and `pixelfont` are already in both packages, so
  the alphabet itself needs no manifest change at all.

## Verification

1. `test/test_pixelfont.lua` green — existing 27 assertions untouched plus the new ones.
2. `luajit -bl` syntax pass on every changed `.lua`.
3. Offline PNG of both adverts, rendered through `encodeCell`, eyeballed against the layout tables.
4. Owner reviews the specimen panel in `tools/font-preview.html` and redraws any glyph he dislikes.
5. Per-task + whole-branch code review.
6. **In-world is the owner's, after merge+push** (the deploy loop pulls from the repo; mind the
   ~5-min CDN lag). What to look for: walk up to the slot and the cage, walk away, and read the idle
   face from across the floor — which is the entire point of the feature.
