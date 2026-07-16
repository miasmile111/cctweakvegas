---
title: A redstone pulse REQUIRES a yield between on and off (same-tick toggle is a silent no-op)
area: redstone
verified: in-game 2026-07-17 (cage shower working on the live server) + source-read (CC:Tweaked RedstoneState)
tags: [redstone, setOutput, getOutput, pulse, dropper, dispenser, piston, rising edge, cooldown, triggered, tick, updateOutput, no-op, silent failure, falling edge, stale high]
---

**Symptom.** A program "pulses" a redstone line and **nothing in the world reacts** — no dropper
fires, no piston moves. No error, no crash; the Lua side is convinced it worked. `getOutput` even
reports the pulse. In the case that found this, the cage kiosk debited the player's card, counted
the balance down and flashed the bars for a withdrawal that dropped **zero** ingots: a one-way money
shredder.

**Cause.** This is a no-op:

```lua
redstone.setOutput(side, true)
redstone.setOutput(side, false)   -- same tick: the world NEVER sees the edge
```

`setOutput` does **not** touch the world. It writes CC's *internal* redstone state and sets a dirty
flag; the world is synced afterwards, on the computer tick, by `updateOutput()`, which computes the
sides to push by diffing `externalOutput[i] != internalOutput[i]`. From the `RedstoneState` javadoc:
*"Whenever a computer sets a redstone output, the 'internal' state is updated, and a dirty flag is
set. When the computer is ticked, `updateOutput()` should be called, to copy the internal state to
the external state."* With no yield between the two calls, internal ends `false`, external was
already `false` → nothing differs → **no block update ever leaves the computer.**

And `getOutput` reads the **internal** value, so **Lua cannot self-diagnose this** — it faithfully
reports the pulse it never sent. There is no in-game assertion that catches it; only the absence of
world reaction does.

**Fix.** Split the pulse into two halves and let the event loop's own yield sit between them. Split
the *API* too — a `pulse()` that does both is a loaded gun for the next reader:

```lua
function hw.pulseOn()  redstone.setOutput(side, true)  end
function hw.pulseOff() redstone.setOutput(side, false) end
```

Then drive them off the station's existing tick loop by phase — **never** with `sleep()` or a nested
`os.pullEvent` inside a play loop (that is the `[[event-pump-reentrancy]]` freeze):

```lua
-- in the timer branch of the play loop.  `pulsed` and the entry pulseOff are NOT optional — see below.
hw.pulseOff()                    -- ONCE on entry: never inherit a line someone left HIGH
...
local phase = tick % 6
if     phase == 0            then hw.pulseOn();  pulsed = true
elseif phase == 2 and pulsed then hw.pulseOff(); pulsed = false
                                  loads = pulseLoads(loads)   -- decrement on the FALLING edge
end
```

**Two ways to get this wrong even after splitting the pulse. Both cost the player metal, silently:**

1. **Decrementing without having raised the line.** Work arrives at an arbitrary tick (a player taps
   mid-cycle), so the *very next* tick can be phase 2. An unguarded `elseif phase == 2` then fires
   `pulseOff` + decrement having **never** pulsed on: no rising edge, no ingot, but the counter moved.
   The player pays, nothing drops, and the item sits in the dropper until it falls out during someone
   **else's** withdrawal — so the count-down desyncs from the floor too. Measured at **~1 tap in 3**
   (2 of 6 phases). The `pulsed` flag is the whole fix: *never decrement without a real rising edge.*
   Cost: at most 5 ticks (0.25s) of latency while a tap waits for the next phase 0.
2. **Inheriting a stale HIGH line.** CC **persists redstone output when a program exits**, and Ctrl+T,
   an uncaught error and a chunk unload all skip whatever cleanup the quit path does — Ctrl+T doesn't
   even reboot. Start with the line already high and the first `pulseOn` is *no edge*: the first cycle
   is debited and ejects nothing. Force `pulseOff()` on entry; the loop's own `os.pullEvent` is the
   yield that flushes it. (Drop the line on the quit path too, but don't rely on it.)

**The diagnostic trap.** A `test`/`drop` command that pulses in a tight `pulseOn; sleep; pulseOff;
sleep` loop **always pairs its edges**, so it is immune to (1) and (2) — it will happily report *"the
pulse works, ingots on the floor"* while the real play loop shreds a third of the taps. A green light
from a tool that cannot see the failure is worse than no tool. If you build a hardware self-test, make
it exercise the **same** code path as the game, or state plainly what it does not cover.

**The second constraint: the receiving block has a rate.** A **dropper/dispenser ejects on the
RISING EDGE only** and then has a **4-game-tick (0.2s) cooldown** — the `triggered` blockstate blocks
re-trigger until the line falls. So even a *correct* pulse, fired every 0.05s tick, runs **4× the
block's physical rate**: a per-tick counter drains four times faster than items actually eject and
strands the rest inside the dropper. The cage uses **6 ticks (2 high, 4 low = 0.3s/item)** — a 50%
margin so server lag cannot swallow a rising edge. Decrement your queue on the **falling** edge, so
one completed cycle = one item that really flew.

**Sibling trap, identical symptom:** putting the redstone output on the **same side as the wired
modem**. `setOutput` drives the modem block instead of dust and nothing ever fires — indistinguishable
from a dead pulse at a glance. Keep the modem and the line on different sides (the cage: modem right,
line back).

**So what.** Any program that pulses redstone — droppers, dispensers, pistons, Create contraptions,
a physical minigame's actuators — must (1) yield between on and off, and (2) pace itself to the
target block's cooldown. This cost the cage a **full build cycle**: the bug was mandated verbatim by
the spec and plan, transcribed faithfully by the implementer, and the per-task review verified the
wrong thing correctly. It was caught only by a whole-branch review reading the CC:Tweaked source.
See `[[event-pump-reentrancy]]` for why the fix must not be `sleep()`.
