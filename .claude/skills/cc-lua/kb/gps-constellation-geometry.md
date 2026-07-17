---
title: CC's GPS has exact distances — so spread your hosts VERTICALLY, and one chunk is enough
area: peripheral
verified: source-read (CC:Tweaked mc-1.21.x WirelessNetwork/gps.lua) + measured 2026-07-17 (test/spikes/gps_constellation.lua, 13 tests)
tags: [gps, gps.locate, gps host, trilaterate, constellation, ender modem, wireless modem, isWireless, rs.getSides, dilution of precision, coplanar, collinear, self-locate, station position]
---

**Claim.** Everything you know about siting real GPS satellites is **wrong here**. A CC GPS
constellation squeezed into a **single 16×16 chunk** locates a station **exactly** (error `0`) from
tens of thousands of blocks away — as long as the fourth host is **lifted off the plane** of the other
three. Horizontal spread buys **nothing**.

**Why — CC's distances carry no noise.** `WirelessNetwork.tryTransmit`:

```java
if (receiver.getLevel() == sender.getLevel()) {
    var distanceSq = receiver.getPosition().distanceToSqr(sender.getPosition());
    if (interdimensional || receiver.isInterdimensional() || distanceSq <= receiveRange * receiveRange) {
        receiver.receiveSameDimension(packet, Math.sqrt(distanceSq));
```

The distance is computed from exact block positions. Real GPS spreads satellites to stop *measurement
noise* being amplified by bad geometry (dilution of precision) — with exact distances there is nothing
to amplify. What is left is pure **degeneracy**: `trilaterate` (`rom/apis/gps.lua`) rejects
near-collinear hosts (`|â2b · â2c| > 0.999`), and any three hosts yield a **mirrored pair** about their
plane which `narrow()` can only break with a fourth fix **off** that plane.

**Measured** (`test/spikes/gps_constellation.lua`, replicating `trilaterate`/`narrow` verbatim), three
hosts at a chunk's corners plus a fourth lifted:

| 4th host lift | exact out to |
| --- | --- |
| +5 y | 20,000 blocks |
| +10 y | 50,000 blocks |
| +40 y | 100,000 blocks |
| **coplanar** | **fails at ANY distance** (mirror unresolved) |
| **collinear** | **fails** (degenerate) |

A chunk is 16×16 but ~384 tall, so the lift is free. **Build rule: 3 hosts at the chunk's corners + 1
lifted ~40 blocks.** All four inside the hub's already-force-loaded chunk.

**The traps:**

- **The modem must be on a computer SIDE.** Both `gps.locate` and `gps host` scan only
  `for _, sSide in ipairs(rs.getSides())` for a `peripheral.getType(sSide) == "modem"` that
  `isWireless()`. A modem on the **wired cable is invisible to GPS** — so if you ever move a station's
  ender modem onto the network to free a computer face, GPS silently stops working. Keep it on a side.
- **Ender modems are fine** — `isWireless()` is true and, per the source above, same-dimension packets
  still carry a distance even for interdimensional modems. Infinite range, no constellation-per-region
  needed. Cross-dimension gives `nil` distance, so a successful `gps.locate()` **proves** you share the
  constellation's dimension — a free dimension check.
- **CC ships the host program.** `gps host <x> <y> <z>` (`rom/programs/gps.lua`) — the constellation is
  a **build task, zero code**. `gps host` with no args self-locates, which needs a working
  constellation already, so give the first hosts explicit coordinates.
- **A host must run forever → it must be force-loaded.** This is why "make every station a GPS host,
  self-reinforcing as I add stations" is a trap: it force-loads your whole floor and defeats the idle
  model (`[[unloaded-chunk-is-the-cheapest-sleep]]`). A few dedicated hosts in the hub's chunk instead.
- **`gps.locate(2)` burns its full 2s timeout when no constellation exists**, via a bare `os.pullEvent`
  loop that **discards** every event it doesn't recognise. At boot that silently eats redstone/presence
  events — see `[[event-pump-reentrancy]]`. Try a config-supplied position *first* so a station with
  one never pays the 2s.

**So what.** A station can learn its own position with no hand-typed coordinates, which is the
difference between a floor of 5 and a floor of 500. The whole cost is four computers in one chunk —
just don't put them all at the same y.
