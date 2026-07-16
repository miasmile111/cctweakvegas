# The Cage — diegetic sink (design)

Date: 2026-07-16 · Status: approved, pre-implementation
Station name: **`cage`** (casino term for the cash desk) → `src/cage/`, `update cage`.

The economy's missing exit. Today `$` enters via `issue` (admin mint) and the slot's paytable, and
never leaves. The cage is a **kiosk** where a member card's `$` becomes real Minecraft metal — and
metal becomes `$`. Bidirectional, flat rate, hub-authoritative.

Read `kb/economy.md` and `kb/advanced-peripherals.md` first; this spec assumes both.

## Rates (flat, symmetric)

| Item | `$` |
| --- | --- |
| `minecraft:copper_ingot` | 25 |
| `minecraft:iron_ingot` | 100 |
| `minecraft:gold_ingot` | 250 |
| `minecraft:diamond` | 1000 |

Deposit and withdrawal use the **same** number — no house spread. The slot's paytable is where the
house edge lives; a second edge here would tax players twice and put two prices on every button.
Denominations live in `cage/cage_rates.lua` (the `slot_pay` idiom: data + pure helpers, one file to
tune). They divide evenly, so make-change is arithmetically trivial if ever wanted — **not built**.

## Player flow — a kiosk, no confirm step

```
walk up            hub presence wakes the station; advert → live UI
insert card        disk event → cage_econ reads id, queries hub → big $ number fills in
tap qty            1x / 5x / 20x — default 1x, persists across taps, resets to 1x on wake
tap a material     IMMEDIATE, no confirm:
                     stock check → wallet.debit → push qty items to droppers → burst fires
                     → big $ number counts DOWN
tap tap tap        each tap is its own debit and adds to the shower queue; bursts overlap
fill deposit chest
  + tap DEPOSIT    value known denoms → wallet.credit → items to vault → number counts UP
eject card         back to anonymous INSERT CARD
```

**No confirm dialog, by design.** A mistake is undone by depositing it straight back, so a confirm
step would only tax the common case. Spamming a material button is the intended overflow moment:
$2,000 as 20 iron is a small shower, $60,000 as 60 diamonds is a big one, and the player chooses
which by picking the denomination — the machine never decides for them.

## Hardware

- Computer + **advanced monitor 2×2 @ scale 0.5** + disk drive + wired modem.
- **Deposit chest** — on the wired network. Player-facing; junk left in it is never touched.
- **Vault chest** — on the wired network. Deposits flow in, withdrawals flow out. Self-balancing:
  the metal players cash in *is* the metal others cash out. Admin seeds it; a Create farm could
  feed it later. Vault empty ⇒ withdrawals deny (diegetically correct for a cage).
- **2–3 droppers** — each needs a wired modem (to receive `pushItems`) **and** redstone dust from
  one computer output side. All droppers fire on the **same** line: one pulse = one item from each
  = ~3 items/pulse. Items land on the floor. This is the cash-machine-overflow moment.
- Peripheral names + sides live in a `cage.cfg` (project convention: no re-import to rewire).

## Architecture

```
GAME     cage/cage.lua         play(mon, pres) loop + UI
         cage/cage_rates.lua   DENOMS + QTYS (pure)
         cage/cage_vault.lua   PURE item math — valuation, withdraw plan, dropper load  ← tested
         cage/cage_hw.lua      peripheral I/O — chests, droppers, redstone pulse
         cage/cage_symbols.lua ingot sprites (slot_symbols idiom)
         cage/cage_advert.lua  idle face — advert.draw(mon)
GATEWAY  lib/cage_econ.lua     card session + hub debit/credit  (sibling of sp_econ)
CORE     lib/card · lib/wallet · lib/ledger   (unchanged except as below)
```

**Why a new gateway, not `sp_econ`.** `sp_econ` is bet/settle-shaped (`tryBet()` → `settle(result)`,
a wager round with a paytable). The cage is debit/credit-shaped: no round, no result, no house
evaluation. Both need the same card-session machinery — re-read the card on `disk` events, write the
mirror, flush the outbox, capture the id at commit time. `cage_econ` reuses `card` + `wallet` and
stays small. Two small gateways beat one gateway with two personalities.

