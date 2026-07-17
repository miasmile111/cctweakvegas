---
title: An unloaded station costs NOTHING — chunk loading is already a proximity sensor
area: lua-runtime
verified: source-read (CC:Tweaked mc-1.21.x, AbstractComputerBlockEntity) 2026-07-17; reasoning behind the per-station proximity design
tags: [chunk, unload, load, deep sleep, idle, presence, proximity, startup, startOn, serverTick, setRemoved, force load, simulation distance, rednet, remote station, os.pullEvent]
---

**Claim.** A CC computer in an **unloaded chunk is closed, not sleeping** — it costs literally zero,
which is *cheaper than* the most carefully written `os.pullEvent` deep sleep. And it wakes itself:
chunk load reboots it into `startup`. So for any station far enough out that its chunk isn't
permanently loaded, **the chunk system is already doing your idle model for you**, and it is doing it
better than you can.

**Evidence** (`AbstractComputerBlockEntity.java`):

```java
protected void serverTick() {
    if (getLevel().isClientSide) return;
    if (computerID < 0 && !startOn) return;
    var computer = createServerComputer();
    ...
    if (startOn || (fresh && on)) { computer.turnOn(); startOn = false; }
```
```java
protected void unload() { var c = getServerComputer(); if (c != null) c.close(); instanceID = null; }
@Override public void setRemoved() { super.setRemoved(); unload(); }
protected void loadServer(CompoundTag nbt, ...) { on = startOn = nbt.getBoolean(NBT_ON); }
```

`serverTick` only runs for loaded block entities. Chunk unload calls `setRemoved()` → `unload()` →
`computer.close()`. The on/off state persists in NBT, so chunk load re-reads `on = startOn = true`,
`serverTick` sees `startOn`, calls `turnOn()`, and the computer **boots fresh** — running `startup`
again (see `[[deploy-and-identity]]`, which covers the reboot-fresh half).

**So what — this inverts an argument that looks fatal.** Designing hub-driven presence for stations
1000+ blocks out, the obvious objection is: *"a remote station can't hear the hub's rednet message,
because it isn't running."* True, and **irrelevant**: a station only needs to hear the hub **when a
player is near it**, and a player near it **has already loaded its chunk** (their own simulation
distance does it). The station boots, and `idle_runner.deepSleep()` **pulls** presence with
`queryPresence()` on entry rather than waiting to be pushed to. The hub answers; the station wakes.

That argument — which nearly killed a hub-central design in favour of a much worse per-station-sensor
one — is void. Chunk loading is a **coarse** (~simulation-distance, ~160 blocks) proximity gate that
costs nothing; you only need to build the **fine** one (am I *at* this machine?).

**Consequences worth internalising:**

- **Don't add a poll to make a remote station "responsive".** It is off. There is nothing to poll
  *with*, and once a player is close enough to matter, it is already awake.
- **The hub is the exception, and must stay force-loaded** — it is the one machine that must run while
  nobody is near it. Everything else should be *allowed* to unload; that is a feature.
- **This is also why "make every station a GPS host" is a trap.** A `gps host` must serve requests
  forever, so it must be force-loaded — turning your cheapest stations into your most expensive ones,
  and defeating the whole idle model. Keep the constellation as a few dedicated computers in the hub's
  already-force-loaded chunk (see `[[gps-constellation-geometry]]`).
- **Anything at boot must survive the boot delay.** A station reboots on *every* chunk load, so
  boot-time work runs constantly in practice, not once. Blocking calls there (`gps.locate` burns a
  full 2s with no constellation; `rednet.lookup` the same with no hub) silently eat events — which is
  how a lever pull got lost on every slot boot. Sample state *before* the blocking calls and re-check
  after: **pull, don't trust push**. See `[[event-pump-reentrancy]]`.
