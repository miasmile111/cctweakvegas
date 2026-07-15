# cctweaked

Workspace for writing CC:Tweaked (ComputerCraft) Lua programs and getting them into
**Seansemperfi's Atlas Server** (CC:Tweaked for Minecraft 1.21.1, joined as a remote
multiplayer server).

## Workflow

1. Ask Claude Code to write/edit a program → it lands in `src/` as a `.lua` file.
2. Host that file publicly (pastebin or a GitHub gist).
3. Import it in-game over HTTP.

Because you *join* a remote server (you're not the host), you can't drop files into the
world save on disk — everything comes in over HTTP.

## Importing a file in-game

**Pastebin (simplest):**
1. Paste the file at <https://pastebin.com>, create the paste, note the code in the URL
   (`pastebin.com/AbCd1234` → `AbCd1234`).
2. In-game terminal: `pastebin get AbCd1234 hello`
3. Run it: `hello`

**GitHub gist / any raw URL (best for iterating):**
1. Paste into a public gist, click **Raw**, copy that URL.
2. In-game: `wget <raw-url> hello`
3. Edit → re-save gist → re-run the same `wget` to overwrite.

## First test

Import `src/hello.lua` and run `hello`. It prints the CraftOS version, computer ID, and
whether the `http` API is available (it must be, for imports to work).

## Notes

- Runtime is CraftOS / Lua 5.1.
- HTTP is enabled on the pack; `localhost`/LAN is blocked, public URLs are allowed.
- The `cc-lua` skill in `.claude/skills/` guides Claude Code when writing programs here.

## slot — two-monitor slot machine

Files: `src/lib/subpixel.lua` + `src/slot.lua` (+ `src/slot_logic.lua`, `src/slot_symbols.lua`).

Wiring: one computer; two ADVANCED monitors on a wired modem + networking cable. Top monitor
1×2 (portrait) = reels; front monitor 1×1 = touchscreen SPIN button.

Import (each file, over HTTP):
```
pastebin get <code> subpixel     # or wget <raw-url> subpixel
pastebin get <code> slot_logic
pastebin get <code> slot_symbols
pastebin get <code> slot
```
Then `slot test` to find monitor names → edit `TOP_NAME`/`FRONT_NAME` in `slot` → run `slot`.
Tap the front monitor to spin.
