# The floppy-swap freeze: wallet's hub lookup is an unstashed event pump

**Date:** 2026-07-17
**Status:** design approved, ready to plan
**Bug:** todo.md "Economy bug — floppy-swap freeze (open)" · `kb/economy.md` "Open follow-up"
**KB:** `[[event-pump-reentrancy]]` · `[[unloaded-chunk-is-the-cheapest-sleep]]`

## Summary

The station freeze on a card swap is **`rednet.lookup` eating the play loop's tick timer**. Two
defects in `src/lib/wallet.lua`, plus one lie on screen that the fix makes visible. This spec
closes all three.

The owner force-loaded the hub and made it reboot reliably, and the freeze stopped. That is a real
mitigation — but it removes the *trigger*, not the *bug*. Every symptom is explained, which is what
makes this worth fixing before the floor opens.

## Evidence (not inference)

From CC:Tweaked `rom/apis/rednet.lua`, `lookup()` (fetched from the mod source, blob
`8107a46`, branch `master` @ `6f16cd6`):

```lua
    local timer = os.startTimer(timeout or 2)
    while true do
        local event, p1, p2, p3 = os.pullEvent()      -- NO filter: pulls EVERYTHING
        if event == "rednet_message" then
            ...
        elseif event == "timer" and p1 == timer then
            break
        end
        -- every other event: silently DISCARDED. Never stashed, never re-queued.
    end
```

Bare `os.pullEvent()`, default timeout **2 seconds**, and no stash. CC has **one event queue per
computer**, so an event this loop pulls is *gone* from the caller's loop.

## The failure chain

1. Hub chunk unloads (or hub reboots / server restarts) → the hub computer is **CLOSED**, not slow
   (`[[unloaded-chunk-is-the-cheapest-sleep]]`). Nothing answers DNS.
2. Player swaps a card → `disk` / `disk_eject` event → `slot.lua:315` → `sp_econ.onEvent` →
   `refreshCard` (`sp_econ.lua:31`) → `wallet.query` → `request` → `getHub`.
3. `getHub` (`wallet.lua:82`) calls `rednet.lookup` → **2 seconds of pulling and discarding every
   event**, including the slot's pending tick timer.
4. `slot.lua` reschedules its timer **only inside the timer branch** (`slot.lua:312`). The swap
   arrived on the `disk` branch. The timer it was waiting on is gone, and nothing re-arms it.
5. Next `os.pullEvent` blocks forever. Monitor frozen, program "running", no crash. Reboot to clear.

Every reported symptom follows: no crash, reboot-to-clear, and **intermittent** — it depended
entirely on whether the hub's chunk happened to be loaded.

## The two defects

**D1 — `getHub` pumps unstashed from inside the play loop** (`wallet.lua:82`).
`request` (`wallet.lua:91-111`) already stashes and re-queues foreign events correctly. `getHub`,
called on line 92 *before* that loop is entered, does not. The comment on lines 77-79 shows the
author knew `lookup` pumps and reached for a cache — but a cache only helps when the hub **answers**.
When it does not, `hubId` stays `nil` and the pump runs on every single call.

**D2 — the negative result is never cached, and any timeout clears the positive one.**
`wallet.lua:108` (`if result == nil then hubId = nil end`) drops a good hub id after one timeout.
So a single server hitch mid-round re-arms D1 **even against a healthy, force-loaded hub**. The
owner's chunkload fix does not cover this path.

## The lie on screen (found while reading, not reported)

`wallet.bet` returns `false, nil, "timeout"` when the hub is unreachable. `sp_econ.lua:51`
(`local ok, bal = wallet.bet(...)`) **drops the third return**, sets `denied = true`, and
`slot.lua:209` renders that as **`INSUFFICIENT`**.

So a hub-unreachable slot tells a player with $500 that they are broke, and refuses every pull. This
is live today, chunkload or not. It fails the OPEN phase's test — *would a player who has never seen
this notice, and would it embarrass us?* — twice over: the machine lies, and it lies about money.

Fixing the freeze makes this **more** visible, not less: the station now survives hub-down and keeps
rendering, so it will sit there confidently showing `INSUFFICIENT` until the hub returns.

## Design

