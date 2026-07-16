# cc-lua knowledge base (empirical findings)

A living wiki of things about the **CC:Tweaked runtime that you can only learn on the real
server** — behaviour that can't be tested from the PC, and cases where the actual monitor /
peripheral / redstone behaviour differs from what the docs or intuition suggest. Method
adapted from Karpathy's [llm-wiki](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f):
the KB is a maintained artifact that compounds, not a pile of one-off war stories in the skill.

This is the **home for those findings.** The `cc-lua` SKILL.md stays the stable how-to; when
we discover a server-only quirk, it goes *here* as an entry, and the skill just points at the KB.

## When to READ it

Before building or debugging any monitor UI, peripheral, or redstone code, **skim the catalog
below** and open any entry whose `area`/tags match — these are mistakes already made and
behaviours already confirmed in-world. Don't re-derive them.

## When to WRITE to it

Add or update an entry whenever you learn something that is:

- **Server-only** — provable only against the live game (real monitor rendering, peripheral
  quirks, redstone timing, watchdog limits, multiplayer-server lag effects), OR
- **Docs-vs-reality** — the API page / your intuition said one thing, the world did another.

Do **not** log things testable in plain Lua, or that already live in the skill/docs. One
finding that reads as a small guide is fine (see `monitor-ui.md`); split it once it sprawls.

## Entry format

One finding (or tight cluster) per file, kebab-case name (`palette-dark-reads-black.md`), with:

```
---
title: <human title>
area: monitor-ui | peripheral | redstone | deploy | lua-runtime | ...
verified: in-game YYYY-MM-DD   # or: untested / docs-only — say how sure we are
tags: [ ... searchable keywords ... ]
---
```

Body: **symptom → cause → fix** (or claim → evidence → so-what). Include keywords on purpose;
this index + in-file search is the whole retrieval system. Cross-link related entries and
memories with `[[wikilink]]`.

## Create vs update

New file when it's a **distinct** quirk you'd link to from elsewhere; edit in place when it's
another facet of something already written. Keep this index's catalog in sync (one line each).

## Catalog

- [[monitor-resolution]] — `monitor-resolution.md` — the foundational model: cell (6×9 px) / subpixel
  (2×3 teletext, 2 colours) / real-px, `getSize`/`setTextScale`, and the **exact** block-layout→cell
  formula (from CC:Tweaked `ServerMonitor.rebuild`): `cols = max(1, round((blocksW−0.3125)/(scale·6/64)))`.
  Slot 1×2 @0.5 = 15×24. Read before any monitor-UI sizing decision. See `docs/monitor-resolution-lesson.html`.
- [[monitor-ui]] — `monitor-ui.md` — hard-won graphics pitfalls: the "too long without yielding"
  watchdog, fractional-coord `setPixel` crash, palette animation + dark-colours-read-as-black,
  no native clipping, window+`setVisible` flicker-free draw, multi-file re-import traps, analog
  lever input. *(A bundle — draw entries out of it as they're revisited.)*
- [[monitor-ui-workflow]] — `monitor-ui-workflow.md` — **the golden-standard loop for building any
  monitor UI**: owner draws in `tools/monitor-mockup.html` → export JSON → decode (per-cell dominant
  colour + raw-subpixel for fonts) → iterate in the live `tools/slot-preview.html` (renders the real
  layout + `encodeCell` truth) → port to Lua (1-indexed!) → **verify offline by rendering `cv.buf` to
  PNG** (luajit sim, no deploy) → ship. Plus the native-vs-subpixel-font decision and the "$ is width
  not colour" rule. Read before starting UI work; skip the slow screenshot-per-change deploy loop.
- [[deploy-and-identity]] — `deploy-and-identity.md` — code-delivery & station-identity facts:
  `wget` won't overwrite, raw-CDN 5-min cache + `?cb=` bust, rednet DNS only sees online nodes
  (→ hub is the registrar), `computerID` vs persistent label, `/disk/startup` override, chunk
  unload = reboot-fresh, Ctrl+T/`pullEventRaw` break-out, self-update-via-relaunch.
- [[redstone-pulse-needs-a-yield]] — `redstone-pulse-needs-a-yield.md` — `setOutput(side,true)` then
  `(side,false)` with **no yield between** is a **silent no-op**: `setOutput` only marks CC's internal
  state dirty, the world syncs on the computer tick by diffing external-vs-internal, and `getOutput`
  reads the internal value so Lua can't see it. Split into `pulseOn`/`pulseOff` driven off the play
  loop's tick phase. Plus: a dropper needs **≥4 game ticks** between rising edges (cage uses 6); the
  line must never share a side with the wired modem; **never decrement a queue without having raised
  the line** (~1 tap in 3 lost) and **never inherit a stale HIGH line** (CC persists output past exit).
  And the trap that makes it worse: a paired-edge `test`/`drop` tool is immune to both and will report
  success while the game shreds taps. Cost the cage a full build cycle.
- [[open-every-modem]] — `open-every-modem.md` — **the floor is not one network.** Opening ONE modem
  and preferring wired goes deaf to a hub reachable only by **ender modem** → `REGISTRATION FAILED —
  HUB OFFLINE` against a hub that's running. Open **every** modem at every rednet entry point (station
  runtime, installer, **the hub itself**, admin tools). Safe: rednet send/broadcast already transmit on
  all open modems and the daemon de-dupes by `nMessageID` (~9.5s) → no double-debit. Includes how to
  tell this apart from an old hub that doesn't know your message `kind`.
- [[station-hardware-discovery]] — `station-hardware-discovery.md` — **identical builds do NOT get
  identical peripheral names** (CC burns `<type>_<n>` indices on attach/detach; the first cage's
  droppers came up 1-4). Discover by TYPE; pick the monitor by **size**, not `find("monitor")` (two
  monitors = a coin-flip boot) and restore the scale on the ones you reject. Deposit-vs-vault is the
  one thing only a human knows → convention + override. `update` **overwrites the program**, which is
  why per-station wiring belongs in the `.cfg` and nowhere else. Plus the `<station> test` pattern.
- [[event-pump-reentrancy]] — `event-pump-reentrancy.md` — a nested `os.pullEvent` loop (rednet
  round-trip, `rednet.lookup`, `sleep`, `parallel`) called from inside a play loop **eats the outer
  loop's own tick timer** → silent freeze (program "running", reboot to clear). One event queue per
  computer. Fix: stash + `os.queueEvent` the foreign events back; cache blocking lookups.
