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

**"Would a longer A→B / A→C help?" — measured: NO. Not even slightly.** Holding the lift at +40 and
growing the horizontal baseline:

| A→B = A→C | exact out to |
| --- | --- |
| 5 blocks | 200,000 |
| 15 blocks | 200,000 |
| 100 blocks | 200,000 |
| 1,000 blocks | 200,000 |
| 10,000 blocks | 200,000 |

A **2,000× bigger triangle changes the reach by zero**, while lift alone moves it 50× (+5 → 10,000
vs +100 → 500,000, then saturating). **The mechanism:** A, B and C define a *plane*, and three exact
distances always narrow the answer to a **mirrored pair reflected across that plane**. Enlarging the
triangle does not move the plane, so the mirror is identical — only the 4th host's **distance off the
plane** separates the two candidates for `narrow()`. Baseline length is the lever in *real* GPS purely
because it averages down measurement noise; CC has no noise, so it is the one lever the exactness
takes away. Lift saturates near +100 and Minecraft's height limit caps it anyway; **+40 is already
~200× more reach than any real floor needs.**

## A GPS fix is ALWAYS whole numbers — decimals ARE the error message

**Verified in-world 2026-07-17, and it cost a debugging session.** `gps locate` printed
`Position is -230.17,69.03,318`. A computer sits at an integer block position — the modem reports
`Vec3.atLowerCornerOf(...)` — so **a correct fix cannot have decimals**. The fractional part is not
imprecision, it is arithmetic telling you the fixes don't agree.

**The distances are always truth; only the claimed positions can lie.** CC computes distance from
real block positions (`Math.sqrt(distanceSq)`), with no config, no noise, and no equivalent of AP's
`playerDetRandomError`. `gps host x y z` broadcasts whatever you *typed*. So when they disagree, the
typed coordinates are wrong — every time.

**The cause, and it will happen to you: you read the MODEM, not the computer.** The modem is its own
block stuck to the computer's face. Point at the computer *from that side* and F3's `Targeted Block`
gives you the **modem's** position, one block off. Sight the computer from a modem-free face.

**How to diagnose it from one screenshot.** `gps locate` runs `gps.locate(2, true)` — debug is already
on — and prints `<distance> metres from <claimed pos>` for every host. That is a solvable system:

1. **Square each distance.** Clean integers ⇒ the distances are trustworthy (this alone rules out any
   "is it jitter?" theory; two identical runs confirm it).
2. **Find two hosts that agree** and solve for the station's true position; it must come out integer.
3. **Check every claim against it** — `|P − claimed|²` vs measured. The liars pop out.
4. **Solve each liar's true coordinate** from its own measured distance.

Real case: hosts claimed `A(-231,80,315) B(-228,80,315) C(-231,80,317) D(-231,187,315)`, measured
d² = `130, 134, 122, 14170`. Station solved to `(-231,69,318)`; A and C checked out; **B was really at
x=-229 (hosted -228, +1 X) and D at y=188 (hosted 187, −1 Y)**. Corrected, all four matched exactly.

**Why it looked like a precision bug rather than a typo:** B's 1-block error sat on a **3-block
baseline** and threw x to -230.17; D's identical 1-block error sat on a **119-block** distance and
moved y by only 0.03. **The same mistake is loud on a short baseline and nearly invisible on a long
one** — so the *size* of the wrongness tells you nothing about the size of the mistake.

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
