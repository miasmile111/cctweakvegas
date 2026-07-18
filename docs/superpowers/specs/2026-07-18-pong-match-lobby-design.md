# Pong rebuild — the durable match/lobby framework

**Date:** 2026-07-18
**Status:** design approved, ready for planning
**Supersedes nothing.** Builds on `lib/mp_econ` (2026-07-17), which stays the money engine.

## Why

Pong was the project's first prototype. It predates the idle framework, the economy, the card
session model and the monitor-UI workflow, and it shows: hardcoded computer-side redstone, a
debug-harness UI (`GO` / `END` native buttons), no lobby, no win condition, no reset, an 18-line
advert stub. Its controls stopped working entirely when the plates moved onto a **redstone relay**.

The rally physics is the only part worth keeping. Everything around it is replaced.

The deliverable is **not** a better pong. It is the **reusable multi-screen match framework** every
future 2–4 player game sits on — pong is its first consumer and its proof.

## Scope

**In:**

- `lib/match.lua` — the lobby→play→results state machine, owns `mp_econ`, owns the event pump.
- `lib/lobby.lua` — the lobby screen: seats, per-seat touch READY, gated GO.
- `lib/counter.lua` — eased delta-tinted balance counter, extracted from `cage.lua`.
- `lib/controls.lua` — redstone abstraction over a relay peripheral or computer sides.
- `mp_econ.reset()` — return `phase` from `"done"` to `"lobby"`.
- `pong/pong.lua` — rewritten as physics + rally render + first-to-5, driven by `match`.

**Out (deliberate):**

- **Screen art.** All three screens ship **debug-grade native text** this session. Visual design is a
  parallel effort on the golden-standard loop (`kb/monitor-ui-workflow.md`) against the UI
  contract in this document. The framework must not assume its final look.
- **Refactoring `cage.lua` to adopt `counter.lua`.** The cage is shipped and in-world verified;
  touching it for a cosmetic dedup risks the only working `$`-exit for zero user-visible gain. One
  session of duplication, deliberately. The cage adopts it next time it is open.
