# Multiplayer economy engine — design

**Date:** 2026-07-17
**Status:** approved, ready to plan
**Scope:** the *engine* that makes future 2–4 player staked games easy. Pong is a **debug harness**,
not a deliverable. No pong polish, no advert, no pixelfont, no art.

Read first: `kb/economy.md` (the economy reference), `[[station-hardware-discovery]]`,
`[[event-pump-reentrancy]]`, `[[open-every-modem]]`.

## Why now

`todo.md`'s backlog item 1. Two things stand between the floor and any multiplayer game, and they
are the same fix wearing two hats:

1. **`card.read()` takes the FIRST drive with a disk** (`card.lua:8`, `mountPath()`). Single-card-
   per-station is baked into every layer above it. This is the actual blocker.
2. **`sp_econ` + `cage_econ` are instances 1 and 2** of the same card-session machinery.
   `mp_econ` is the rule-of-three trigger (`cage_econ.lua:6-8` says so in a comment).

The unlock: **a card session is one card on one drive.** Bind it to `nil` and you have today's
single-card gateways, unchanged. Bind N of them to N *named* drives and you have multiplayer. The
extraction and the blocker are one piece of work.

## Architecture

```
GAME      pong.lua (debug harness: rally + GO/END touch + score)
GATEWAY   sp_econ    (1 card, house paytable)   <- rebuilt on card_session
          cage_econ  (1 card, debit/credit)     <- rebuilt on card_session
          mp_econ    (N seats, pot)             <- NEW
CORE      card_session (ONE card on ONE drive)  <- NEW, the extraction
          card         (readAll / read(drive))  <- the blocker, fixed
          wallet . ledger                       <- UNTOUCHED
```

`wallet` and `ledger` do not change. The pot is existing `debit` + `credit` calls.

## Decisions (owner-set, 2026-07-17)

| Question | Decision |
| --- | --- |
| First MP game | **Staked pong**, existing station, as a **debug harness only** |
| Mid-match card pull | **Ante is forfeit.** The money left at ante time; the card is a mirror |
| Seat identity | **Locked at ante.** A card inserted mid-match is a spectator — no join, no takeover |
| Match start | **Quorum + an explicit GO control** |
| GO control | **`monitor_touch` button** — diegetic, costs no side, keeps stations wire-it-and-run |
| Anonymous seats | **Play, cannot win the pot** |
| Anon wins the match | **Best carded seat takes the pot.** Anon takes the match; money stays among payers |

### Why "the card is a mirror" dissolves the mid-match-pull problem

The owner's instinct ("whoever pulled should lose the money") is right, and the awkwardness he named
("their card is no longer in the drive") is smaller than it looks: **`wallet.debit` already hit the
hub ledger at ante time.** `score` on the floppy is a display mirror only (`kb/economy.md` lesson 5).
An empty drive costs the engine nothing on the money side — it only costs the *display*.

So `mp_econ` captures the anted id per seat and pays **that** id. This is `sp_econ`'s `stakedId`
lesson (`kb/economy.md` lesson 2) generalized to N seats, and it is why "seat locked at ante" is not
an extra rule — it is the same rule the economy already lives by.

## `card.lua` — the blocker

Additive. Every existing call site is unaffected (`drive` defaults to nil = first drive = today).

```lua
card.drives()                    -- -> { "drive_0", "drive_1" }  ALL drive peripherals, SORTED
card.read(drive)                 -- -> { id, score } | nil       nil drive = first WITH a disk
card.readAll()                   -- -> { { drive, id, score }, ... }  only drives holding a card
card.write(id, score, drive)     -- -> true | false, reason
card.writeMirror(score, drive)   -- -> true | false, reason
card.isCardEvent(ev)             -- unchanged
```

- **`drives()` returns EVERY drive, disk or not** — because **a drive is a seat, and an empty seat
  still exists.** (An earlier draft filtered to drives holding a disk; that is right for `readAll`
  and wrong for seat discovery, where it would make a cardless seat vanish from the station rather
  than show up as an anonymous player.) `readAll()` does the filtering.
- **`drives()` sorts by name** so seat order is stable across reboots. Names themselves are NOT
  stable across identically-built stations (`[[station-hardware-discovery]]`) — that is what the
  cfg override is for; sorting only guarantees *this* station is consistent with itself.
- `read(nil)` scans for the first drive with a disk AND a mount path — today's `mountPath()`
  behaviour exactly, so every existing caller is unaffected.

## `card_session.lua` — the extraction

One card, one drive. The machinery both gateways duplicate today:

