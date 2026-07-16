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
src/            Lua programs (one game per file); import these in-game
  hello.lua     smoke test — CraftOS version + HTTP status
  pong.lua      reference minigame: 2-player Pong, 4 pressure plates → 4 sides
  slot*.lua     slot machine v1 (+ src/lib/subpixel.lua canvas)
.claude/skills/cc-lua/   the project skill (read before writing Lua)
README.md       meta design doc (read first)
todo.md         per-component status / next steps
```

## Conventions

- One program per file in `src/`, `.lua` extension, filename = the in-game program name.
- Header comment on every program: what it does, how to run it, wiring notes.
- Prefer an in-game `.cfg` file for per-build settings (redstone side mappings, monitor
  names) so the user can reconfigure without re-importing.
- Design principles (diegetic input, idle-asleep, hub-authoritative, monochrome default)
  live in `README.md` — honor them; don't restate them here.
