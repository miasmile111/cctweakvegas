# Hub economy (member cards + scoring) — design

**Date:** 2026-07-16
**Status:** approved, pre-implementation
**Depends on / feeds:** the hub registrar (`2026-07-16-station-identity-and-deploy-design.md`, built)
and the shared idle runner (`2026-07-16-station-folders-and-idle-runner-design.md`, built). This adds
the **score economy** the hub was always meant to own (README "Hub-authoritative economy"), and makes
the slot a real bet-and-pay gamble. It is the core of README's "Membership card" + "Rednet protocol"
sections and TODO Option B.

## Problem

The hub is a registrar only: it knows every station but holds no score. The slot is a free lever-pull
with no stakes and no payout. We want the canonical **hub-authoritative ledger** (`id → score`),
**membership floppies** that identify a player, and a **bet-and-risk** slot: a pull costs a stake, a
win pays a per-symbol paytable, triple-seven is the jackpot. All of this must be built so a **second
game reuses it trivially** — the economy is a fat shared gateway, each game supplies only a tiny
payout script (the same move the idle runner made for the idle lifecycle).

## Goals

1. **Hub-authoritative ledger.** One persisted `id → score` table on the hub; the hub is the *only*
   writer. Games send deltas / requests; they never own the truth.
2. **Bet & risk slot.** A pull debits a fixed stake (hub-gated: no funds → no spin); a win credits a
   per-symbol payout (triple-seven jackpot). No card = anonymous **free-play** (reels spin, result
   shows, nothing debited or paid) — never require a card to play (README principle 4).
3. **Layered economy, thin games.** A shared **economy core** (card + protocol + outbox) and a
   **single-player gateway** own all the machinery; a game supplies only `stake` + a payout `eval`
   and calls the gateway from its existing `play()` loop — exactly as `pres` is handed in today.
4. **Built toward multiplayer.** The core knows nothing about SP vs MP. A future multiplayer gateway
   (parked — needs an interactive wager system) drops in beside the SP one with **zero core change**.
5. **A win is never lost.** Debits fail closed (gate play); credits are guaranteed via a persisted
   outbox that flushes when the hub returns.
6. **Admin card issue.** A one-time `issue <name> [balance]` mints a ledger entry + writes the floppy.

## Architecture — three layers

```
Layer 3  GAME      slot.lua (round loop + visuals)  +  slot_pay.lua (stake + payout eval)   ← tiny, per-game
Layer 2  GATEWAY   sp_econ.lua  (single-player: one card, house paytable)                    ← BUILD NOW
                   mp_econ.lua  (multi-card pot / interactive wagers)                         ← PARKED
Layer 1  CORE      card.lua · wallet.lua (+outbox) · ledger.lua (hub)                         ← serves BOTH gateways
```

- **Layer 1 is SP/MP-agnostic** — `bet`/`credit`/`query` are id-scoped; the hub handles any number of
  ids. MP later = a gateway that withdraws stakes from several ids into a pot and awards the winner,
  built on these same core calls. No Layer-1 change is needed for MP.
- **`idle_runner` is untouched.** Pong has no economy; the gateway is composed *inside* a game's
  `play()`, not bolted onto the idle lifecycle. No economy leaks into the idle layer.

## Confirmed facts

- `idle_runner.run` opens the modem and `rednet.open`s it **before** calling `cfg.play` (`idle_runner.lua:19`).
  So the gateway reuses the already-open modem; it must **not** re-open. It finds the hub with
  `rednet.lookup("ccvegas", "hub")` (the hub `rednet.host`s hostname `hub`, `hub.lua:36`).
- `play()`'s event loop currently pulls `timer` / `rednet_message` / `key` and already forwards
  rednet events to `pres.fromEvent(ev)` (`slot.lua:289-294`). It must additionally handle `disk` /
  `disk_eject` and forward every event to `econ.onEvent(ev)` — same pattern.
- The slot monitor is drawn through an offscreen `window` + `subpixel` canvas; the reserved top ~34%
  (`viewTop = cv.h*0.34 + barH`, `slot.lua:59`) is free gradient today — the balance header goes there.