```lua
local s = card_session.new{ drive = nil }   -- nil = first drive (sp_econ, cage_econ)
                                            -- "drive_1" = that drive only (mp_econ seats)
s.player     -- id string | nil (anonymous)
s.balance    -- last known hub balance | nil
s.offline    -- hub unreachable (NOT the same as broke)
s.refresh()      -- read card -> wallet.query -> mirror write; sets player/balance/offline
s.onEvent(ev)    -- a card event FOR THIS DRIVE -> refresh()
s.noteHub(reason)-- record a hub call the CALLER made: offline = (reason == "timeout")
s.setBalance(b)  -- displayed balance + card mirror, after a hub write the caller made
s.status()       -- { player, balance, offline }
```

- **`onEvent` filters by drive.** A `disk` event carries the drive's name (`ev[2]`); a session bound
  to `drive_1` ignores `drive_0`'s. Without this, one card insert at a 4-seat station fires **four**
  `wallet.query` round-trips — three of them re-reading a card that did not change.
- **`noteHub` is why `offline` can live in the session** rather than being duplicated per gateway.
  `sp_econ.tryBet` and `cage_econ.tryDebit` both make hub calls the session did not make, and both
  must render the result honestly; they hand the reason back instead of keeping a second flag.

`new()` calls `wallet.flush()` once (bank anything outboxed while the hub was down) and `refresh()`.

> **When N sessions exist, `wallet.flush()` must run ONCE per station, not once per seat.**
> `mp_econ` flushes; `card_session.new` takes `flush = false` from it. A 4-seat station calling
> flush four times at boot is four rednet round-trips where one would do — and with the hub down,
> four `LOOKUP_BACKOFF` windows serialized into the boot path (`wallet.lua:123`).

### The drift to reconcile (do NOT copy it forward)

`sp_econ` has an **`offline`** flag; `cage_econ` does not — it folds hub-unreachable and
insufficient-funds into one `msg` string. `sp_econ` is the correct one: it exists *because* telling a
player holding $500 that they are `INSUFFICIENT` is a lie the machine tells about money (the
2026-07-17 freeze-fix branch, `kb/economy.md`).

**`card_session` carries `offline`, and `cage_econ` adopts it.** This closes, for free, the filed
`cage_econ.tryDebit` bug where a dead card id renders `NEED $x` (todo.md, cage follow-ups).

Out of scope for the extraction: `sp_econ.tryBet/settle` and `cage_econ.tryDebit/deposit/refund` stay
where they are. Those are the *shapes* that differ (bet/settle vs debit/credit) — only the session
underneath is shared. That is exactly why they were never built on each other.

## `mp_econ.lua`

```lua
local e = mp_econ.new{
  drives   = nil,   -- nil = auto-discover (sorted). cfg override for seat order.
  minSeats = 2,
  maxSeats = 4,
  ante     = 10,
}
```

### State

```
phase = "lobby" | "playing" | "done"
seats[i] = {
  drive   = "drive_0",
  session = <card_session>,
  antedId = nil,   -- id DEBITED this match. nil = seat did not pay (anon, or lobby)
  anted   = 0,     -- $ this seat put in
}
pot = 0
```

### API

| Call | Contract |
| --- | --- |
| `e.onEvent(ev)` | Fold into every seat's session. Call for EVERY event in the play loop. |
| `e.cardedCount()` | How many seats hold a readable card. |
| `e.canStake()` | `cardedCount() >= minSeats`. For the UI only — **GO is always live.** |
| `e.start()` | The GO edge. Returns `"staked"` \| `"free"` \| `"deny"`, reason, seatIndex. |
| `e.finish(scores)` | Resolve. `scores` = `{ [seatIndex] = number }`. Returns a result table. |
| `e.status()` | `{ phase, pot, seats = { { player, balance, offline, anted } } }` |

There is deliberately **no `abort()`/`voidMatch()`**. It would have zero callers — the
rule-of-three trap in reverse, a policy guessed rather than proven. A match that must end early ends
via `finish()` with the scores as they stand, which is what "the ante is forfeit" already means.

> **An anonymous seat is invisible, so "occupancy" cannot gate the GO button.** A seat is a drive; a
> human standing at one with no card emits nothing the computer can read. So there is no
> `canStart()` quorum — **GO is always live**, and `start()` decides staked-vs-free from the only
> thing the station can actually observe: how many cards are in. `minSeats` therefore means *the
> minimum number of CARDED seats that makes a pot*, not a quorum of bodies.

### `start()` — the ante