### Part 1 — `pumpSafe`: give back the events you didn't consume

A local helper in `wallet.lua` that drives a blocking rom function in a coroutine we pump ourselves,
stashing every event and re-queuing it on return. This is the CraftOS scheduler's own contract
(`os.pullEvent` is `coroutine.yield(filter)`), so we can stand in for it.

```lua
-- Drive a blocking rom function that pumps events, WITHOUT losing the caller's events.
-- rednet.lookup pulls with a bare os.pullEvent() and silently discards everything it does not
-- recognise (verified in rom/apis/rednet.lua) -- including the play loop's tick timer. That is the
-- floppy-swap freeze. We resume the coroutine ourselves and hand every event back afterwards.
local function pumpSafe(fn, ...)
  local co = coroutine.create(fn)
  local stash = {}
  local res = { coroutine.resume(co, ...) }
  while coroutine.status(co) ~= "dead" do
    if not res[1] then error(res[2], 0) end
    local ev = { os.pullEvent() }
    -- the coroutine's OWN dns traffic is its business; everything else belongs to the caller
    if not (ev[1] == "rednet_message" and ev[4] == "dns") then stash[#stash + 1] = ev end
    res = { coroutine.resume(co, unpack(ev)) }
  end
  if not res[1] then error(res[2], 0) end
  for _, e in ipairs(stash) do os.queueEvent(unpack(e)) end
  return unpack(res, 2)          -- wallet.lua's Lua 5.1-safe local, NOT table.unpack
end
```

Two properties this leans on, both verified rather than assumed:

- **Re-queuing a stray timer is harmless.** `lookup`'s own timeout timer gets stashed and handed
  back, so the caller sees a `timer` event with an id it does not recognise. Every one of the 9
  event loops in `src/` compares the id (`ev[1] == "timer" and ev[2] == timer`) — checked across
  `slot`, `cage`, `pong`, `hub`, `idle_runner`, `update`, `wallet`. All ignore it.
- **Nothing else in the repo speaks the `dns` protocol**, so filtering it out of the stash by
  `ev[4] == "dns"` cannot drop an event a caller wanted.

**`pumpSafe` stays local to `wallet.lua`.** It is not a new `lib/` module: only one caller needs it,
a new lib file means touching every package's file list in `packages.lua` (and the CDN-lag deploy
trap that comes with it), and `idle_runner`'s lookup is deliberately exempt (below). Extract it on
the rule of three.

### Part 2 — `getHub`: back off when the hub is down

```lua
local LOOKUP_BACKOFF = 5     -- seconds to trust a failed lookup before pumping again
local hubId, lastFail

local function getHub()
  if hubId then return hubId end
  if lastFail and (os.clock() - lastFail) < LOOKUP_BACKOFF then return nil end   -- do not pump
  hubId = pumpSafe(rednet.lookup, PROTO, "hub", TIMEOUT)
  if not hubId then lastFail = os.clock() end
  return hubId
end
```

- **Reuses the existing `TIMEOUT` (1.5s)** rather than `lookup`'s 2s default and rather than adding a
  knob. One number, already proven in-world by `request`.
- **`LOOKUP_BACKOFF = 5`** turns hub-down from *a 2s stall on every call* into *at most one 1.5s
  stall per 5s* — and with Part 1 that stall is a survivable hitch, not a freeze.
- `wallet.lua:108`'s `hubId = nil` on timeout **stays** (the hub genuinely may return with a new id);
  it is now safe, because the re-lookup is stash-safe and backoff-limited.

### Part 3 — say `HUB OFFLINE`, don't say `INSUFFICIENT`

Thread the reason that already exists through to the screen. No new protocol, no new round-trips.

- **`wallet.query`** gains a second return: `balance, reason`. Today it returns `nil` both when the
  hub is down and when the id is unknown, which are not the same thing. Additive — all three existing
  callers (`issue.lua:98`, `cage_econ.lua:36`, `sp_econ.lua:31`) take a single return and are
  unaffected.