`cage_econ` surface (mirroring `sp_econ`'s shape so stations feel alike):

| Method | Returns |
| --- | --- |
| `M.new(cfg)` | session; flushes outbox + reads card at construction |
| `self.onEvent(ev)` | re-reads card on disk events |
| `self.tryDebit(amount)` | `"ok"` \| `"deny"` (insufficient/hub down) \| `"nocard"` |
| `self.deposit(amount)` | new balance (credit is guaranteed via outbox) |
| `self.refund(amount)` | credit back after a short move — same path as deposit |
| `self.status()` | `{ player, balance, denied }` |

### Core changes (small, and they pay forward)

1. **`wallet.debit(id, amount)`** → hub `debit{id, amount}` → `debit_ok{id, balance}` |
   `debit_deny{id, balance, reason}`. Hub handles it through the **same `ledger.debit` + persist path
   as `bet`** — roughly ten lines. `bet` would work unchanged, but "bet" in the hub's ledger for a
   cash withdrawal is a lie we'd read back later. `bet` stays the slot's wager-round special case.
2. **`credit_deny`** — closes latent follow-up **F2**: a credit to an unknown id currently replies
   `balance = nil` and is treated as acked, silently dropping it. The cage makes this reachable
   (deposit against a card whose ledger id is gone), so fix it here.
3. **`pixelfont`** — add a `scale` parameter to `drawGlyph`/`drawText`/`drawCentered`/`textWidth`
   (each glyph pixel becomes an N×N block; `gap` stays raw subpixels, **unscaled**) and the owner's
   two `$` glyph tables (see below). A 1× number is 6 subpx tall on a canvas twice the slot's width;
   the balance is the emotional center of this screen.

### What this enables (forward-look — do NOT build now)

Recorded so the `mp_econ` brainstorm starts here instead of rediscovering it:

- **`wallet.debit` is the multiplayer primitive.** An MP pot is "debit each player, credit the
  winner"; the trading station is "debit sender, credit receiver". Both are this pair. The cage is
  simply its first caller.
- **`credit_deny`** matters more in MP (a winner whose card walked away) than it does here.
- **Card-session extraction is a rule-of-three call.** `sp_econ` and `cage_econ` are instances one
  and two. `mp_econ` is three — *then* extract `lib/card_session.lua`, with three real callers
  proving the shape. Extracting from two would be guessing.
- **`card.read()` takes the first drive with a disk.** Single-card-per-station is baked in. MP
  wagers need N cards → N drives → `card.readAll()` / `card.read(drive)`. This is the real work item
  sitting between here and `mp_econ`. The cage does not need it; do not build it.

## The shower — a tick-driven queue, never a blocking loop

`pending` is a count of items owed to the floor. Each tick, `cage_vault` round-robins the next few
items into the droppers and `cage_hw` pulses the line once. Taps **push onto `pending` while it
drains**, so bursts overlap and spamming compounds instead of being swallowed.

This is not just feel — a blocking `for i=1,n do pulse(); sleep(0.05) end` would hold `os.pullEvent`
and swallow the tick timer and touch events, which is exactly the `[[event-pump-reentrancy]]`
failure that froze the slot on a card swap. The queue keeps the pump free.

## Screen — 36×24 cells (72×72 subpx, exactly square)

Per `.claude/skills/cc-lua/kb/monitor-resolution.md`: `cols = round((2 − 0.3125) / (0.5·6/64)) = 36`,
`rows = round((2 − 0.3125) / (0.5·9/64)) = 24`. Bands use slot's `Rl(row) = (row-1)*3 + 1` helper.

**Owner-approved layout** (`tools/cage-preview.html`, signed off 2026-07-16). The preview is the
source of truth for every constant; the plan carries them.

```
row  1-2   header      native: player name (col 3) · status right-aligned to col 35
row  3-7   BIG $        owner's $ glyph @1× (7×14) + digits @2× (8×12): 61 of 72 subpx
row  8-9   ══ bar ══    red + bulbs
row 10-17  MATERIALS    4 buttons × 9 cells, black box: ingot sprite (rows 10-12),
                        native "Withdraw" (13) / "COPPER" (14) / "$25" (16)
row 18-19  QTY          [ 1x ] [ 5x ] [ 20x ] — selected = yellow (slot's stake idiom)
row 20-21  ══ bar ══    red + bulbs
row 22-24  DEPOSIT      full-width, 3 cells tall, STEEL BEVEL (pushed-in on tap)
           side bulb lanes cols 1 & 36, rows 3-7 extended one bulb up into the header
```

- **Palette identity: green↔gold gradient** on slot's existing `GRAD` + `bulb()` machinery. Same
  kit, different money — the floor should read as a district, not a clone.
- **The delta-tinted counter** (reusable pattern): the balance tints by direction — **gold climbing,
  pink falling, white at rest**. The tint is the feedback; you read "being paid" / "spending" before
  you read the digits. **Pink, not red**: stock red is luminance 114 and the gradient's gold band is
  ~118, so a red number vanishes on half the drift — and a cell holds 2 colours, so no outline can
  save it. Pink 200 reads as "down" and clears the ground at both ends.
- **The palette, not screen space, is the scarce resource.** 16 slots, all spoken for: gradient 4
  (blue/purple/magenta/cyan) · content 10 (white text+bevel-light, orange copper, lightBlue diamond,
  yellow bulbs+qty-selected+count-up, pink count-down, gray bulbs-off+bevel-dark, lightGray iron+
  bevel-face, green press-flash, red bars, black panels) · free 2 (lime, brown). Slots are **global
  to the monitor**, so a station affords *one* bevel ramp shared by all its buttons — which makes a
  bevel a station's signature rather than decoration.
- **Bevel ramp = steel** (white 240 / lightGray 153 / gray 76 → +87/−77). The only true ramp in CC's
  stock 16: the greens (161/132/17) have no highlight, and the reds — plentiful by count — put red at
  114 and brown at 106, eight points apart, so they have **no shadow**. Steel costs no slots.
- **No card ⇒ not the kiosk.** Controls aren't drawn at all (drawing them dead lies about what's
  tappable) and there is **no `$0`** (that reads as "you're broke", not "no card"). The screen shows
  the rate table instead — the wait is the one moment a player has nothing to do, so it teaches.