- Deploy flattens files by `name` (`update.lua`), so `require("sp_econ")` etc. are folder-independent;
  only `packages.lua` `path` fields encode the folder. New pure modules live in `src/lib/`.
- Tests run under luajit with `package.path = "src/lib/?.lua;src/slot/?.lua;src/pong/?.lua;test/?.lua;..."`
  (`test/test_slot_logic.lua:1`). New pure modules in `lib/` are already on that path.

## Rednet protocol (`ccvegas`)

Request/reply, each with a short timeout + bounded retry (`rednet.receive` with an id filter, or a
correlation field). The hub persists the ledger after every write, then replies with the fresh balance.

```
station → hub   { kind = "bet",    id, stake }        → { kind = "bet_ok", id, balance }
                                                       | { kind = "bet_deny", id, balance, reason }   -- "insufficient" | "unknown"
station → hub   { kind = "credit", id, delta }         → { kind = "balance", id, balance }
station → hub   { kind = "query",  id }                → { kind = "balance", id, balance }
issue   → hub   { kind = "mint",   name, balance }     → { kind = "minted", id }
                                                       | { kind = "mint_deny", reason }               -- "exists"
```

- **Debit is hub-gated:** the slot may not spin for stakes until it receives `bet_ok`. On `bet_deny`
  or timeout → no spin (fail closed).
- **Credit is guaranteed:** fire it after a win; if no reply arrives, the outbox (below) retries.
- Existing `register` / `presence` / `presence?` messages on the same protocol are unchanged; the hub
  adds the new kinds to its receive loop.

## Layer 1 — economy core

### `lib/ledger.lua` (pure, unit-tested)

No CC APIs — the hub is its I/O host (loads/persists the table; ledger just transforms it). The
ledger is a plain `{ id → score }` table passed in and mutated/returned.

```lua
ledger.mint(t, name, balance)   -- create id=name with starting balance; returns id or nil,"exists"
ledger.balance(t, id)           -- returns score or nil (unknown id)
ledger.apply(t, id, delta)      -- add delta (may be negative); returns new balance or nil (unknown)
ledger.debit(t, id, stake)      -- if balance >= stake: subtract, return true,newBalance
                                --    else return false,balance  (insufficient — no change)
```

`id` = the chosen name (README: the card's `id` is the chosen name; trust model = close friends, no
anti-cheat). `mint` rejects a duplicate name so two people can't share one ledger row by accident.

### `lib/card.lua` (I/O — in-world verified)

Membership floppy read/write. One file on the disk: `/<mount>/ccvegas_card` holding
`textutils.serialize{ id = <string>, score = <number> }`.

```lua
card.read()             -- find a mounted disk with a card file; returns { id, score } or nil (no card / blank)
card.writeMirror(score) -- update the score mirror on the currently-mounted card (best-effort; id unchanged)
card.isCardEvent(ev)    -- true for "disk" / "disk_eject" (so play() knows to re-read)
```

- Uses `disk.getMountPath` / `fs` on the drive peripheral; anonymous = no card file present.
- `score` on the disk is a **display mirror** only; the hub is authoritative. `writeMirror` keeps it
  fresh after each balance change so a card shows a sensible number when read at another machine.

### `lib/wallet.lua` (I/O + a pure outbox helper)

The station-side hub client: wraps the protocol with timeout/retry and owns the **persisted credit
outbox**. Depends on the already-open modem (from `idle_runner`); resolves the hub via `rednet.lookup`.

```lua
wallet.query(id)          -- → balance or nil (timeout)
wallet.bet(id, stake)     -- → true,balance (bet_ok) | false,balance,reason (deny/timeout: fail closed)
wallet.credit(id, delta)  -- → true,balance ; on timeout, ENQUEUE to outbox and return false (win not lost)
wallet.flush()            -- try to send every queued credit; drop each that the hub acks
```

- **Outbox** persisted to `/ccvegas_outbox.tbl` on the station computer: a list of `{ id, delta }`.
  `wallet.flush()` runs on gateway entry (active session start) and after any successful hub contact,
  so a win banked while the hub was down lands on the player's next visit / the hub's return.
