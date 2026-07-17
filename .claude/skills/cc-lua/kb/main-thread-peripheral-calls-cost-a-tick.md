---
title: Every inventory call costs a game tick of FROZEN monitor — and redstone never touches monitors
area: peripherals
verified: source-read (CC:Tweaked mc-1.21.x) 2026-07-17 + reproduced under luajit (test/test_cage_hw.lua)
tags: [pushItems, pullItems, list, inventory, main thread, mainThread, MainThreadExecutor, task_complete, stutter, freeze, lag, monitor, redstone, throttle, max_main_computer_time, parallel, chest, dropper, barrel]
---

**Symptom.** The monitor **stutters or freezes** for a fraction of a second whenever a station moves
items — and it looks for all the world like the *redstone* is doing it, because the stall lands
exactly when the droppers fire. In the case that found this, the cage's kiosk hitched on every
withdrawal, worse at 20x than at 1x.

**It is not the redstone.** `MonitorBlock.java` contains **zero** references to redstone/signal/power
— monitors neither read nor respond to it. And terminal writes (`write`, `blit`,
`setBackgroundColor`, `setPaletteColour`) are **computer-thread** calls: they mutate the server-side
terminal and flip an `AtomicBoolean`, nothing more. **Monitor drawing is effectively free** — 1000
writes cost the same one packet per tick as one write (`ServerMonitor.markChanged` →
`blockTick` → one `MonitorWatcher.enqueue`). Draw as much as you like.

**The real cost: main-thread tasks.** Every `inventory` method — `list`, `size`, `pushItems`,
`pullItems`, `getItemDetail`, `getItemLimit` — carries `@LuaFunction(mainThread = true)`
(`AbstractInventoryMethods.java`). Such a call:

1. queues a task via `ILuaContext.issueMainThreadTask` — *"executed on the main server thread at the
   beginning of next tick"*;
2. **parks your coroutine** (`TaskCallback` returns `MethodResult.pullEvent("task_complete", ...)`).

`MainThreadExecutor.execute()` polls exactly **one** task per pass, and a sequential coroutine can
only ever have **one task in flight** — it cannot queue task N+1 until task N's `task_complete` wakes
it. So:

> **~1 inventory call per game tick ≈ 50ms, with your play loop drawing NOTHING.**

`redstone.setOutput` is *not* main-thread (`RedstoneAPI.java` has no `mainThread`) — it's cheap. See
`[[redstone-pulse-needs-a-yield]]` for why it still needs a yield.

**So: count your calls.** That is the whole game. The cage's `loadDroppers` re-listed the vault
*inside* its per-dropper loop — 4 droppers = 4 `list` + 4 `pushItems` = **8 calls ≈ 400ms of dead
monitor**, for a listing only *we* were mutating. The fix is boring and worth 2x: take **one**
listing, mirror each slot's remaining count locally, trust `pushItems`' return value, and let the
caller hand in the listing it already took for its stock check. Cost becomes one push per dropper
**per vault slot it draws from** — a tidy vault is one push per dropper; a fragmented one pays a tick
per extra slot boundary.

**The trap in that fix, and it bit on the first try:** once you stop re-listing, `pushItems` returning
**0 is ambiguous** — the target is full, *or* your mirror is stale and the slot is really empty. Guess
"slot is dead" and you skip stock the next target needs; guess "target is full" and you spin. The
cage's caller takes its listing *before* a blocking rednet round-trip, so stale is real: a hopper or
player draining a slot in that window left a dead slot the sweep kept hitting, and a 20x tap against a
vault holding 66 iron delivered **2**. Money stayed honest (the shortfall is refunded) but the order
stranded. Fix: don't guess — sweep once on the caller's listing, and **only if short**, take ONE fresh
`list()` and retry the remainder. Costs a tick only when something was already wrong. The per-dropper
re-list was accidentally immune to this, so the optimisation must buy the resilience back explicitly.

**Budgets and throttling.** `max_main_computer_time` = **5ms** per computer per tick,
`max_main_global_time` = **10ms** globally (`MainThreadConfig.java`). Overrun does **not** error — the
executor goes `COOL` → `HOT` → `COOLING`, and while `COOLING` **no tasks run at all** until its budget
*fully* replenishes. It manifests as your peripheral calls silently taking several ticks each. Timers
and events keep firing normally, which is exactly why this reads as "the monitor is lagging" rather
than "my code is blocked".

**When you truly need N transfers fast:** give each its own coroutine so N tasks sit in the queue
*simultaneously* and `MainThread.tick()`'s drain loop takes them in as few as one tick. `parallel`
does this, but it **discards the events it doesn't consume** — inside a play loop that eats your tick
timer and your `monitor_touch`es (`[[event-pump-reentrancy]]`), so stash and re-queue foreign events.
Two hard ceilings: the event queue caps at **256**, and `parallel.waitForAll` is **O(n²)** in
coroutines (every one wakes on every `task_complete` and filters by id) — batch in chunks, don't fan
out unboundedly.

**So what.** Any station that moves items — cage, vending, a Create contraption loader — pays ~50ms of
frozen UI per inventory call. Budget the *call count* the way you'd budget bytes, and never diagnose a
stuttering monitor by looking at the redstone. `test/test_cage_hw.lua` asserts the call count against
a fake network, because "correct but 8 calls" is a bug you cannot see in-world without measuring —
`cage debug` prints the per-tap timings and any tick gap over 100ms.
