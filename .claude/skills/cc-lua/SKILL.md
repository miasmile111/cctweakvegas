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

**Game controls MUST be physical Minecraft blocks read via redstone. Never use keyboard, `key`/`char`, or `monitor_touch` as a gameplay control.** (A keyboard `Q` / Ctrl+T admin quit is fine — quitting isn't gameplay.)

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

## Deploy / test loop (getting code onto the server to test)

You cannot push to the server; the user hosts the file and pulls it in-game. Standard loop:

1. Write/edit the program in `src/`.
2. User hosts it:
   - **Pastebin:** paste `src/<game>.lua` at https://pastebin.com → Create paste → note the code from the URL (`pastebin.com/AbCd1234` → `AbCd1234`).
   - **Gist (better for iterating):** paste into a public gist → click **Raw** → copy that URL.
3. Import in-game:
   - `pastebin get <code> <game>`  → run `<game>`
   - or `wget <raw-url> <game>`  (re-save gist + re-run `wget` to overwrite on each edit)
4. Iterate: edit `src/` → re-host → re-import. **The in-game copy is a snapshot** — edits on the PC don't reach the server until re-imported. For games with settings (e.g. side mappings), prefer an in-game `.cfg` file the program reads at startup so remapping doesn't require re-import.

**Optional automated upload:** if the user provides a Pastebin API dev key, you may `curl` the file to `https://pastebin.com/api/api_post.php` (`api_dev_key`, `api_option=paste`, `api_paste_code=@file`) via Bash and return the paste code directly — offer this only if they want to skip manual pasting.

## First-time / smoke test

If the pipeline is unproven, have the user import `src/hello.lua` and run `hello` — it prints the CraftOS version, computer ID, and whether the `http` API is available (required for imports).
