---
title: A redstone relay is a PERIPHERAL, not a computer side — and a station must be told to use it
area: redstone
verified: in-game 2026-07-18 (pong's 4 pressure plates on one relay; commissioned start to finish)
tags: [redstone, relay, redstone_relay, peripheral, getInput, sides, controls, cfg, wiring, plates,
       pressure-plate, commissioning, diegetic, input, discovery, 1.114]
---

# A redstone relay is a peripheral, not a computer side

**Symptom.** Plates wired to a **redstone relay** produce nothing. `redstone.getInput(side)` reads
`false` on every side forever, the game never responds, and **nothing errors** — a station that looks
alive and is stone deaf.

**Cause.** `redstone.*` is the *computer's own six faces*. A relay is a separate block with its own
six faces, reached as a **peripheral**. Moving inputs onto a relay silently invalidates every
`redstone.getInput` call in a station, because the computer's sides are now genuinely never powered.

**Fix.** Wrap it and call the same method names on the wrapped handle.

```lua
local src = peripheral.wrap("redstone_relay_0")   -- or the global `redstone` table
if src.getInput("left") then ... end
```

## The fact that makes this cheap

**A relay's methods are NAME-IDENTICAL to the built-in `redstone` API** — `getInput`,
`getAnalogInput`, `setOutput`, `setBundledOutput`, `testBundledInput`, all of it (verified on
tweaked.cc). So a "redstone source" is **either** the global `redstone` table **or**
`peripheral.wrap(name)`, and they are duck-type interchangeable. No adapter layer is needed; the
whole abstraction is choosing which table to hold. That is what `src/lib/controls.lua` is.

**Version floor: CC:Tweaked 1.114.0.** Older builds have no `redstone_relay` peripheral type at all —
`peripheral.getNames()` won't list it and discovery-by-type hard-errors. If a server is older, the
only option is wiring the plates to the computer's own sides (`source = computer`).

## The commissioning trap that actually cost time

A station with **no `.cfg` at all** falls back to `source = computer`. So the diagnostic tool — the
one you run precisely *because* nothing works — cheerfully shows you the computer's six dead sides
and tells you nothing is happening. It is correct and useless simultaneously.

**Write `source = relay` into the station's `.cfg` FIRST, then run the test tool.** The tool must
also **print which source it resolved** (`INPUT TEST via redstone_relay_0`) — that one line is the
entire diagnosis, and without it "no side lights up" is indistinguishable from a wiring fault, a
missing modem, an old CC, or a relay that isn't on the network.

## Wiring checks, in the order worth trying

1. **Is the relay reachable?** `peripheral.getNames()` must list it. It has to be **adjacent to the
   computer** or on the **wired-modem network with the modem activated** (right-click; red ring = on).
   A relay wired only to the plates, with no path to the computer, is invisible.
2. **Are the plates feeding the RELAY's faces?** The relay reads its own six sides. Dust into the
   relay block, not into the computer.
3. **Version.** No `redstone_relay` in `getNames()` on a correctly-attached relay ⇒ CC < 1.114.

## Why this shape, for the next station

Per [[station-hardware-discovery]], names are not stable across identically-built stations, so:
discover the relay **by TYPE** (`peripheral.hasType(name, "redstone_relay")`), let an explicit name in
the `.cfg` always win, and **never hardcode a peripheral name in a station program** — `update`
overwrites the program and the `.cfg` is the only thing that survives.

**Fail loud at boot.** `controls.new` errors naming the missing logical input
(`controls: input 'p1_down' has no line in the station .cfg`). The alternative — a control that reads
"not pressed" forever — is the worst possible failure for a game, because it is indistinguishable
from a player not touching it.

**One relay = six inputs.** A 2-player pong (4 paddle inputs) fits with two to spare. Four players
needs a second relay; qualified `relay_1:left` names are the additive path, not a redesign.

**Corollary that saved a shared-infra change:** if a station's *wake* trigger was a computer-side
lever, moving the plates to a relay kills the wake too — and **silently**, since the polled side can
never change. Pong deleted its local wake entirely (it had gained an ender modem, so hub presence
wakes it), which is why `idle_runner` needed no modification. Check the wake path whenever inputs
move off the computer.

## Related

- [[station-hardware-discovery]] — discover by type, `.cfg` survives `update`, the `<station> test` pattern.
- [[redstone-pulse-needs-a-yield]] — the *output* side of redstone; a pulse needs a yield between edges.
- [[open-every-modem]] — the other "looks dead, is actually a wiring assumption" failure.
