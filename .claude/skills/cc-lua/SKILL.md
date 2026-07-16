---
name: cc-lua
description: Use when the user asks to write, create, edit, debug, or explain a Lua program for CC:Tweaked (ComputerCraft) in this project — in-world monitor minigames controlled by physical Minecraft blocks (pressure plates / buttons / levers via redstone). Targets Seansemperfi's Atlas Server (CC:Tweaked for Minecraft 1.21.1, joined as a remote multiplayer server). Covers writing correct CraftOS/Lua 5.1, looking up the real CC:Tweaked API, and delivering programs into the game over HTTP (pastebin / wget).
---

# CC:Tweaked minigames — Atlas Server

## What this project is

Small **minigames rendered on in-world CC:Tweaked monitors**, controlled **diegetically** — players interact with physical Minecraft blocks and watch the real monitor. No terminal GUI, no keyboard-driven gameplay. `src/pong.lua` is the reference implementation.

## Environment (fixed facts — do not re-derive)

- **Mod:** CC:Tweaked for Minecraft 1.21.1 (Forge). Runtime = **CraftOS**, **Lua 5.1**.
- **Multiplayer:** the user *joins* a remote server (`servers.dat` present, local `saves/` empty). They are NOT the host, so in-game files live on the server's disk — **you cannot drop a `.lua` into the world from disk.** Delivery is HTTP-only (see Deploy).
- **HTTP config (pack default):** `http.enabled = true`; `$private` (localhost/LAN) **denied**; `*` **allowed**. Public URLs (pastebin, gist raw) work; localhost does not.
- Instance path: `C:\Users\miasm\curseforge\minecraft\Instances\Seansemperfi's Atlas Server`.

## HARD RULE — diegetic in-world input only