**Staked iff `>= 2` carded seats.** One carded seat would ante and win its own ante back — pointless,
so that is a `"free"` match with no debit. Zero carded seats: also `"free"` (today's pong).

Ante is **all-or-nothing across carded seats**:

1. Debit each carded seat in turn (`wallet.debit`).
2. **Any failure ⇒ refund every already-debited seat** (`wallet.credit` the anted id) and return
   `"deny"` with the failing seat index and reason (`"insufficient"` \| `"offline"` \| `"unknown"`).
3. All succeed ⇒ `pot = ante * cardedCount`, seats lock (`antedId` captured), `phase = "playing"`.

This is `kb/economy.md` lesson 6's ordering invariant (stock check → debit → move → refund-if-short)
with "the pot is complete" as the stock check. A partial pot is the multiplayer duplication bug: two
players paid, one didn't, and somebody is about to win money that was never all there.

> **The refund uses `wallet.credit`, which OUTBOXES on a hub timeout** — so a refund is never lost
> even if the hub died mid-ante. That is the right guarantee here (the player is owed that money,
> and the station's loop flushes it), and it is exactly why `credit` and not `creditNow`.

### `finish(scores)` — the payout

```lua
{ matchWinner = <seatIndex>,     -- highest score of ALL seats (may be anon)
  potWinner   = <seatIndex|nil>, -- highest score among CARDED seats
  potShare    = { [seatIndex] = amount },  -- what each seat was credited
  pot         = <amount> }
```

- Pot pays the **best-scoring carded seat**. An anon may take `matchWinner` and no money.
- **Ties among carded seats:** split `floor(pot / n)` each, **remainder to the lowest seat index**.
  Integer money only — a fractional balance would live in the ledger while every screen showed a
  different rounded number (`wallet._wholeAmount`'s comment, `wallet.lua:29-43`).
- Credit goes to `antedId`, **never** `session.player`. The drive may be empty or hold a stranger.
- A `"free"` match: `finish` still returns `matchWinner` (glory) with `pot = 0` and no credits.
- `phase = "done"`. Next `start()` clears seats.

### A live pot must never leave the loop unresolved

`pong.lua:160` returns `"sleep"` the moment the zone empties — "no round to finish". **With a pot on
the table that is a money bug:** both players are debited, `finish` is never called, and the $ simply
evaporates from the floor. `sp_econ`'s slot never had this problem because a spin resolves within one
tick of the lever; a pong match lasts as long as the players do.

**Rule: `play()` may not exit with `phase == "playing"`.** On zone-empty (and on the operator's `Q`),
pong calls `finish(scores)` first and *then* sleeps. Whoever was ahead takes the pot — which is
exactly what "the ante is forfeit" means when the person who walked off was losing.

> **Known gap, filed not fixed: a chunk unload or a crash mid-match evaporates the pot.** An unloaded
> chunk's computer is CLOSED, not sleeping (`[[unloaded-chunk-is-the-cheapest-sleep]]`) — no exit
> path runs, so `finish` never happens and the debited $ is gone. The window is small (a player
> present means the chunk is loaded, and the supervisor restarts a crash) and the fix is real
> persistence — a pot journal like `wallet`'s outbox, replayed at boot. **Out of scope for the debug
> harness; it must be closed before an MP game takes real players.** Note it in `todo.md`.

### What `mp_econ` does NOT own

The GO/END **buttons' pixels**. `mp_econ` is economy state; the game renders it. The engine exposes
`status()`; `pong.lua` decides where a button sits and calls `start()`/`finish()` on a touch. Keeping
hit-testing out of the engine is what lets the next MP game have a completely different layout.

## Seat ↔ drive binding

The cage's solved pattern (`[[station-hardware-discovery]]`), verbatim:

- **Discover by TYPE**, never by hardcoded name. CC burns `<type>_<n>` indices on attach/detach; the
  first cage's droppers came up **1-4, not 0-3**. Two identically-built pong stations will not agree.
- Seat order = `card.drives()` sorted. Deterministic for a given station.
- **`pong.cfg` overrides**, and cfg always wins over discovery — it is the ONLY place per-station
  wiring belongs, because `update pong` **overwrites `pong.lua`** and `.cfg` is not in the package
  file list:
  ```
  drives=drive_0,drive_1     # seat order, left paddle first
  ```
- Drives may be direct-attached or on the wired modem network.
  **In-world unknown, must be verified:** does `getMountPath()` work for a drive reached over a wired
  modem, and do two drives on one computer both mount? If a network drive does not mount, the seats
  must be direct-attached and pong's side budget gets tight (4 plates + drives). This is the one
  hardware assumption the design rests on and it is a 2-minute check.

## Pong — the debug harness

Minimum to exercise the engine. Explicitly NOT a good pong.

- **2 disk drives** = 2 seats. Seat 1 = left paddle, seat 2 = right.
- **Native text** header: `seat id · balance · POT`. No subpixel, no pixelfont — the alphabet does
  not exist and is another session's job (todo.md).
- **Touch `GO`** → `e.start()`. **Touch `END`** → `e.finish{ [1]=ls, [2]=rs }`, highest score takes
  the pot. Pure debug: pong has no real win condition and this session is not the one that gives it
  one.
- The existing rally (`physics()`/`draw()`) is untouched. `ls`/`rs` already exist and are the scores.
- Free rally (0–1 cards) behaves exactly as today: endless, no pot, no debit.
- **Zone-empty or `Q` with a live pot ⇒ `finish()` before returning.** See the rule above.

### The reentrancy hazard, stated plainly

`pong.lua`'s loop re-arms its tick timer **only in the timer branch** (`pong.lua:157-161`) — the exact
shape that froze the slot (`[[event-pump-reentrancy]]`). `mp_econ.start()` and `.onEvent()` call
`wallet`, which pumps events. `wallet.request` and `wallet._pumpSafe` already stash and re-queue, so
this is safe **as long as nothing new pumps outside them**.

**Mandate for the implementation:** no new blocking call may be introduced outside `wallet`, and
`pong.lua` must re-arm its timer after any handler that touches `mp_econ` — the cage already does
this (`cage.lua` re-arms after every touch handler) precisely because the guarantee is worth having
regardless. Do not add a `sleep()`, a `parallel`, or a `rednet.receive` anywhere in this branch.

## Testing

Unit tests (`luajit test/test_*.lua`, the existing 12 files' fakes pattern):

- **`card`** — `drives()` sorting + disk-present filter; `read(drive)` targeting; `read(nil)` still
  returns the first drive (the no-regression test); `readAll()` with 0/1/2/3 drives; a blank and an
  unreadable disk.
- **`card_session`** — refresh on disk event; anonymous; hub-offline sets `offline` and falls back to
  the card mirror; mirror write on a successful query; `flush=false` suppresses the flush.
- **`mp_econ`** — the meat:
  - staked iff >= 2 carded; 1 carded and 0 carded are free (no debit)
  - **ante refunds on a mid-ante failure** — seat 2 insufficient ⇒ seat 1 credited back, `"deny"`
  - pot to best carded seat; **anon outscores everyone ⇒ anon is `matchWinner`, best carded gets the
    pot**
  - tie split + remainder to the lowest index; the shares must sum to exactly `pot`
  - **credit follows `antedId` after the card is pulled** and after a *different* card is inserted
    (the spectator case)
  - `finish` on a `"free"` match credits nobody and returns `pot = 0`

Not unit-testable, must be verified in-world (see below): drive mounting, `monitor_touch` on pong's
monitor, and the timer-survival of a real hub round-trip mid-rally.

## Deploy

- `packages.lua`: `card_session` + `mp_econ` → **pong**; `card_session` → **slot** and **cage** (they
  now require it). Verify the manifest against the tree — a missing module is an `unknown package` or
  a short install, and the raw-CDN lag makes it look like a code bug (`CLAUDE.md`).
- **`update hub` is NOT needed. No protocol change.** The pot is existing `debit` + `credit`. This
  deliberately sidesteps `kb/economy.md` lesson 7 — every protocol change makes stations report
  `HUB OFFLINE` against a healthy hub until the hub is updated **and rebooted**.
- Deploy order: push → wait 2–5 min (CDN) → `update slot`, `update cage`, `update pong` → reboot.
  slot and cage must be updated too: they gain a `require("card_session")`.

## In-world verification (post-merge)

1. `update pong` on a station with **2 drives** → does it boot? (the `getMountPath()` question)
2. 0 cards → free rally, as today. **No regression is the bar here.**
3. 1 card → free rally, header shows that player, **no debit** (check the balance).
4. 2 cards → `GO` → both debited, `POT $20` → `END` → higher score credited $20.
5. **Pull a card mid-match → `END` → the pot still pays the anted id.** The headline behaviour.
6. Insert a *different* card mid-match → still pays the anted id, spectator gets nothing.
7. Insufficient seat 2 → `GO` → **seat 1 is NOT out of pocket** (the refund path), header says which.
8. Hub down → `GO` → denied, says `HUB OFFLINE`, **not** `INSUFFICIENT`, and nobody is debited.
9. **Walk away mid-staked-match → the pot resolves, nobody is out of pocket** (the zone-empty rule).
10. **slot + cage still work** — they were rebuilt on `card_session`. This is the regression that
    matters most: the extraction touches two shipped, in-world-verified stations.

## Out of scope

Pong as a real game (win condition, art, advert, pixelfont) · scoreboards · the trading station ·
`hub_version`/ping and the request-id de-dupe (both filed; both are protocol changes and this branch
deliberately makes none) · the `bet_deny{reason="unknown"}` → `INSUFFICIENT` lie in `sp_econ`
(filed; adjacent, but it is `sp_econ`'s bet path, not the session).
</content>
