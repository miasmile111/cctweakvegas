---
title: A nested os.pullEvent loop inside a play loop eats the outer loop's timer (freeze)
area: lua-runtime
verified: in-game 2026-07-16; root cause of the floppy-swap freeze confirmed from the CC rom source 2026-07-17
tags: [os.pullEvent, event queue, timer, freeze, hang, rednet, request, reentrancy, play loop, os.queueEvent, blocking, rednet.lookup, coroutine, pumpSafe, backoff, cache, terminate, ctrl+t, parallel]
---

**Symptom.** A monitor game running its own `os.startTimer`/`os.pullEvent` tick loop **freezes**
(monitor stops updating) after some event — in the case that found this, inserting/swapping a
membership card mid-session. The computer's own GUI shows the program *still running* (not crashed,
no error, no supervisor restart). Only a reboot clears it. Intermittent — depends on timing.

**Cause.** The loop reschedules its tick timer **only inside its timer branch**:

```lua
local timer = os.startTimer(TICK)
while true do
  local ev = { os.pullEvent() }
  if ev[1] == "timer" and ev[2] == timer then
    ...work...
    timer = os.startTimer(TICK)        -- reschedule ONLY here
  elseif ev[1] == "disk" then
    someHelper()                        -- <-- runs its OWN os.pullEvent loop
  end
end
```

A helper called from a **non-timer** branch (here `wallet.request`, which does a rednet round-trip
via its own `os.pullEvent` loop) pulls events while it waits — including the game's pending
`timer` event — and **discards** the ones it doesn't recognise. CC has **one event queue per
computer**; an event pulled by the inner loop is *gone* from the outer loop. So the tick timer fires,
the inner loop eats it, the outer `disk` branch doesn't reschedule, and the next `os.pullEvent`
blocks forever (no timer pending). Frozen. `rednet.receive`, `rednet.lookup`, `sleep`,
`parallel.*`, `read`, and any `os.pullEvent` loop are all such **blocking pumps** — they consume
from the same queue.

**Fix.** Any helper that runs its own event loop while callable from inside another loop must
**give back the events it didn't consume** — stash them and re-queue with `os.queueEvent` before
returning:

```lua
local unpack = table.unpack or unpack   -- Lua 5.1 (CraftOS)
local stash, result = {}, nil
local t = os.startTimer(TIMEOUT)
while true do
  local ev = { os.pullEvent() }
  if isMyReply(ev)             then result = ev; break
  elseif ev[1]=="timer" and ev[2]==t then result = nil; break   -- my own timeout
  else stash[#stash+1] = ev end                                  -- foreign: hand it back
end
for _, e in ipairs(stash) do os.queueEvent(unpack(e)) end         -- outer loop still sees its timer
return result
```

A re-queued `{"timer", id}` re-fires for the outer loop, which matches `ev[2]==timer` and reschedules
— exactly one timer stays alive, no double-fire.

**Re-queue BEFORE you re-raise.** If the helper can error after it has already stashed events, an
early `error()` drops them and causes the very freeze the stash exists to prevent. Hand the events
back first, then re-raise. (`wallet._pumpSafe` shipped with this bug; a test whose `fn` errors on the
first resume has an empty stash and cannot catch it.)

### A cache is NOT enough — it only helps on the success path (2026-07-17)

This entry used to end at "**cache** anything found via a blocking lookup (`rednet.lookup` pumps
events too) so the hot path doesn't pump at all." That advice was followed *exactly* — `wallet.getHub`
cached the hub id — **and the floppy-swap freeze happened anyway, for a year.** The gap:

> **A cache only helps when the lookup SUCCEEDS.** When the hub was unreachable, `hubId` stayed `nil`,
> so the cache never populated and **every single call re-ran the 2s pump**. The cache is load-bearing
> precisely in the case that never fails, and absent precisely in the case that freezes.

The full fix is three parts, and dropping any one leaves the bug:

1. **Stash the lookup itself** (`rednet.lookup` is a pump; wrap it — see `_pumpSafe` below).
2. **Cache the hit** — keeps the hot path from pumping at all.
3. **Back off the miss** — after a failed lookup, don't retry for N seconds (`wallet.lua`:
   `LOOKUP_BACKOFF = 5`). This is the part the old advice missed.

**`rednet.lookup` cannot be stashed by wrapping its loop — you don't own it.** Drive it as a
coroutine instead and hand back what it drops. This is exactly what CC's own `rom/apis/parallel.lua`
does, and it works because **`os.pullEvent` inside a coroutine IS `coroutine.yield(filter)`**, which
yields to whoever resumed it — you:

```lua
local function pumpSafe(fn, ...)         -- for fns that pull with NO filter (rednet.lookup does)
  local co, stash = coroutine.create(fn), {}
  local res = { coroutine.resume(co, ...) }
  while coroutine.status(co) ~= "dead" do
    local ev = { os.pullEvent() }
    if not (ev[1] == "rednet_message" and ev[4] == "dns") then stash[#stash+1] = ev end  -- dns = its own
    res = { coroutine.resume(co, unpack(ev)) }
  end
  for _, e in ipairs(stash) do os.queueEvent(unpack(e)) end   -- BEFORE the re-raise, always
  if not res[1] then error(res[2], 0) end
  return unpack(res, 2)
end
```

**Never mutate `os.pullEvent` to make this work** — it is a no-op in real CraftOS (it already yields),
and swapping in bare `coroutine.yield` **silently breaks Ctrl+T**, because the real `os.pullEvent`
turns a `terminate` event into `error("Terminated", 0)`. If a test seems to demand the mutation, the
**test's fake is wrong**: a fake `os.pullEvent` must *yield* when called inside a coroutine
(`coroutine.running()` is nil on the main thread in Lua 5.1 — that's the discriminator), not return
flatly.

**Verified from the rom source** (`rom/apis/rednet.lua`, blob `8107a46`): `lookup` runs
`local event, p1, p2, p3 = os.pullEvent()` — **no filter** — and silently discards everything that is
not a dns reply or its own timer. Default timeout **2s**; it takes an optional 3rd `timeout` arg
(added in CC:Tweaked 1.118.0; on older builds the arg is silently ignored and you get 2s).

Re-queuing a `modem_message` is safe: `rednet.run` gates on `not received_messages[nMessageID]` and
records the id on first processing (9.5s window), so it cannot emit a duplicate `rednet_message`.

**Cheaper alternatives** when you don't need the reply inline: don't do blocking I/O in the event
branch — set a flag and handle it on the next tick; or run the I/O in a separate `parallel` coroutine
that owns its own rednet and hands results back via `os.queueEvent`.

**So what.** Any future game that talks to the hub (or does *any* blocking call) from inside its
`play()` loop will hit this. The economy's `wallet.request` is the fixed reference. See
`[[monitor-ui]]` for the sibling "too long without yielding" watchdog quirk, and the economy KB
`kb/economy.md` for where this bit in practice.