- **6-digit ceiling** at 2× ($999,999). Beyond that the number clips; the fix is a 1× fallback.
  Out of scope now (the slot pays 25× a $100 stake), but named rather than discovered at $1M.
- `monitor_touch` is diegetic here (settled in slot v3): physical in-world interaction, not a
  terminal GUI. Hit-testing is **cell-space, band-first** — slot's `stakeAt(tx, ty)` pattern.

### The `$` glyphs — two sizes, not two scales

The owner drew **two** `$`: 5×10 (`mockup(3).json`) and 7×14 (`mockup(4).json`). These are separate
glyphs, **not** one scaled: `scale` doubles pixels (5×10 @2× = a chunky 10×20 of the same drawing),
whereas the 7×14 carries hand-drawn detail no scaling could produce. Both go in the library as
`SIGN_SM` / `SIGN_LG`; `scale` stays orthogonal to both. The cage uses **LG at 1×** beside 2× digits:
14 tall against 12, overshooting a subpixel above and below, which is how a `$` sits against figures.

### UI review gate — CLEARED (2026-07-16)

`tools/cage-preview.html` was built and signed off by the owner before implementation, per the
golden-standard loop in `kb/monitor-ui-workflow.md`. Layout got right when it was cheapest.

## Failure behavior

| Case | Behavior |
| --- | --- |
| No card | Material/qty/deposit buttons inert; big number `$0` dim; header `INSERT CARD`. Never a gate. |
| Hub offline — withdraw | Debit fails closed ⇒ no items move. `HUB OFFLINE`. |
| Hub offline — deposit | Credit outboxed, items still move to vault, number counts up. Deposits are guaranteed (existing `wallet.credit` contract). |
| Insufficient `$` | Deny **before** debit. `NEED $2000`. |
| Vault short | Deny **before** debit. `VAULT: 3 IRON`. |
| Move came up short | `refund()` the difference — the debit already happened. |
| Junk in deposit chest | Valued at 0, left in the chest, never moved to the vault. Fails safe: never eats tools. |
| Card ejected mid-shower | Shower completes (already paid for). Id is captured at debit time — the `stakedId` lesson from `kb/economy.md`. |

**Ordering is the invariant: stock check → debit → move → (refund if short).** Never move before
debiting; never debit before confirming stock.

## Testing

- **Unit-tested (pure):** `cage_vault` — valuation of a chest listing, withdraw planning, dropper
  round-robin. `cage_rates`. The `pixelfont` `scale` + `$` additions. Same idiom as `slot_logic` /
  `ledger`.
- **Not unit-tested:** `cage_hw` (thin peripheral I/O), `cage.lua`'s draw code — verified by the
  offline PNG render (sim reuses the real `subpixel.lua`) plus in-world.
- **Syntax:** `luajit -bl` on every file, per the build workflow.
- **In-world:** mint → insert → deposit mixed chest (with junk) → withdraw each denom → spam-tap →
  vault-empty deny → insufficient deny → hub-offline both directions → eject mid-shower.

## Deploy

New `cage` package in `src/packages.lua`, `station = true`. Files: `idle_logic`, `idle_runner`,
`subpixel`, `pixelfont`, `card`, `wallet`, `cage_econ`, `cage_rates`, `cage_vault`, `cage_hw`,
`cage_symbols`, `cage_advert`, `cage`. Mind the raw-CDN lag (`CLAUDE.md`): wait 2–5 min after the
push before `update cage`, and expect a retry or two on a brand-new package.

## Out of scope

Make-change · buy/sell spread · multi-denomination cart · confirm dialogs · AP Inventory Manager
(binds one player per memory card — breaks walk-up-and-play; the chest+dropper model works for
anyone) · the trading station · scoreboards · `mp_econ`.