- **4-player pong.** The framework supports N seats; pong builds 2. See "Deferred".
- **The pot journal.** Owner's call 2026-07-18: a chunk unload mid-match only realistically happens
  on a full server crash. Accepted risk, not closed. (Was listed as "must close before an MP game
  takes real players" in `todo.md` — that judgement is hereby downgraded, not forgotten.)
- **`pong_advert.lua` art.** Stays the 18-line stub this session; it is part of the later art pass.

## Architecture

```
idle_runner.run{ name="pong", monitor=mon, play = match.run{...} }   ← station framework unchanged
                          │
                    lib/match.lua        owns mp_econ, the phase loop, the results screen
                    ┌─────┴─────┐
              lib/lobby.lua   pong.play(ctx)
                    │
              lib/controls.lua ── relay peripheral or computer sides
                    │
              lib/counter.lua  ── eased delta-tinted $ (results screen)
```

Layer rule, unchanged from the economy's: `match` consumes `mp_econ`, never `wallet` directly.
`mp_econ` remains the sole owner of ante/pot/payout semantics.

### `match.run` — the game-facing API

```lua
match.run{
  title      = "PONG",
  seatLabels = {"LEFT", "RIGHT"},   -- lobby rows AND the free-game result text
  minSeats   = 2,                   -- carded seats that make a pot (passed to mp_econ)
  maxSeats   = 2,
  ante       = 10,
  target     = 5,                   -- informational; the game decides when it is over
  controls   = ctl,
  drives     = {...},               -- passed through to mp_econ
  play       = pong.play,           -- (ctx) -> { [seatIndex] = score }
}
```

Returns `"sleep"` or `"quit"` — exactly the contract `idle_runner` already expects, so `pong.lua`'s
bottom-of-file call barely changes.

### The state machine

```
LOBBY ──GO (live only when every seat is READY)──> PLAY ──game returns scores──> RESULTS
  ▲                                                  │                             │
  │                                     zone empties │                             │ GO (skip)
  └──────────────────────────────────────────────────┴─────────────────────────────┘
                                                        or RESULT_TICKS timeout
```

- **Zone empties in any state** → resolve any live pot, return `"sleep"`. `idle_runner` draws the advert.
- **READY flags clear on every entry to LOBBY.** Ready is **per-match consent, never a sticky flag** —
  if it survived a match, a player who walked away is still "ready" and the next GO antes their card
  for a game they are not at. This is a money-correctness rule, not a UI preference.
- **`mp_econ.reset()`** clears `phase → "lobby"`, `pot = 0`, and every seat's `antedId`/`anted`.
  Today `"done"` is terminal, which is the observed "the game did not reset" bug.

### `play(ctx)` — the only thing a new game writes

```lua
ctx.win        -- the window to draw into
ctx.controls   -- the controls instance
ctx.seats      -- { {label=...}, ... }  seat 1 = left paddle
ctx.tick()     -- yields one frame; returns false when the match must abort
-- returns { [seatIndex] = score }
```

**`match` owns the event pump; `play` never calls `os.pullEvent`.** This is deliberate and is the
single most important boundary in the design. Event-pump re-entrancy is this repository's most
expensive recurring bug class (`[[event-pump-reentrancy]]`; the floppy-swap freeze cost a whole
session). A game author must not be able to get it wrong. `match` pumps, dispatches `monitor_touch`
and `disk`/`disk_eject` into `mp_econ.onEvent`, tracks presence, and hands `play` a bare tick.

`ctx.tick()` returning `false` means abort: the game returns its current scores immediately and
`match` resolves the pot.

## Money: the results screen replays a completed transaction

By the time RESULTS draws, **the money has already moved** — `mp_econ.start()` debited the ante at
GO, `mp_econ.finish()` credited the pot. The animation is therefore a **replay**, not a live
transfer, and must be driven from captured numbers:

- `match` captures each seat's balance **immediately before `mp_econ.start()`** as `balanceAtGO`.
- RESULTS animates `balanceAtGO → balanceNow` per seat.
- Loser: `100 → 90`. Winner: `90 → 110` — the winner's counter visibly climbs back across its own
  starting value, which is the readable "you got your ante back and then some".

Tint follows the cage's verified rule, lifted into `counter.lua`: **climbing = yellow/gold, falling =
pink, at rest = white.** Pink, not red — stock red is luminance 114 against a ~118 gold band and
vanishes; a cell holds only 2 colours so no outline can save it.

**A free (unstaked) match shows no counters at all** — just `LEFT PLAYER WON` / `RIGHT PLAYER WON`.
Nothing moved, so nothing animates.

### `lib/counter.lua`

Extracted verbatim-in-behaviour from `cage.lua`:

```lua
local c = counter.new{ value = 100 }
c.setTarget(90)     -- begins easing
c.step()            -- advance one tick
c.value()           -- current eased display value
c.tint()            -- YELLOW climbing / PINK falling / WHITE at rest
```

Pure and unit-testable — no peripherals, no drawing. Drawing stays with the caller so the later art
pass can render it any way it likes.

## Controls

Verified against tweaked.cc: peripheral type **`redstone_relay`**, CC:Tweaked **1.114.0+**, methods
**name-identical** to the built-in `redstone` API (`getInput(side)`, `getAnalogInput(side)`, …). A
source is therefore either the global `redstone` table or `peripheral.wrap(name)` — duck-type
identical, which is what makes this abstraction nearly free.

```lua
local ctl = controls.new{ cfg = CFG }
ctl.get("p1_up")   -- boolean
```

Logical names map to physical wiring **entirely in `pong.cfg`**, which is not in the package file
list and therefore survives `update pong`:

```
# source: "relay" (discovers the single redstone_relay by type) | a peripheral name | "computer"
source  = relay
p1_up   = left
p1_down = front
p2_up   = right
p2_down = back
```

Discovery follows `[[station-hardware-discovery]]`: `source = relay` finds the relay **by type**; an
explicit name in cfg always wins; no peripheral name is ever hardcoded in `pong.lua`. Fail loud at
boot if a configured source or a required input is missing.

Only **4 inputs** — READY moved to on-screen touch, so no edge detection is needed and paddles are
level-polled each frame.

### The local redstone wake is REMOVED

`wake_side` / `wake_level` (added 2026-07-17 in `c17d7f8`) existed only because the pong station had
no ender modem and so could not self-locate for GPS presence. **It has one now.** Pong wakes on hub
presence like the cage and the slot.

This deletion is load-bearing: with the plates on a relay, no *computer* side ever changes state, so
the old wake would read a line that can never move — it would have failed **silently**, looking
exactly like a dead station. Removing it also means **`idle_runner` needs no change at all**, which
keeps this branch away from the slot's lever and the shared idle machinery entirely.

## The UI contract (binding on the parallel design effort)

The framework is built against this element list; the visual design is built against the same list.
Neither blocks the other. **Geometry is fixed and formula-verified — do not re-derive it.**

**Canvas: 3×2 blocks @ `setTextScale(0.5)` = 57×24 cells = 114×72 subpixels.**
(From `ServerMonitor.rebuild`: `cols = round((3 − 0.3125)/(0.5·6/64))`, `rows` likewise. See
`kb/monitor-resolution.md`.)

**Palette: 16 slots, global to the monitor.** The palette, not screen space, is the scarce resource.
A station affords roughly **one** bevel ramp shared by all its buttons. Steel (white 240 /
lightGray 153 / gray 76) is the only true 3-step ramp in CC's stock 16.

**A cell holds at most 2 colours** (`encodeCell`: most-frequent → bg, first-different → fg,
everything else collapses to bg). Any design that ignores this renders as mud.

**Native cell-text always layers over the entire subpixel canvas** — a subpixel popup can never
cover native text. Gate the text instead. (The cage's empty-deposit toast bug.)

### Elements, per screen

**LOBBY**
- Title (`PONG`) and the ante (`ANTE $10`).
- One row per seat, 2 seats: seat label (`LEFT`/`RIGHT`), card id or `anon`, balance or a status
  word (`OFFLINE` / `BAD CARD`), and a **READY touch button beside that seat's id**.
- A **GO button**, visibly inert until *every* seat is READY, then live. The disabled and enabled
  states must be unmistakably different — this button moves money.
- A transient message line for deny reasons (`HUB OFFLINE — nobody charged`, `SEAT 2: … — all
  antes refunded`).

**PLAY**
- The rally: 2 paddles, ball, centre net, and the score. **First to 5.**
- **No buttons.** The `GO`/`END` debug buttons are removed; this screen is the game only.

**RESULTS**
- Per seat: card id + the animated counter (`balanceAtGO → balanceNow`, gold up / pink down).
- Free match: `LEFT PLAYER WON` / `RIGHT PLAYER WON`, no counters.
- A **GO button at the bottom** that skips straight back to LOBBY for a fast rematch.
- Auto-returns to LOBBY after `RESULT_TICKS` (~8s) if untouched.

## Error handling

- **Hub unreachable at GO** → `mp_econ` denies with `reason = "timeout"` → `HUB OFFLINE — nobody
  charged`. Nobody is debited. Fail-closed on money, unchanged.
- **A seat cannot cover the ante** → `mp_econ` refunds every ante already taken (rule 1: never a
  partial pot) and names the seat.
- **A card ejected mid-match** → the pot pays the **anted id**, not the live card (`mp_econ` rule 2).
- **A card inserted mid-match** → spectator; seats lock at ante.
- **Zone empties mid-match** → resolve, credit whoever is ahead, sleep. The ante is forfeit; that is
  what "forfeit" means when the player who walked off was losing.
- **Missing relay / missing configured input** → fail loud at boot with the missing logical name.
- **Missing monitor / drive** → unchanged existing behaviour.

## Testing

Unit tests (`luajit`, pure modules, following the existing `test/` pattern):

- `counter.lua` — easing converges, tint direction, no overshoot, equal values read white.
- `controls.lua` — cfg parsing, relay-vs-computer source selection, missing-input error, name-wins-
  over-discovery.
- `match.lua` state machine — phase transitions, READY cleared on every LOBBY entry, GO gated until
  all ready, abort path resolves the pot, `balanceAtGO` captured before `start()`.
- `mp_econ.reset()` — `done → lobby`, pot zeroed, `antedId` cleared; existing 77 tests stay green.
- Pong scoring — first to 5 terminates; the rally physics keeps its current behaviour.

`luajit -bl` syntax pass on every changed file. Peripheral I/O is not unit-tested (unchanged repo
practice); it is covered by the in-world checklist.

### In-world checklist (post-merge, per the deploy loop)

1. `update pong`, reboot. Station wakes on **presence** (walk up) — no plate needed.
2. Paddles respond on all four relay inputs; `pong test` (retained) identifies them.
3. 0 cards → both READY → GO → **free rally**, first to 5, results says `LEFT/RIGHT PLAYER WON`, no
   counters, nobody debited.
4. 1 card → free match, **no debit**.
5. 2 cards → READY both → GO → both debited, `POT $20` → first to 5 → results counters drain the
   loser and climb the winner → winner credited.
6. GO on the results screen returns to LOBBY immediately; **READY is cleared**, not sticky.
7. Leave results untouched → auto-returns after ~8s.
8. Eject a card mid-match → the pot still pays the anted id.
9. Insert a *different* card mid-match → spectator, gets nothing.
10. Seat 2 insufficient → GO → **seat 1 is not out of pocket** (refund path).
11. Hub down → GO → `HUB OFFLINE`, not `INSUFFICIENT`, nobody debited.
12. Walk away mid-match → the pot resolves, station sleeps to the advert.
13. **Regression: slot and cage still work.** `mp_econ` gained `reset()` and `counter` was extracted;
    the slot's lever wake and the cage's `$` flow are the things this branch could plausibly break.

## Deferred

- **4-player pong / 4 seats.** `match` and `mp_econ` are N-seat already; a relay has exactly 6 sides,
  so 4 paddles + nothing else fits one relay. `controls` will accept qualified
  `relay_1:left` names so a second relay is additive, but neither is built now.
- **The art pass** on all three screens plus `pong_advert.lua`, on the golden-standard loop.
- **Cage adopting `counter.lua`.**
- **The pot journal** (accepted risk, above).
- **`hub_version` / ping** — unrelated to this branch, still outstanding in `todo.md`.

## Open question, to be answered in-world, not assumed

**Does a `redstone_relay` input change raise the computer's `redstone` event?** tweaked.cc does not
say. Nothing in this design depends on it — presence is the wake and paddles are polled every frame
— but it is worth one deliberate check, because if a future design *does* lean on it, the failure
mode is silent (a station that simply never wakes).
