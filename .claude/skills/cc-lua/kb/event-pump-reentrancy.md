---
title: A nested os.pullEvent loop inside a play loop eats the outer loop's timer (freeze)
area: lua-runtime
verified: in-game 2026-07-16
tags: [os.pullEvent, event queue, timer, freeze, hang, rednet, request, reentrancy, play loop, os.queueEvent, blocking, rednet.lookup]
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
— exactly one timer stays alive, no double-fire. Also **cache** anything found via a blocking lookup
(`rednet.lookup` pumps events too) so the hot path doesn't pump at all.

**Cheaper alternatives** when you don't need the reply inline: don't do blocking I/O in the event
branch — set a flag and handle it on the next tick; or run the I/O in a separate `parallel` coroutine
that owns its own rednet and hands results back via `os.queueEvent`.

**So what.** Any future game that talks to the hub (or does *any* blocking call) from inside its
`play()` loop will hit this. The economy's `wallet.request` is the fixed reference. See
`[[monitor-ui]]` for the sibling "too long without yielding" watchdog quirk, and the economy KB
`kb/economy.md` for where this bit in practice.
