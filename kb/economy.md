# Economy system — reference

The hub-authoritative score economy: a persisted `id → balance` ledger on the hub, membership-card
floppies, and games that bet/pay through a shared gateway. Built 2026-07-16, in-world verified.
Spec: `docs/superpowers/specs/2026-07-16-hub-economy-design.md`. This doc is the living reference —
read it before touching or extending the economy.

## Currency: **`$`**

The in-world money is displayed as **`$`** — the unit of every `balance`/`stake`/`payout` in the
ledger. **Show it as `$<n>` in games** (e.g. `Alice: $240`). One ledger, one currency, base-wide.
(The old `M-Bucks` / `MB` branding was dropped 2026-07-16 — a plain `$` reads better; if you find a
stray `MB` anywhere, it's `$`.)

## Architecture — three layers

```
GAME      slot.lua (round loop + visuals)  +  slot_pay.lua (stake + payout eval)   ← tiny, per-game
          cage.lua (kiosk loop + UI)                                               ← tiny, per-game
GATEWAY   sp_econ.lua  (single-player: one card, house paytable)                    ← built
          cage_econ.lua (card session + hub debit/credit, sibling of sp_econ)       ← built
          mp_econ.lua  (multi-card pot / wagers)                                    ← future
CORE      card.lua · wallet.lua (+outbox) · ledger.lua (hub)                        ← SP/MP-agnostic
```

- **`lib/ledger.lua`** (pure, unit-tested) — hub-side `{id→balance}`: `mint/balance/apply/debit`.
- **`lib/card.lua`** — membership floppy `/<mount>/ccvegas_card` = `{ id, score }`. `score` is a
  **display mirror only**; the hub is authoritative. No card = anonymous.
- **`lib/wallet.lua`** — station→hub client (protocol `ccvegas`) + a **persisted credit outbox**.
- **`lib/sp_econ.lua`** — the single-player gateway; composes card+wallet into a bet-gate/settle API
  a game drives from its `play()` loop (passed in like `pres`): `tryBet()`, `settle(result)`,
  `onEvent(ev)`, `status()`.
- **`lib/cage_econ.lua`** — the cage's gateway (sibling of `sp_econ`, not built on it — the cage is
  debit/credit-shaped, not bet/settle-shaped): `tryDebit(amount)`, `deposit(amount)`,
  `refund(amount)`, `onEvent(ev)`, `status()`.
- **`slot/slot_pay.lua`** — the slot's tiny payout script: `STAKE` + `eval(result)`.
- **`hub/hub.lua`** — owns `ledger.tbl` + the `bet/credit/query/mint/debit` handlers (sole writer).
- **`issue.lua`** — admin `issue <name> [balance]`: mints a ledger id + writes the floppy.
- **The cage (`cage/`) is the `$` exit** — a kiosk where a card's `$` becomes real metal (droppers)
  and metal becomes `$`, bidirectional and flat-rate. See `todo.md`'s Cage section + the spec/plan
  under `docs/superpowers/`.

## Protocol (`ccvegas`, request/reply)

```
station → hub   bet    {id, stake}   → bet_ok {id, balance} | bet_deny {id, balance, reason}
station → hub   debit  {id, amount}  → debit_ok {id, balance} | debit_deny {id, balance, reason}
station → hub   credit {id, delta}   → balance {id, balance} | credit_deny {id, reason="unknown"}
station → hub   query  {id}          → balance {id, balance}
issue   → hub   mint   {name, bal}   → minted {id} | mint_deny {reason}
```