- Pure, testable helpers (no I/O) for the queue: `wallet._enqueue(list, item)`, `wallet._drop(list, acked)` —
  these get unit tests; the send/receive wrapper is I/O and is verified in-world.

## Layer 2 — single-player gateway `lib/sp_econ.lua`

The fat shared piece. Composes `card` + `wallet`, owns the bet-gate decision, settle/credit, the card
lifecycle, and economy **state**. Built and used *inside* a game's `play()`:

```lua
local econ = require("sp_econ").new{ zone = ZONE, pay = require("slot_pay") }
--   pay = a payout module: { STAKE = <int>, eval = function(result) -> payout:int end }

econ.onEvent(ev)   -- fold in a raw os event: disk/disk_eject (re-read card, refresh balance via query),
                   --   and hub "balance"/"bet_ok" replies. Call for EVERY event, like pres.fromEvent(ev).
econ.tryBet()      -- called on the arm edge (lever). Returns:
                   --   "staked" — card present & funded: stake debited (bet_ok). Run the round for real.
                   --   "free"   — no card: anonymous free-play. Run the round; settle() will pay nothing.
                   --   "deny"   — card present but insufficient / hub unreachable. Do NOT run; flash INSUFFICIENT.
econ.settle(result)-- called when the round resolves. If the round was "staked" AND result is a win,
                   --   credits pay.eval(result) (via wallet, → outbox on failure), updates balance + card mirror.
                   --   Returns the payout paid (0 on loss / free-play). Idempotent per round.
econ.status()      -- { player=<id|nil>, balance=<int|nil>, stake=<int>, lastWin=<int>, denied=<bool> }
```

- **Game owns pixels.** The game renders `econ.status()` in its own header strip (styles differ per
  game). `sp_econ.drawHeader(mon, status)` ships a **default plain-text header** (id · balance ·
  stake, or `FREE PLAY`) for games that don't want a custom one — slot draws its own fancy version.
- `sp_econ` tracks the current round's bet outcome internally so `settle` knows whether to pay; the
  game just calls `tryBet()` at the arm edge and `settle(result)` at resolution.

## Layer 3 — the slot game

### `slot_pay.lua` (pure, unit-tested) — the tiny per-game payout script

```lua
local STAKE = 10
return {
  STAKE = STAKE,
  -- result = { reels[1..3] final symbol indices } (1=seven 2=cherry 3=bell 4=bar)
  eval = function(result)      -- returns payout (0 if not a triple)
    local a,b,c = result[1], result[2], result[3]
    if not (a == b and b == c) then return 0 end
    local mult = ({ [1]=25, [2]=3, [3]=5, [4]=8 })[a]   -- seven jackpot · cherry · bell · bar
    return STAKE * mult
  end,
}
```

Default numbers (approved, tunable): **stake 10** · triple-cherry **3×** · bell **5×** · bar **8×** ·
seven **25× (jackpot)**. Live beside the existing slot tuning knobs in `todo.md`.

### `slot.lua` integration (least-invasive to the existing loop)

- Build `local econ = require("sp_econ").new{ zone = ZONE, pay = require("slot_pay") }` at the top of
  `play()`; `econ.flush`-on-entry happens inside `new`.
- **Arm edge** (the existing `state=="attract" and armed and lvl>=SPIN_LEVEL` branch, `slot.lua:258`):
  `local mode = econ.tryBet()`. If `"deny"` → don't spin; set a short `INSUFFICIENT` flash in the
  header and stay in attract. If `"staked"`/`"free"` → `newSpin()` and go spinning as today.
- **Result** (the `allStopped` branch, `slot.lua:271`): after computing win/lose, call
  `econ.settle({ reels[1].final, reels[2].final, reels[3].final })`; keep its return (the payout) for
  the header / banner.
- **Events:** in the loop, add `disk` / `disk_eject` handling and call `econ.onEvent(ev)` for every
  event (alongside the existing `pres.fromEvent(ev)` on rednet).
- **Header:** each frame, draw the balance strip in the reserved top area from `econ.status()` —
  `player · balance · stake`, or `FREE PLAY` when anonymous, or a brief `INSUFFICIENT` on deny. Slot
  renders this in its own subpixel/window style (not the default header).
- No change to reel logic, gradient, bulbs, or the `test` mode.