- **`sp_econ`** gains `self.offline` (boolean) in state and in `status()`:
  - `tryBet` captures `wallet.bet`'s third return; `reason == "timeout"` sets `offline = true`.
  - `refreshCard` sets `offline = true` when `wallet.query` reports `"timeout"` with a card present —
    so the slot says `HUB OFFLINE` the moment the card goes in, not only after a wasted pull.
  - `tryBet` still returns `"deny"` for both cases. **Fail-closed on money is correct and does not
    change**; only what the player is *told* changes.
- **`slot.lua:209`** header, offline checked first (a timeout sets `denied` too):
  ```lua
  if     status.offline then hdr = "HUB OFFLINE"
  elseif status.denied  then hdr = "INSUFFICIENT"
  ...
  ```
  `"HUB OFFLINE"` is 11 chars in a 15-cell header — fits the existing centred write, no layout change.

## Non-goals

- **`idle_runner.lua:55`'s `rednet.lookup` is NOT in scope and must not be "fixed".** Lines 51-53
  document why: it runs once at boot, before `deepSleep`, so there is no caller loop whose timer it
  could swallow, and the lever is pre-sampled ahead of it (`idle_runner.lua:80-84`). It is a known,
  reasoned, mitigated case. Touching it risks the lever-wake regression that cost the proximity build
  a cycle.
- **`update.lua:221`** — one-shot admin program, no play loop. Out of scope.
- **The cage's offline UX.** `cage.lua` has its own UI and its own fail-closed withdraw path; it
  benefits from Parts 1-2 automatically (shared `wallet`), but its screen wording is a UI job for the
  advert/UI session, not this bugfix.
- **The ambiguous-timeout double-credit** (`kb/economy.md` "Open follow-up" item 1) — a real latent
  bug, but it needs a request id the hub de-duplicates on, which is a protocol change that belongs
  with `hub_version`. Untouched here.
- **`hub_version` / ping.** Same reason. Filed, not fixed.

## Testing

Offline, `luajit`, in the existing `test/test_wallet.lua` harness (which requires `wallet.lua`
directly and can monkeypatch `os.*` globals). `pumpSafe` is exported as `M._pumpSafe` to match the
repo's `_`-prefixed testable-helper convention.

The central test **reproduces the freeze directly**: drive a fake blocking function that discards
every event (exactly what `lookup` does), feed it a `timer` event, and assert the timer comes back
out via `os.queueEvent`. That test fails against today's code and passes after the fix.

1. `_pumpSafe` re-queues a foreign event the inner function discarded (**the freeze, reproduced**).
2. `_pumpSafe` re-queues foreign events **in arrival order**.
3. `_pumpSafe` returns the inner function's return value.
4. `_pumpSafe` does **not** re-queue `rednet_message` on the `dns` protocol.
5. `_pumpSafe` propagates an error raised inside the coroutine.
6. `getHub` backoff: a failed lookup suppresses a second lookup inside the window (assert the fake
   `rednet.lookup` is called **once**, not twice).
7. `getHub` backoff expires: a lookup is attempted again past the window.
8. `getHub` caches a successful id — a second call performs **no** lookup.
9. `wallet.query` returns `"timeout"` as its reason when the hub does not reply.
10. `wallet.query`'s balance return is unchanged for existing single-return callers.

`sp_econ.offline` is covered by driving `tryBet`/`refreshCard` against a stub wallet: a `"timeout"`
reason sets `offline`, an insufficient-funds deny does **not**, and a recovered hub clears it.

Plus: `luajit -bl` syntax pass on every touched file, and the full suite green.

## In-world verification (after merge + push)

The bug's own repro, now that we know the trigger:

1. `update slot`, reboot. Insert a card, confirm the header shows `<id>: $<bal>`.
2. **Break the hub on purpose** — stop `hub.lua` (or unload its chunk). This is the state the
   chunkload fix normally prevents.
3. Swap the floppy at the slot, repeatedly. **Pre-fix: freeze.** Post-fix: the reels keep animating
   and the header reads `HUB OFFLINE`.
4. Pull the lever while offline → the pull is denied and the header says `HUB OFFLINE`, **not**
   `INSUFFICIENT`.
5. Bring the hub back. Within ~5s (the backoff) the header returns to `<id>: $<bal>` with no reboot.
6. Confirm a win banked while offline still lands (the outbox path is untouched — this is a
   regression check, not a new promise).