- **Bet is hub-gated, fails closed** — no `bet_ok` (deny, or hub offline/timeout) ⇒ no spin.
- **Debit is hub-gated, fails closed** — the honest, game-agnostic withdrawal primitive (`bet`
  stays the slot's wager-round special case). No `debit_ok` (deny, or hub offline/timeout) ⇒ no
  items move. `reason` is `"unknown"` | `"insufficient"` | `"timeout"`. Built for the cage; it is
  also the multiplayer primitive (`mp_econ` pots + the trading station both reduce to debit/credit
  pairs).
- **Credit is guaranteed** — hub down ⇒ queued to the station outbox, flushed on next contact. An
  explicit `credit_deny` (id unknown to the ledger) is a terminal deny, never queued — retrying an
  unknown id can never succeed. This closed **F2** (below).
- The hub **persists `ledger.tbl` on every write** (bet debit, winning credit, mint). `query` never
  writes. So a staked spin = 1 disk write (debit), or 2 on a win (debit + payout). Anonymous = none.

## Payout model (tunable)

`slot_pay.lua`: `STAKE = 10`; triple only, per-symbol — **cherry 3× · bell 5× · bar 8× · seven 25× (jackpot)**.
Starting card balance default **$100** (`issue`). Symbol indices: 1=seven 2=cherry 3=bell 4=bar.

## Hardware / setup

- **Hub** = computer + **every modem it can reach stations with** + **disk drive** (the drive is for
  `issue` to write cards). **The floor is NOT one network:** cabled stations reach the hub over the
  wire, distant ones only by **ender modem** — so the hub needs *both* and must **open both**. See
  `[[open-every-modem]]`; this shipped broken and read as "hub offline" on a hub that was running.
- **Each game station** = computer + advanced monitor + wired modem (peripherals) + **disk drive**,
  plus whatever reaches the hub (an **ender modem** if it isn't cabled to it). Every rednet entry
  point opens *all* modems; never pick one.
- **The cage** adds a deposit + a vault inventory and 2+ droppers — see `todo.md`.
- Deploy: **`update hub` FIRST, then reboot the hub**, then the stations. Order matters whenever the
  protocol grew (the stations speak the new `kind` before the hub understands it), and `update` only
  writes files — **the running program stays old until the machine restarts**. Mind the raw-CDN lag
  (`[[deploy-and-identity]]`): re-run `update` a few min after a push or you silently pull stale code.

## Hard-won lessons (don't re-learn these)

1. **A win is never lost — nor double-credited.** The credit outbox banks a payout when the hub is
   down; `flush()` **persists after each ACK** (not once at the end) so an interrupted flush can't
   resend an already-credited win. Bet debits fail closed, so they need no outbox.
2. **Settle credits the *staked* id, not the live card.** `sp_econ` captures `stakedId` at bet time;
   if the player ejects/swaps their card during the result window, the payout still goes to whoever
   paid the stake. The card mirror on a swapped card self-heals from the hub on the next read.
3. **Card-swap freeze (fixed).** A nested `os.pullEvent` loop (`wallet.request`) called from inside
   the slot's tick loop swallowed the game's own tick timer on a mid-session card swap → frozen
   monitor. Fix: `request()` **stashes and re-queues** every non-matching event; the hub id is
   **cached** so `rednet.lookup` (also a blocking pump) stays out of the hot path. General rule in
   `[[event-pump-reentrancy]]` (cc-lua KB) — applies to *any* future game that talks to the hub mid-loop.
4. **A card can live on any disk.** Issuing onto the master tools floppy just adds a `ccvegas_card`
   file — harmless; that disk is now both a tools disk and a card. Cards aren't special disks.
5. **`score` on the card is a mirror.** If card and hub disagree, the hub's `ledger.tbl` wins; the
   card corrects on the next insert/`query`.
6. **Ordering invariant for any item-for-`$` exchange: stock check → debit → move → refund-if-short.
   Never violate this order.** Debiting before confirming stock (or crediting before the metal
   actually lands) is a duplication exploit, not just a UX bug: credit-first plus a partially-failed
   sweep would pay a player for metal still sitting in their own chest, which they could re-tap
   unboundedly. Debit-first with a stock check ahead of it risks only a bounded one-time loss (needs
   the hub UP *and* the id gone from the ledger) — refund the shortfall after the fact if a move
   comes up short. The cage's `cage.lua`/`cage_hw.lua` are the reference implementation.
7. **"HUB OFFLINE" does not mean the hub is offline.** The station cannot tell the difference between
   *no hub*, *a hub it can't reach*, and *a hub that doesn't understand the message* — all three are
   simply **no reply within `TIMEOUT`**, and fail-closed reports the same string for all of them. The
   hub's handler chain is `if/elseif` with **no `else`**: an unknown `kind` matches nothing and it
   replies **nothing**. So the moment you add a message kind, every station that sends it before the
   hub is updated *and restarted* reports HUB OFFLINE against a healthy hub. Triage it by which
   messages work, not by looking at the hub:
   - balance shows + deposit works + only withdraw fails → hub is **up but old** (knows `query`/
     `credit`, not `debit`) → `update hub`, **reboot it**.
   - nothing reaches it at all (even `update`'s registration) → **topology**: the modem that can
     reach the hub isn't open, or isn't there → `[[open-every-modem]]`.
   Both of those shipped here, on the same day, presenting identically. Worth a `hub_version`/ping in
   the protocol so a station can say *"hub is up but too old"* — every future protocol change has this
   same failure mode. **Not built; the next protocol change should build it.**

## Open follow-up

- **Floppy-swap freeze STILL happens intermittently (open bug, 2026-07-16).** Owner reports the station
  *sometimes* freezes (no crash — monitor stops, program still "running", reboot to clear) when
  **switching out floppy disks**. The `1a7d9d7` fix (stash+re-queue foreign events, cache the hub id —
  see lesson 3 above and `[[event-pump-reentrancy]]`) reduced but did **not** eliminate it. Likely a
  remaining nested-`os.pullEvent` / blocking-call path reachable from the `disk`/`disk_eject` handler
  (`sp_econ.onEvent` → `card.read` → `wallet.query`/`rednet.lookup`), or a `disk_eject` firing mid-`bet`
  round-trip. **Next-session repro:** rapid insert/eject during attract vs during a spin's result
  window; log every event the play loop sees around a swap; check whether `wallet.request`/`rednet`
  round-trips can still be entered from `onEvent`. Fix so a swap never blocks the tick timer.
- ~~**F2 (latent):** a `credit` to an *unknown* id is treated as acked (hub replies `balance=nil`) →
  win silently dropped.~~ **FIXED (cage task).** The hub now replies `credit_deny{id, reason="unknown"}`;
  `wallet.credit`/`wallet.flush` classify it via `wallet._creditResult` as a terminal `"deny"` —
  applied immediately, never queued to the outbox (retrying an unknown id can never succeed). Made
  reachable (and worth fixing) by the cage: a deposit against a card whose ledger id is gone.

## Future economy work (parked — each its own spec, after the vertical slice)

- **Trading station** — a station where players **transfer `$` between member cards**. Players may
  hold **multiple cards**; trading moves balance from one `id` to another. Hub-mediated (two id-scoped
  ledger writes: debit sender, credit receiver) so it's authoritative and atomic-ish. Diegetic input
  (buttons/levers to pick amount + confirm). Reuses the core (`ledger`/`card`/`wallet`); `wallet.debit`
  (built for the cage) is already its debit primitive. Add once the basic vertical-slice pieces
  (scoreboards) are in.
- **Scoreboards** — display-only rednet subscribers rendering standings around the floor.
- **Multiplayer economy** (`mp_econ`) — multi-card pot / interactive wagers; core is already SP/MP-agnostic.
