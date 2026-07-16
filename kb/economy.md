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
GATEWAY   sp_econ.lua  (single-player: one card, house paytable)                    ← built
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
- **`slot/slot_pay.lua`** — the slot's tiny payout script: `STAKE` + `eval(result)`.
- **`hub/hub.lua`** — owns `ledger.tbl` + the `bet/credit/query/mint` handlers (sole writer).
- **`issue.lua`** — admin `issue <name> [balance]`: mints a ledger id + writes the floppy.

## Protocol (`ccvegas`, request/reply)

```
station → hub   bet    {id, stake}   → bet_ok {id, balance} | bet_deny {id, balance, reason}
station → hub   credit {id, delta}   → balance {id, balance}
station → hub   query  {id}          → balance {id, balance}
issue   → hub   mint   {name, bal}   → minted {id} | mint_deny {reason}
```

- **Bet is hub-gated, fails closed** — no `bet_ok` (deny, or hub offline/timeout) ⇒ no spin.
- **Credit is guaranteed** — hub down ⇒ queued to the station outbox, flushed on next contact.
- The hub **persists `ledger.tbl` on every write** (bet debit, winning credit, mint). `query` never
  writes. So a staked spin = 1 disk write (debit), or 2 on a win (debit + payout). Anonymous = none.

## Payout model (tunable)

`slot_pay.lua`: `STAKE = 10`; triple only, per-symbol — **cherry 3× · bell 5× · bar 8× · seven 25× (jackpot)**.
Starting card balance default **$100** (`issue`). Symbol indices: 1=seven 2=cherry 3=bell 4=bar.

## Hardware / setup

- **Hub** = computer + wired modem + **disk drive** (the drive is for `issue` to write cards).
- **Each game station** (slot…) = computer + advanced monitor + lever + wired modem + **disk drive**.
- Deploy: `update hub`, `update slot`, `update issue` (mind the raw-CDN lag — see
  `[[deploy-and-identity]]` in the cc-lua KB; re-run `update` a few min after a push).

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

## Open follow-up

- **F2 (latent):** a `credit` to an *unknown* id is treated as acked (hub replies `balance=nil`) →
  win silently dropped. Unreachable in normal single-hub flow (the ledger never deletes a just-debited
  id). Cheap fix if ever needed: a `credit_deny` reply kind, mirroring `bet_deny`.

## Future economy work (parked — each its own spec, after the vertical slice)

- **Trading station** — a station where players **transfer `$` between member cards**. Players may
  hold **multiple cards**; trading moves balance from one `id` to another. Hub-mediated (two id-scoped
  ledger writes: debit sender, credit receiver) so it's authoritative and atomic-ish. Diegetic input
  (buttons/levers to pick amount + confirm). Reuses the core (`ledger`/`card`/`wallet`); likely a new
  small gateway. Add once the basic vertical-slice pieces (scoreboards, sink) are in.
- **Scoreboards** — display-only rednet subscribers rendering standings around the floor.
- **Diegetic sink** — what `$` is *for* (redstone payout: dispense item via AP Inventory Manager,
  open a door, light a lamp). See `[[advanced-peripherals]]`.
- **Multiplayer economy** (`mp_econ`) — multi-card pot / interactive wagers; core is already SP/MP-agnostic.
