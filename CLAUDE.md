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