**Game controls MUST be physical, in-world interactions — never a keyboard/terminal GUI.** Physical
blocks read via redstone (pressure plates / buttons / levers) are the default. **`monitor_touch` IS
allowed** — right-clicking an in-world monitor is a physical-world interaction, not a terminal GUI, so
it's diegetic (e.g. slot v3's tap-to-select stake buttons). The ban is on **keyboard / `key` / `char`
gameplay**. (A keyboard `Q` / Ctrl+T admin quit is fine — quitting isn't gameplay.) See
[[diegetic-input-preference]] and `kb/monitor-ui.md`.

- Read the computer's **6 sides**: `redstone.getInput(side)` → boolean. `side` ∈ `"top" "bottom" "left" "right" "front" "back"`, relative to computer facing (`front` = screen direction). Up to 6 physical controls per computer.
- **POLL every physics tick** — a player standing on a pressure plate holds the signal high with no new events, so read `getInput` inside the tick loop for continuous hold-to-move. The `redstone` event only fires on change; don't depend on it for held input.
- **Free up sides:** put the monitor on a **wired modem + networking cable** so it doesn't consume a side. `peripheral.find("monitor")` still finds it over the network.
- **Side names confuse players.** Put the side→control map in a config block at the top of the file, and ship a `test` sub-mode that live-displays each side's on/off so the user can identify which plate feeds which side, then edit the map. `src/pong.lua` shows both.
- Control blocks: **pressure plates** (hold-to-move), **buttons** (momentary tap), **levers** (toggle/hold). For many signals on one side, **bundled cable** (`redstone.getBundledInput`/`testBundledInput`) — only if the pack ships bundled cables (an addon; don't assume). `rednet`/modems may link builds, but the player-facing control must be a physical block.

## Monitor minigame pattern (reuse for every game)

- **Find the screen:** `local mon = peripheral.find("monitor")`; `error(...)` clearly if absent.
- **Flicker-free draw:** wrap the monitor in a `window` (`window.create(mon,1,1,W,H,true)`); each frame do `win.setVisible(false)` → redraw → `win.setVisible(true)` to flush at once. Never draw to the raw monitor frame-by-frame.
- **Fit any size:** `W,H = mon.getSize()` at runtime; scale the game to it. Never hardcode monitor dimensions. Tune granularity with `mon.setTextScale(0.5..1)`.
- **Loop = event loop:** one `os.pullEvent` loop; `os.startTimer(dt)` drives physics/redraw ticks; poll redstone inside each tick; restart the timer each tick. Always yield — never a busy `while true do end`.
- **Palette:** `colors.white` / `colors.black` only, unless the user confirms an **advanced** (gold-bordered, colored) monitor. Regular monitors are monochrome.
- **Cleanup on exit:** clear the monitor, `setTextScale(1)`, restore the terminal.

## Writing CraftOS Lua (5.1) — rules

- Lua **5.1**: no `goto`, no `//`, no native bitwise ops (use `bit32`), `#t` for length.
- Use the CC API, not host-Lua assumptions. Core modules: `term fs http os peripheral redstone textutils colors keys parallel window paintutils rednet settings`.
- Every turtle movement/dig returns `false` on failure — always check and handle it. Turtles need fuel unless the server disabled it.
- Guard optional hardware (`if http then`, `if peripheral.find(...) then`) so programs degrade gracefully.
- Prefer clear `print`/`error(msg)` failures — the user debugs from the in-world terminal.
- One program per file in `src/`, `.lua` extension, filename = the in-game name. Add a header comment: what it does + how to run + wiring notes.

## Look up the real API — don't guess

Authoritative docs: **https://tweaked.cc/**. When unsure about a function, signature, event, or peripheral method, **WebFetch the exact page** instead of guessing:

- Modules (global APIs): `https://tweaked.cc/module/<name>.html` — e.g. `os`, `redstone`, `term`, `window`, `colors`, `keys`, `turtle`, `parallel`, `textutils`, `rednet`, `settings`, `paintutils`, `peripheral`.
- Peripherals: `https://tweaked.cc/peripheral/<name>.html` — e.g. `monitor`, `modem`, `speaker`, `drive`.
- Events: `https://tweaked.cc/event/<name>.html` — e.g. `redstone`, `monitor_touch`, `timer`, `key`, `modem_message`.

Fetch the page for the module you're using before relying on memory for a signature. See `[[cc-api-docs]]` memory.

## Knowledge base — empirical, server-only findings (`kb/`)

`kb/index.md` is a living wiki of things learnable **only on the real server** — monitor
rendering, peripheral quirks, redstone timing — and cases where the world contradicts the
docs/intuition. It is the home for those findings so this skill stays a stable how-to.

- **READ before building/debugging** monitor UI, peripherals, or redstone: skim `kb/index.md`
  and open any entry matching your `area`/tags. These are mistakes already made in-world.
  **Building a monitor UI? Follow `kb/monitor-ui-workflow.md`** — the project's golden-standard loop
  (owner mockup → live `tools/slot-preview.html` → Lua → verify offline by rendering to PNG → deploy).
- **WRITE when you learn** a server-only or docs-vs-reality fact: add/update a `kb/` entry
  (see the format in `kb/index.md`) instead of inlining a one-off example here. Don't log
  things testable in plain Lua.
- Seed entry: `kb/monitor-ui.md` — watchdog "too long without yielding", fractional-coord
  `setPixel` crash, palette animation + dark-colours-read-as-black, no native clipping,
  window+`setVisible` flicker-free draw, multi-file re-import traps, analog lever input.

## Local references (authored how-to)

- `references/subpixel-drawing.md` — the reusable 2×3 teletext subpixel canvas (`src/lib/subpixel.lua`):
  chars 128–159, `term.blit`, how to draw pixel art at 6× the cell resolution.

## Deploy / test loop (getting code onto the server to test)

Canonical repo: **`miasmile111/cctweakvegas`** (public, `gh` authed as `miasmile111`). Raw base:
`https://raw.githubusercontent.com/miasmile111/cctweakvegas/main/src/`. You push; the user pulls
in-game with `update`. **The in-game copy is a snapshot** — nothing lands until pulled. Full
design: `docs/superpowers/specs/2026-07-16-station-identity-and-deploy-design.md`.

**Loop:** edit `src/` → **`git push`** → in-game **`update <pkg>`** (e.g. `update slot`). One
`update` run:

1. **Self-updates** — re-pulls `update.lua`; if changed, relaunches the new copy with the same
   args (one-run seamless). A stale master floppy self-heals on first use.
2. **Pulls the package's files** — from `src/packages.lua` via `http.get` with a `?cb=<epoch>`
   cache-buster (defeats raw.githubusercontent's ~5-min CDN cache), overwriting (no `wget`).
3. **Registers with the hub** — rednet proto `ccvegas`, hub hosts hostname `hub` → assigns a
   unique label (`slot2`, or `slot2+pong1`). Hub offline → loud fail, files still install.
4. **Enables auto-run** (station packages) — writes a marked `startup` supervisor that boots the
   game + self-heals; break out with a key at boot / Ctrl+T / a key in the 3s post-exit window.

**Programs:** `update`, `hub` (v0 registrar — run on an always-loaded computer + modem),
`mkinstaller` (mints installer floppies), plus the games. Packages defined in `src/packages.lua`.

**Fresh station** = computer + **disk drive** + **wired modem**. Bootstrap with a master floppy
(a floppy carrying `update` — make one with `mkinstaller` or `cp update /disk/update`): insert it,
run `/disk/update slot`. Or `wget <raw base>/update.lua update` once.

**Why not plain `wget`:** it **refuses to overwrite** an existing file and doesn't cache-bust.
Per-station settings (side maps, monitor names) still belong in an in-game `.cfg` read at startup.

**Fallback (throwaway):** gist → `wget <raw-url> <name>`, or `pastebin get <code> <name>`.

## First-time / smoke test

If the pipeline is unproven, have the user import `src/hello.lua` and run `hello` — it prints the CraftOS version, computer ID, and whether the `http` API is available (required for imports).
