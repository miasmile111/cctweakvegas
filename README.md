# cctweaked — the Hub (meta design)

> Living design doc for the whole project. Read this first, every session. It holds the
> **why** and the **shape** — not Lua syntax (that's the `cc-lua` skill) and not the
> import/deploy workflow (that's `CLAUDE.md` + the skill). Keep it succinct; expand it as
> the base grows.

## Vision

A diegetic **minigame hub** built inside Minecraft on Seansemperfi's Atlas Server — a
Vegas / Macau / Tokyo gambling-district *feeling*: neon, noise, a floor of machines you
walk up to and play. Every game is rendered on **real in-world monitors** and/or built as
**physical Create contraptions**, and controlled by **physical blocks** (levers, buttons,
pressure plates) via redstone. Games are **1 player or 2–4 players**. A lightweight
**membership economy** ties the floor together: winnings from any game accrue to your
personal card. Built on **CC:Tweaked** + **Create: Simulated**.

## Core principles

Every part of the base obeys these. When a design choice is unclear, these decide it.

1. **Diegetic input only.** Controls are physical in-world blocks read over redstone —
   levers, buttons, pressure plates. No terminal GUI, keyboard, or touchscreen for gameplay.
2. **Idle = truly asleep.** No game loop runs without a redstone-certain signal that a
   player is present. Server lag is the enemy; with many machines on the floor, no station
   may burn cycles while unattended. Three tiers:
   - **Deep sleep** — zone empty. Computer blocks on an event (`os.pullEvent`), ~zero cost.
   - **Attract** — a proximity sensor (e.g. pressure plate) detects a nearby body → a Vegas
     advertisement animation plays ("COME PLAY, GET MONEY"). Runs *only* while someone's in
     the zone; wakes quietly, without the player having to ask.
   - **Armed round** — the start control (lever/button) is triggered → the full game loop
     runs for that one round, then falls back to attract or sleep.
3. **Hub-authoritative economy.** One server holds the canonical score per player. Games
   report *changes*; they never own the truth.
4. **Cards are optional flavor, never a gate.** The floppy-disk membership card is a fun
   meta-layer for tracking winnings — a game is fully playable with no card inserted (just
   untracked / anonymous). Never require a card to play.
5. **Monochrome by default.** White/black monitors unless a build confirms an advanced
   (colored) monitor. Games scoped to 1–4 players.

## System architecture

Three roles on one **rednet** bus.

```
   [ Game station ]      [ Game station ]      [ Game station ]   ... (many)
        |  ^
        v  |  report score delta / query balance
   ============================ rednet ================================
        |                                        ^
        v  apply delta                           | broadcast update
   [ Hub server ] --- canonical ledger: id -> score
        |
        v
   [ Scoreboard ] [ Scoreboard ] ...   (display-only subscribers)
```

- **Hub server** — one computer. Owns the ledger (`id → score`), persists it, answers
  balance queries, applies deltas from games, and broadcasts changes to scoreboards.
- **Game stations** — self-contained per game. Arm on redstone, run a round, and on payout
  send a *delta* to the hub. Read an inserted card only to learn *which* `id` to credit.
- **Scoreboards** — display-only. Subscribe to hub broadcasts, render standings on monitors
  around the floor.

**Station identity & setup.** Every station is **computer + disk drive + wired modem** (drive =
member cards; modem = rednet + monitor over the network). Installing a game (`update slot`)
auto-assigns the computer a unique, collision-free name (`slot2`) — the **hub is the registrar**,
persisting `computerID → instance` so asleep stations never clash. A new station self-installs
from an **installer floppy** (insert + reboot). See the deploy loop in `CLAUDE.md` and the spec in
`docs/superpowers/specs/`.

## Membership card

A **floppy disk** (CC item) each player owns; they pick a name at issue.

| Field   | Role                                                                |
| ------- | ------------------------------------------------------------------- |
| `id`    | Player identity (chosen name). The key the hub credits against.     |
| `score` | Cached mirror of the hub's canonical value, for local display only. |

- **Authoritative score lives on the hub**, not the disk. The disk carries `id`; `score` on
  it is a convenience copy the hub keeps fresh. (Trust model: close friends — no anti-cheat,
  security is out of scope.)
- **Lifecycle:** insert card at a station's disk drive → station reads `id` → play → on a win
  the station sends `+delta` for that `id` to the hub → eject to leave. No card = anonymous
  round, nothing reported.
- **Extensible.** Start with `id` + `score`; add fields later (tier, tickets, stats) without
  reshaping the model.

## Rednet protocol (sketch)

Message *shapes*, not code — the contract between roles. Firmed up when the hub is built.

- `station → hub` — **credit**: `{ id, delta }` (award/deduct winnings for a round).
- `station → hub` — **query**: `{ id }` → hub replies `{ id, score }` (show balance at a machine).
- `hub → scoreboards` — **update**: `{ id, score }` broadcast (or a full standings snapshot).

Design intent: stations are fire-and-forget where possible; the hub is the only writer of truth.

## Create: Simulated

The base leans on **Create: Simulated** (the physics-contraption core of the Create
Aeronautics suite) alongside CC:Tweaked. It assembles blocks into rigid physics bodies and
exposes redstone components + a physics-interaction API. For a diegetic minigame floor that
means a game need not live only on a screen — it can have **real moving parts**: spinning
wheels, drop / plinko rigs, dice tumblers, race vehicles, physical prize / coin actuators.
CC:Tweaked is the brain (logic, scoring, monitors); Create: Simulated is the body (kinetics
the brain drives and reads over redstone). Games may be **monitor-rendered**, **physical
contraption**, or **hybrid**.

## Components & roadmap

| Component              | Status  | Notes                                                             |
| ---------------------- | ------- | ----------------------------------------------------------------- |
| **Deploy / identity**  | ✓       | `update`/`hub`/`mkinstaller`: push→pull, auto-name, auto-run. Spec in `docs/`. |
| **Slot machine**       | v1 ✓    | Lever-armed, monitor-rendered reels. See `todo.md` / `src/`.      |
| **Hub server**         | v0 ✓    | Registrar built (assigns station labels). **Economy = next.**     |
| **Idle / lag model**   | next    | Deep-sleep→attract→armed in each game; unblocks auto-run at scale. |
| **Membership cards**   | next    | Issue disks; card read/write; credit/query economy on the hub.    |
| **Scoreboards**        | planned | Rednet display subscribers around the floor.                      |
| **More games**         | ongoing | 1–4 player; monitor / Create-contraption / hybrid.                |

Each component gets its own detail as it's built (its `src/` files, its `todo.md` section).

---

*Import/deploy workflow and Lua/CraftOS syntax are **not** here — see `CLAUDE.md` for the
workflow and the `cc-lua` skill for implementation.*
