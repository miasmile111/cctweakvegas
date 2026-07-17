# `issue add` — top up an existing card

**Date:** 2026-07-17
**Status:** approved (owner, 2026-07-17)
**Touches:** `src/issue.lua`, `src/lib/wallet.lua`, `test/test_wallet.lua`

## Problem

`issue <name> [balance]` only **mints**. Once a floppy carries an id, there is no way to put more `$`
on it — the admin's only lever is minting a *new* id, which is not the same player. The floor needs a
top-up: a card exists, the ledger knows the id, add money to it.

Every primitive already exists (`wallet.credit`, `wallet.debit`, `card.read`). This is a small
command, not a new subsystem.

## Scope

**In:** `issue add <amount>` — reads the id from the card in the drive, moves that id's balance by
`amount`, refreshes the card's `score` mirror, reports the before/after.

**Out:** setting an absolute balance (would need a new hub message kind — see *Why a delta* below);
targeting an id by name without a disk; any GUI or physical station. `issue` stays an admin CLI.

## Design

### Interface

```
issue <name> [balance]     mint a NEW id onto a blank floppy   (unchanged; balance defaults to 100)
issue add <amount>         move the balance of the id ALREADY on the inserted floppy
```

`amount` is a delta and may be negative. `add` is a **reserved word**: a player literally named `add`
cannot be minted. Accepted wart — the usage line says so.

### Why a delta, not an absolute set

`credit {id, delta}` and `debit {id, amount}` already exist in the `ccvegas` protocol, so a delta
needs **no hub change and no hub reboot**. An absolute `set` would need a new message kind, and per
`kb/economy.md` lesson 7 every new kind makes every station that sends it report **HUB OFFLINE against
a healthy hub** until the hub is updated *and restarted*. Not worth it to save the admin one
subtraction.

### The sign picks the primitive

| `amount` | Call | Why |
| --- | --- | --- |
| `> 0` | `wallet.creditNow(id, amount)` | new: credit that **fails closed** (below) |
| `< 0` | `wallet.debit(id, -amount)` | already fails closed on insufficient funds |
| `== 0` | — | usage error; a no-op that reports success would be a lie |

**Negative amounts must not drive a balance below zero.** `ledger.apply` does **not** clamp — it will
happily write `-30` — while `ledger.debit` refuses when `bal < stake`. Routing negatives through
`debit` gets that guard for free, so `issue add -50` against a `$20` balance **refuses and changes
nothing**. This is not just tidiness: the cage renders the balance through `pixelfont`, which has no
minus glyph, so a negative balance is unrenderable at the kiosk.

### `wallet.creditNow` — the one core addition

`wallet.credit` is **guaranteed**: on timeout it enqueues to the persisted outbox and returns
`"queued"`. That is right for a game — a player earned that win and it must survive a hub outage.

It is wrong here, and silently so:

- `issue` is a **one-shot program**. Nothing on an admin box ever calls `wallet.flush()`, so a queued
  credit sits in `ccvegas_outbox.tbl` forever and the money never arrives.
- Worse, the admin sees a failure and **re-runs it**. Now the outbox still holds the first `+500`, so
  if anything ever does flush that computer, the player is credited **twice**.

So:

```lua
-- admin/interactive credit: fails CLOSED, never outboxes.
-- Returns ok, balance, reason ("unknown" | "timeout").
function M.creditNow(id, delta)
```

Same round-trip and the same `_creditResult` classifier as `credit`; the only difference is that
`"queue"` becomes a hard `false, nil, "timeout"` with **nothing enqueued**. `wallet.credit` is
untouched — existing callers keep the guarantee they rely on.

### Outcomes — all three distinguishable

`kb/economy.md` lesson 7: never collapse "denied", "hub offline", and "hub too old" into one string.

| Result | Message |
| --- | --- |
| ok | `alice: $100 -> $600  (+500)` — card mirror rewritten to the new balance |
| `deny` (`reason="unknown"`) | the ledger has no such id — the card is stale. Terminal; nothing queued. Point at `issue <name>` to mint. |
| `deny` (`reason="insufficient"`, negative only) | `alice has only $20 — cannot take $50.` Nothing changed. |
| `timeout` | **ambiguous — see below.** Says only what is true: nothing was *queued*. Then asks the hub what the balance actually reads. |
| no/blank card | `no card in the drive` → point at `issue <name> [balance]` |