## Hub changes (`hub/hub.lua`)

- Load/persist a **second store** `ledger.tbl` (`id → score`), separate from `registry.tbl`; same
  load-or-init + `persist()` pattern already in the file.
- In the registrar receive loop, add handlers for `bet` / `credit` / `query` / `mint` that call
  `lib/ledger.lua`, persist on every write, and reply per the protocol above. `mint` also comes from
  the `issue` program.
- The hub gains a **disk drive** (for `issue` to write floppies). Force-loaded / always-on as today.
- `hub.lua` now `require("ledger")`; `packages.lua` `hub` gains `ledger`.

## The `issue` program (admin mint) — `src/issue.lua`

Runs on the hub computer (advanced → a second multishell tab) or any computer with a drive + modem.

```
issue <name> [balance]     -- default balance e.g. 100
  → rednet "mint" to hub → on "minted"{id}: write /<mount>/ccvegas_card = { id=name, score=balance }
  → on "mint_deny"{reason="exists"}: print a loud error, write nothing.
```

- Fail-loud like the rest of the base: no drive / no blank disk / hub offline → clear message, no
  partial state. Its own package so it isn't pulled onto game stations.

## `packages.lua` updates

```lua
slot = { station = true, files = { ...existing...,
  { name = "card",     path = "lib/card.lua" },
  { name = "wallet",   path = "lib/wallet.lua" },
  { name = "sp_econ",  path = "lib/sp_econ.lua" },
  { name = "slot_pay", path = "slot/slot_pay.lua" },
}}
hub = { station = false, files = { ...existing...,
  { name = "ledger",   path = "lib/ledger.lua" },
}}
issue = { station = false, files = {
  { name = "card",   path = "lib/card.lua" },
  { name = "wallet", path = "lib/wallet.lua" },   -- reuses the hub client for the mint round-trip
  { name = "issue",  path = "issue.lua" },
}}
```

(`wallet` on the `issue` package is only for the mint request/reply; if `issue` ends up talking to the
hub directly with a bare `rednet` call, drop it — decide during implementation.)

## Testing / verification

- **Unit (luajit, new test files):**
  - `test_ledger.lua` — `mint` creates + rejects duplicate; `balance` unknown → nil; `apply` adds
    (incl. negative); `debit` succeeds when funded (subtracts) and fails closed when short (no change).
  - `test_slot_pay.lua` — non-triple → 0; each triple → its multiple; triple-seven = jackpot (25×);
    stake respected.
  - `test_wallet.lua` — pure outbox helpers: `_enqueue` appends; `_drop` removes acked items and
    keeps the rest; flush-order semantics.
  - Extend `package.path` note: new `lib/` modules are already covered by the existing path.
- **Syntax:** `luajit -bl` on every new/edited `.lua` (card/wallet/sp_econ are I/O but must still parse).
- **In-game (user):** `update hub` (add drive), `update slot` (add drive), `update issue`. Then:
  mint a card (`issue Alice 100`) → insert at slot → balance shows → pull: stake debited, win pays per
  paytable, balance updates on card + monitor → spend to 0 → pull → `INSUFFICIENT`, no spin → eject →
  `FREE PLAY` anonymous round pays nothing → **hub-offline win**: stop the hub, win a round (credit
  goes to outbox), restart the hub, next interaction flushes the outbox and the balance corrects.

## Non-goals / parked

- **Multiplayer gateway (`mp_econ`)** — needs an interactive player-vs-player wager system (commit
  stakes, form a pot, award the winner) that isn't designed yet. Core is built to accept it later.
- **Scoreboards** — display-only rednet subscribers of the ledger; their own spec. The hub *may*
  broadcast a `balance` update on each write to make that trivial later, but no scoreboard client is
  built now.
- **Diegetic sink** — what score is *for* (redstone payout: dispense item via AP Inventory Manager,
  open a door, light a lamp). Its own spec; the ledger being a true spendable balance is the hook.
- **Adjustable stake / bet-up control, multi-line paylines, security/anti-cheat** — out of scope
  (close-friends trust model).
- **Card issue UI** — admin `issue` command only; no in-world sign-up kiosk.
