# Slot Machine — Design Spec

**Date:** 2026-07-15
**Project:** cctweaked — CC:Tweaked monitor minigames (Seansemperfi's Atlas Server, MC 1.21.1 Forge, CraftOS / Lua 5.1)
**Status:** Approved design, pre-implementation

## Summary

A diegetic slot machine rendered on **two in-world advanced monitors** driven by one
computer. Player taps a touchscreen SPIN button on the front monitor; three reels spin on the
top monitor and land on a result. v1 is a **pure spin** (no credits/betting): tap → reels
spin → WIN or LOSE.

A secondary, explicit goal: harvest the **teletext subpixel drawing hack** into a reusable
library + `cc-lua` skill reference, so future minigames reuse it. This spec is as much about
establishing that reusable visual-design pattern as about the game.

## Diegetic-input note

The project's normal rule bans `monitor_touch` as a gameplay control. The user has clarified
that the intent of the rule is "no terminal GUI / keyboard, players don't linger in a UI" — a
**touch on an in-world monitor is physical-world interaction and is allowed**. This game
deliberately uses `monitor_touch` on the front monitor as its sole control. (A keyboard quit
is still fine for admin.)

## Hardware / wiring

- 1 computer, 2 **advanced** monitors (16-color), each on a **wired modem + networking cable**
  so they don't consume computer sides and are found by network peripheral name.
- **Top monitor:** 1 block wide × 2 blocks tall (portrait). ≈ 15×20 characters at
  `textScale 0.5` (confirmed at runtime via `getSize` — never hardcoded).
- **Front monitor:** 1×1 block. ≈ 15×10 characters at `textScale 0.5`.
- **Control:** `monitor_touch` on the front monitor = spin trigger. Whole screen is the target.

Exact character dimensions depend on the build and text scale; the program reads them at
runtime and lays out proportionally. The `test` submode prints real values.

## Files

```
src/
  slot.lua              the game (requires subpixel)
  lib/
    subpixel.lua        reusable teletext 2x3 subpixel canvas (canonical artifact)
.claude/skills/cc-lua/
  references/
    subpixel-drawing.md  documents the hack so future games reuse it
docs/superpowers/specs/
  2026-07-15-slot-machine-design.md   (this file)
```

**In-game import:** two files (`subpixel` then `slot`). `slot.lua` loads the lib via
`require("subpixel")` (or `dofile` fallback — see Open questions). Deploy is HTTP-only
(pastebin/gist → `pastebin get` / `wget`), re-hosted after each edit, per the cc-lua skill.

## Module 1 — `subpixel.lua` (reusable)

The reusable "hack." CC drawing characters **128–159** each render a **2×3 subpixel** block:
the character's **foreground** color fills the "on" subpixels, **background** fills the "off"
ones. So any 2×3 subpixel block is expressible in exactly two colors. `term.blit(text, fg,
bg)` writes a full row of such cells in one call (fast, flicker-light).

The module wraps a monitor (or any term-like target) as a virtual pixel canvas of
`(cols*2) × (rows*3)` pixels:

- `new(target)` → canvas bound to a monitor; reads `getSize()`, allocates buffer.
- `:clear(color)` — fill whole buffer.
- `:setPixel(x, y, color)` — 1-indexed subpixel set (bounds-checked, silent no-op off-canvas).
- `:fillRect(x, y, w, h, color)`
- `:drawSprite(x, y, sprite)` — `sprite` = 2D array of color indices (or a sentinel for
  transparent), blitted onto the buffer.
- `:render()` — for each character cell, gather its 6 subpixels, reduce to the **two dominant
  colors**, compute the char (`128 + bitmask`, honoring the bottom-right "invert" bit so the
  full 32-glyph range is used), and `term.blit` **row by row**. Wrap in a `window` /
  `setVisible` flush for flicker-free output.

**Symbols are data:** each reel icon (seven, cherry, bell, bar) is a small color-index array
consumed by `drawSprite`. New icons = new data, no new code.

**Pure, testable core:** the subpixel-group → (char, fg, bg) reduction is a pure function of 6
color indices. It is unit-testable in plain Lua 5.1 without CC APIs.

### Reference doc

`.claude/skills/cc-lua/references/subpixel-drawing.md` explains the 128–159 encoding, the
2-colors-per-cell constraint, the `term.blit` row technique, and how to reuse `subpixel.lua`.
Linked from the skill so every future minigame can pick it up.

## Module 2 — `slot.lua` (the game)

### Config + test submode

Top-of-file config block maps **which network monitor name is the top (play) monitor and
which is the front (button) monitor**, plus text scales. `slot test` submode: lists attached
monitors, prints each one's `getSize`, labels them live, and echoes `monitor_touch` coordinates
so the user can confirm the mapping without editing blind. (Mirrors `pong test`.)

### Top monitor — play display (portrait)

Vertical layout, top→bottom:

1. **Reserved block** (upper monitor block) — blank/dark in v1. Future high-earnings
   scoreboard goes here, with a **margin gap** below it separating it from play.
2. **Marquee** — title `LUCKY` (or chosen text) on a colored bar.
3. **Reel grid** — 3 vertical reels side by side, separators between. Center row = the
   **payline** (lit); rows above/below dimmed to read as symbols scrolling past.
4. **Bulb columns** — a column of lamps down each side that **chase** during a spin.
5. **Result banner** — full-width, flips **WIN!** (green flash) / **LOSE** at stop.

Reel symbols drawn via `subpixel.lua` sprites. Banner/marquee text may use plain glyphs.

### Front monitor — SPIN button (1×1)

**Beveled 3D button** filling the screen: raised look via light top/left edge + dark
bottom/right edge; pressing **inverts the bevel** (pushed-in). States:

- **idle** — bright red `SPIN`, chasing light border in attract mode.
- **pressed / locked** — while reels spin: bevel inverted or greyed, label `WAIT` / `· · ·`,
  taps ignored; the **chasing border keeps animating** around the perimeter.

The chasing border reuses the same bulb-animation logic as the reel columns.

### Game loop

Single `os.pullEvent` loop:

- `monitor_touch` on the **front** monitor **and not already spinning** → begin spin: pick each
  reel's final symbol via RNG (`math.random`, seeded once from `os.epoch("utc")`).
- `timer` tick (≈20 fps): advance reel scroll offsets; decelerate; **staggered sequential
  stop** (reel 1, then 2, then 3) snapping each to a symbol boundary with easing. Animate
  button border + reel bulb columns each tick. Redraw both monitors (flush via window).
- When all three reels have stopped → compare the three **center-row** symbols → all equal =
  **WIN** (green banner flash + celebratory bulb animation), else **LOSE**. Return button to
  idle; accept the next touch.
- Keyboard `Q` / Ctrl+T = admin quit (not gameplay). Cleanup: clear both monitors, restore
  text scale, restore terminal.

### Win rule (v1)

Three matching symbols on the center payline = WIN. Each reel's landing symbol is independent
uniform RNG. No paytable tiers, no near-miss weighting in v1 (candidates for later).

## Symbols (v1)

Four icons: **seven, cherry, bell, bar**. Each a subpixel sprite (color-index array). Sized to
fit one reel cell-group on the ~15-wide top monitor (≈ 4–5 chars wide → 8–10 subpixels).

## Explicitly deferred (YAGNI for v1)

- Credits / betting / bet sizing.
- High-earnings scoreboard on the top monitor's reserved block (space is reserved now).
- Paytable tiers, partial wins, near-miss weighting.
- Sound (speaker peripheral) — could be added if one is attached.

## Verification approach

- **Pure functions** — subpixel group→char reduction, win-check, reel snap math — unit-tested
  in plain Lua 5.1 locally (no CC APIs needed).
- **Visual / integration** — in-game: import `subpixel` + `slot`, run `slot test` to confirm
  monitor mapping + sizes + touch coords, then play. Iterate via re-host/re-import loop.
- Guard optional hardware (`peripheral.find`, monitor present) with clear `error`/`print`.

## Open questions (resolve during planning)

1. **Lib loading:** `require("subpixel")` vs `dofile("subpixel.lua")` — pick the one that works
   cleanly given CraftOS `package.path` and a two-file import into the same directory. Fallback:
   inline a copy of the lib into `slot.lua` if two imports prove awkward for the user.
2. **Exact 128–159 bitmask/invert mapping** — confirm against tweaked.cc + a live in-game check
   before finalizing the reduction function.
3. **Marquee title text** — `LUCKY` placeholder; user may rename.