Note `wallet.debit` returns `reason="timeout"` for an unreachable hub and `"insufficient"`/`"unknown"`
for a real deny, so the negative path distinguishes the same three cases as the positive one.

### A timeout is ambiguous, and must never be reported as a "no"

`request()` gives up after `TIMEOUT = 1.5s`. That is **not** proof the hub did nothing: it may have
received the message, applied it, and persisted `ledger.tbl`, with only the reply lost or merely late.
A server hitch stalls a CC computer for seconds (the cage's own `cage debug` shows 300ms tick gaps on
an idle floor), so 1.5s is a narrow window.

`credit`/`debit` carry **no request id and are not idempotent**, so "just run it again" is precisely
how a balance gets doubled. This command therefore must not print "nothing was credited" — it cannot
know that. It prints only what it does know (nothing was *queued*), then issues a `query` and shows
the hub's current reading next to the card's last-known mirror, so a human can decide. If the `query`
also times out, it says the change *most likely* didn't land — a guess, labelled as one.

This is the one path here that can lose real money, and the first draft got it exactly backwards:
it asserted the unknowable half and then instructed the harmful action.

> **Latent, out of scope:** `wallet.credit`'s outbox has the same ambiguity — a timed-out credit that
> the hub actually applied gets queued and re-sent on the next `flush()`, double-crediting. Pre-dates
> this work; noted in `kb/economy.md` as follow-up. The real fix for the family is a request id the
> hub can de-duplicate on.

### Amount validation — the only door to the ledger

`ledger.apply` is `t[id] = t[id] + delta` with no checks, so `wallet._wholeAmount` (pure, unit-tested,
beside the other `_` helpers) is the sole gate. It refuses non-numbers, **non-finite values**,
fractionals, and anything past `MAX_AMOUNT = 1e9`.

Non-finite is the one that matters: `tonumber("inf")` and `tonumber("1e400")` are both `inf`, and
`inf` **passes an integrality test** (`math.floor(inf) == inf`). `issue add inf` would make the hub
persist `balance + inf = inf` — that card is poisoned **permanently**, since no claw-back can fix it
(`ledger.debit` needs `bal >= stake`, and `inf - n = inf`); recovery means hand-editing `ledger.tbl`.
It prints as `-9223372036854775808`. `nan` fails the floor test only by accident (`nan ~= nan`) — not
something to rely on.

Fractional is subtler but the same family: Lua 5.1's `("%d"):format(101.5)` **silently** yields `101`
rather than erroring, so the ledger and every screen on the floor would disagree forever.

### Mint validation (in scope after all)

`issue <name> [balance]` is otherwise unchanged, but it takes the **same door**: a fractional starting
balance is the same disagreement bug, and `issue alice -5` used to mint a player at **−$5** — walking
straight around the guard that is the entire reason negatives route through `debit`. Both now refused.
Pre-existing (the old code took `tonumber()` at face value); fixed here because it directly undermines
this change's invariant.

The "before" figure is computed as `new - delta`; there is **no extra `query` round-trip**. `query`
could not distinguish "unknown id" from "hub offline" anyway (both return `nil`) — `credit`/`debit`
can, so let them.

### Card mirror

On success, `card.write(id, newBalance)` refreshes the `score` mirror while the disk is right there.
Best-effort: a mirror write failing is **not** a failed top-up — the ledger is authoritative and the
card self-heals on its next insert (`kb/economy.md` lesson 5). Report it, don't fail on it.

## Testing

`wallet.creditNow` is one `request()` wrapper, and `request` is I/O. Unit-test what is pure:

- `_creditResult` already covers the three classifications — assert `creditNow` maps `"queue"` to a
  hard failure and, critically, that **nothing is enqueued** on that path (the whole point of it).
- Existing `wallet.credit` outbox tests must still pass unchanged — proof the guarantee wasn't broken.

`issue.lua` is a top-level script (opens modems, prints); its logic is the sign-routing decision.
Verification is in-world: mint a card, `issue add 500`, `issue add -50`, `issue add -999999` (must
refuse), and `issue add 500` with the hub stopped (must say nothing was queued, and the outbox file
must not appear).

## Risks

- **`add` as a reserved word.** Accepted; documented in usage.
- **A stale card whose id was removed from the ledger** reports `unknown` rather than re-minting.
  Correct — silently re-minting would fabricate a player.
