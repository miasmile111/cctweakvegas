# cctweaked — project guide

## Purpose

This project authors **Lua minigames for CC:Tweaked (ComputerCraft) monitors**, played on
**Seansemperfi's Atlas Server** (CurseForge; CC:Tweaked for Minecraft 1.21.1, Forge).

The defining constraint: every minigame is **diegetic** — rendered on an **in-world monitor**
and controlled by **physical Minecraft blocks** (pressure plates, buttons, levers) read via
redstone. Players interact with the world and watch the real monitor; **no terminal GUI,
keyboard, or touch input for gameplay.**

The user prompts Claude Code → Claude writes `.lua` files into `src/` → the user hosts them
(pastebin / GitHub gist) → imports them in-game over HTTP.

## Use the `cc-lua` skill

For ANY request to write, edit, debug, or explain a CC:Tweaked Lua program here, use the
**`cc-lua`** skill (`.claude/skills/cc-lua/SKILL.md`). It holds the environment facts, the
diegetic-input rule, the monitor-minigame pattern, CraftOS/Lua 5.1 rules, the CC:Tweaked API
lookup sources (https://tweaked.cc/), and the deploy/test loop. Follow it.

## Key facts a new session needs

- **Remote server** — the user *joins*, doesn't host. In-game files live on the server's
  disk; you can't drop files into the world locally. **Import is HTTP-only** (`pastebin get`
  / `wget` from public URLs). HTTP is enabled; `$private` denied, `*` allowed.
- **Runtime:** CraftOS, Lua 5.1.
- **Input is physical/redstone**, polled each tick (a held pressure plate emits no event).
  Read the computer's 6 sides with `redstone.getInput(side)`; put the monitor on a wired
  modem to free sides for controls.
- **Look up the API** at https://tweaked.cc/ (`/module/`, `/peripheral/`, `/event/` pages) —
  WebFetch the exact page rather than guessing signatures.
- The in-game copy is a snapshot — re-host + re-import after every edit.

## Layout

```
src/            Lua programs (one game per file); import these in-game
  hello.lua     smoke test — prints CraftOS version + HTTP status
  pong.lua      reference minigame: 2-player Pong, 4 pressure plates → 4 computer sides
.claude/skills/cc-lua/   the project skill (read it before writing Lua)
README.md       import workflow reference
```

## Conventions

- One program per file in `src/`, `.lua` extension, filename = the in-game program name.
- Monochrome (white/black) unless the user confirms an advanced (colored) monitor.
- Header comment on every program: what it does, how to run it, wiring notes.
- Prefer an in-game `.cfg` file for per-build settings (e.g. redstone side mappings) so the
  user can reconfigure without re-importing.
