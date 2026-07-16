# cctweaked — project guide

CC:Tweaked + Create: Simulated **minigames for a diegetic Minecraft gambling-hub base**,
played on in-world monitors / physical contraptions, controlled by physical blocks.

## Read these, in order

- **`README.md`** — the meta design doc: vision, core principles, the hub economy, the
  membership-card model, rednet architecture, roadmap. **Read it first, every session** —
  it's the *why* everything builds toward. Succinct by design; keep it that way.
- **`cc-lua` skill** (`.claude/skills/cc-lua/SKILL.md`) — the *how*: CraftOS/Lua 5.1 rules,
  the CC:Tweaked API lookup (https://tweaked.cc/), the monitor-minigame pattern, and the
  deploy/test loop with exact import commands. **Use it for ANY request to write, edit,
  debug, or explain Lua here.**
- **This file** — workflow pointers only. Don't repeat README's design content here.

## Workflow (deploy loop)

The user *joins* a remote server (doesn't host) → code comes in **over HTTP only**. Canonical
repo: **`miasmile111/cctweakvegas`** (public). Loop: you write `.lua` into `src/` → **`git push`**
→ in-game the user runs **`update`** (`src/update.lua`), which pulls that station's programs fresh
from the repo (cache-busted, overwrites — no `wget` delete dance). The in-game copy is a snapshot;
nothing lands until `update` runs. Exact `install.list` format + first-time setup: `cc-lua` skill.

> **Deploy gotcha — CDN lag.** `raw.githubusercontent.com` (Fastly) edge-caches ~5 min and does
> **not** reliably honor the `?cb=` cache-buster, so `update` run immediately after a `git push` can
> fetch a **stale `packages.lua`** — symptoms: a newly-added package reads as `unknown package`, or a
> package installs an old/short file list (missing a new module). It's not a code bug. Wait ~2–5 min
> after pushing, then re-run `update`. New-package installs may need a couple of retries.

## Build workflow — standing authorization

This is a **Minecraft-server hobby project, NOT production** — scope architecture accordingly; favor
the simplest thing that works, don't gold-plate. For any new build, run this chain **end to end
without pausing to check in at each gate** (the user has EXPLICITLY authorized this, incl. merging to
main and pushing — granted 2026-07-16):

0. **Read the project KB first.** Before brainstorming/researching a new feature or debugging,
   read the relevant repo `kb/` docs (`economy.md`, `advanced-peripherals.md`) **and** the `cc-lua`
   skill KB (`.claude/skills/cc-lua/kb/index.md` + matching entries). This local, in-world-verified
   knowledge comes **before** any external/web research — it's mistakes already made; don't re-derive.
1. **Brainstorm → spec** (`superpowers:brainstorming`), then self-check the spec (placeholders /
   consistency / scope / ambiguity). **No pause for spec sign-off.**
2. **→ `superpowers:writing-plans`** right after the spec self-check.
3. **→ `superpowers:subagent-driven-development`** right after the plan (fresh implementer + reviewer
   per task; fix Critical/Important findings; whole-branch review at the end). **No pause for the
   execution-choice prompt.**
4. **All green?** unit tests + `luajit -bl` syntax pass; per-task and whole-branch reviews clean.
5. **→ merge to main** (`superpowers:finishing-a-development-branch`, option 1) and **push** — the
   deploy loop pulls from the repo, so in-world verification happens *after* the merge+push.

Still stop for: genuine blockers, spec/plan contradictions, or irreversibly destructive actions.
Everything else: proceed.

## Layout

```
src/            Lua programs; import these in-game (deploy flattens every file by name)
  lib/          cross-station shared modules
    idle_logic.lua   pure presence/idle decision helpers (unit-tested)
    idle_runner.lua  shared idle lifecycle: deep-sleep/wake/presence; draws <name>_advert
    subpixel.lua     sub-pixel canvas
  hub/  hub.lua      the registrar + player-detector presence loop (always-on infra)
  slot/ slot.lua slot_logic.lua slot_symbols.lua slot_advert.lua   slot machine
  pong/ pong.lua pong_advert.lua   2-player Pong (4 pressure plates → 4 sides)
  hello.lua     smoke test — CraftOS version + HTTP status
  update.lua mkinstaller.lua packages.lua   deploy tooling + package manifest
.claude/skills/cc-lua/   the project skill (read before writing Lua)
README.md       meta design doc (read first)
todo.md         per-component status / next steps
```

A **station** = its own `src/<basename>/` folder with a play file + a `<basename>_advert.lua`
(the static idle advert). The shared `lib/idle_runner.lua` owns the deep-sleep/wake loop; a station
supplies only `play(mon, pres)` and the advert. Cross-station code lives in `lib/`.

## Conventions

- One program per file, `.lua` extension, filename = the in-game program name. Each station lives
  in its own `src/<basename>/` folder (play file + `<basename>_advert.lua`); shared code in `src/lib/`.
  Deploy flattens files by name, so `require("<name>")` never encodes the folder.
- Header comment on every program: what it does, how to run it, wiring notes.
- Prefer an in-game `.cfg` file for per-build settings (redstone side mappings, monitor
  names) so the user can reconfigure without re-importing.
- Design principles (diegetic input, idle-asleep, hub-authoritative, monochrome default)
  live in `README.md` — honor them; don't restate them here.
