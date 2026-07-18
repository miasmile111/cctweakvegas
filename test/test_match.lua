-- test_match.lua — the match runner: phase loop, pump ownership, and the money-replay capture.
--
-- Everything here runs against injected fakes: a fake mp_econ, a fake window, and a fake os whose
-- pullEvent replays a scripted event list. No monitor, no hub, no CC.
package.path = "src/lib/?.lua;test/?.lua;" .. package.path
local t = require("runner")

colors = { black = 1, white = 2, gray = 3, lightGray = 4,
           green = 5, yellow = 6, pink = 7, red = 8 }
keys = { q = 16 }

local match = require("match")

-- ---- fakes -----------------------------------------------------------------
-- `_writes` is the CURRENT frame (reset on clear, mirroring a real window); `_log` is EVERY string
-- ever written, never reset. find() searches ONLY `_writes` -- the current frame -- so it can prove
-- ORDERING (e.g. that a balance was captured before a later frame changed it). findEver() searches
-- `_log` and exists ONLY for the win flash: the flash is drawn, pumped for flashTicks frames, then
-- unconditionally overwritten by the results screen's own clear() in the SAME synchronous call (no
-- event boundary in between) -- that overwrite is the whole point of a transient flash. A find()
-- scoped to the current frame could therefore never observe the flash text once the match finished.
-- Widening find() itself to search `_log` was tried and rejected: it made the capture-ordering test
-- below match stale LOBBY frames (both seats already show balance 100 before any match starts),
-- silently defeating the one assertion that guards the pre-ante capture rule.
local function fakeWin()
  local w = { _writes = {}, _log = {} }
  function w.getSize() return 57, 24 end
  function w.setVisible() end
  function w.setBackgroundColor() end
  function w.setTextColor() end
  function w.clear() w._writes = {} end
  function w.setCursorPos(x, y) w._x, w._y = x, y end
  function w.write(s)
    local e = { x = w._x, y = w._y, text = s }
    w._writes[#w._writes + 1] = e
    w._log[#w._log + 1] = e
  end
  function w.find(p)
    for _, e in ipairs(w._writes) do
      if tostring(e.text):find(p, 1, true) then return e end
    end
  end
  function w.findEver(p)
    for _, e in ipairs(w._log) do
      if tostring(e.text):find(p, 1, true) then return e end
    end
  end
  return w
end

-- Scripted event source. Once the script runs dry it emits filler timer ticks so a phase that
-- legitimately waits does not need every tick spelled out.
--
-- Three properties make a LOST TIMER RE-ARM detectable, which the first version of this fake could
-- not do (it returned a constant id and replayed it forever, conflating "issued" with
-- "outstanding"):
--   (a) outstanding timers are a SET, not a last-value
--   (b) a timer is SINGLE-SHOT -- emitting it retires it, as CraftOS does
--   (c) _swallow() models a nested event pump eating pending events, which is exactly what a
--       handler that reaches the hub can do ([[event-pump-reentrancy]])
-- With all three, pulling an event when nothing is outstanding is a DEADLOCK -- the real in-world
-- symptom: a station frozen on os.pullEvent with no timer coming, no crash, no error.
local function fakeOs(events)
  local i, filler, nextId = 0, 0, 0
  local outstanding = {}
  local o = {}
  function o.startTimer() nextId = nextId + 1; outstanding[nextId] = true; return nextId end
  function o.pullEvent()
    i = i + 1
    if events[i] then return unpack(events[i]) end
    local live
    for id in pairs(outstanding) do if not live or id < live then live = id end end
    if not live then
      error("DEADLOCK: pullEvent with NO timer outstanding -- a re-arm was lost", 0)
    end
    outstanding[live] = nil
    filler = filler + 1
    if filler > 2000 then error("EVENTS EXHAUSTED -- the match loop never returned", 0) end
    return "timer", live
  end
  o.epoch = function() return 0 end
  o._swallow = function() outstanding = {} end
  return o
end

-- a fake mp_econ instance recording what the runner asked of it
local function fakeEcon(script)
  script = script or {}
  local e = {
    phase = "lobby", pot = 0,
    seats = { {}, {} },
    _calls = {},
    _status = script.status or { phase = "lobby", pot = 0, seats = {
      { player = "alice", balance = 100 },
      { player = "bob",   balance = 100 },
    } },
  }
  -- refreshCard/start both reach the hub in the real code, which runs a NESTED event pump that can
  -- swallow this loop's pending timer ([[event-pump-reentrancy]]). e._os is wired by runner() below;
  -- swallowing here models that hazard so Fix 2/3's re-arm ordering is actually exercised.
  function e.onEvent(ev)
    e._calls[#e._calls + 1] = { op = "onEvent", ev = ev }
    if e._os then e._os._swallow() end
  end
  function e.status() return e._status end
  function e.cardedCount() return 2 end
  function e.start()
    e._calls[#e._calls + 1] = { op = "start" }
    if e._os then e._os._swallow() end
    local r = script.start or { "staked" }
    if r[1] == "staked" then e.phase, e.pot = "playing", 20 else e.phase = "playing" end
    if r[1] == "deny" then e.phase = "lobby" end
    return r[1], r[2], r[3]
  end
  function e.finish(scores)
    e._calls[#e._calls + 1] = { op = "finish", scores = scores }
    e.phase, e.pot = "done", 0
    return script.finish or { potWinner = 1, potShare = { [1] = 20 }, pot = 20, matchWinner = 1 }
  end
  function e.reset()
    e._calls[#e._calls + 1] = { op = "reset" }
    e.phase, e.pot = "lobby", 0
  end
  function e.opsOf(name)
    local n = 0
    for _, c in ipairs(e._calls) do if c.op == name then n = n + 1 end end
    return n
  end
  return e
end

local function fakePres(goneAfter)
  local n = 0
  return {
    gone = function() n = n + 1; return goneAfter ~= nil and n >= goneAfter end,
    fromEvent = function() end,
  }
end

-- flashTicks defaults to 0 here so the win flash does not silently EAT the scripted touches that
-- follow a GO (the flash pumps, and a pump consumes events until a timer arrives). The flash gets
-- its own dedicated test below, with flashTicks = 1 and an explicit timer.
local function runner(cfg, events, econ, presGone)
  local win = fakeWin()
  local osInst = fakeOs(events)
  econ._os = osInst   -- lets fakeEcon model the nested-pump swallow hazard ([[event-pump-reentrancy]])
  local play = match.run{
    title = "PONG", seatLabels = { "LEFT", "RIGHT" },
    minSeats = 2, maxSeats = 2, ante = 10, target = 5,
    controls = {}, drives = { "drive_0", "drive_1" },
    flashTicks = cfg.flashTicks or 0, resultTicks = cfg.resultTicks or 9999,
    play = cfg.play,
    deps = {
      mp_econ = { new = function() return econ end },
      window  = { create = function() return win end },
      os      = osInst,
    },
  }
  local result = play({ setTextScale = function() end, getSize = function() return 57, 24 end },
                      fakePres(presGone))
  return result, win, econ
end

-- ---- Q quits, and the runner returns the idle_runner contract ----
do
  local econ = fakeEcon()
  local res = runner({ play = function() return {} end }, { { "key", 16 } }, econ)
  t.eq(res, "quit", "a Q key returns 'quit' to idle_runner")
end

-- ---- the zone emptying puts the station to sleep ----
do
  local econ = fakeEcon()
  local res = runner({ play = function() return {} end },
                     {}, econ, 1)
  t.eq(res, "sleep", "an empty zone returns 'sleep'")
end

-- ---- GO is INERT until every seat is ready: a touch must not start a match ----
do
  local econ = fakeEcon()
  local lobby = require("lobby")
  local events = {
    { "monitor_touch", "monitor_0", 21, 18 },   -- GO while nobody is ready
    { "key", 16 },
  }
  runner({ play = function() return {} end }, events, econ)
  t.eq(econ.opsOf("start"), 0,
       "GO with no seats ready NEVER antes -- the gate is enforced in the runner, not just drawn")
end

-- ---- both ready -> GO -> the game runs -> results ----
do
  local econ = fakeEcon()
  local lobby = require("lobby")
  local played = false
  local events = {
    { "monitor_touch", "m", 13, 12 },   -- seat 1 READY
    { "monitor_touch", "m", 31, 12 },   -- seat 2 READY
    { "monitor_touch", "m", 21, 18 },   -- GO
    { "key", 16 },
  }
  local _, win = runner({
    play = function(ctx)
      played = true
      t.ok(ctx.win ~= nil, "play gets a window")
      t.eq(ctx.target, 5, "play gets the target score")
      t.eq(#ctx.seats, 2, "play gets the seats")
      return { [1] = 5, [2] = 3 }
    end,
  }, events, econ)

  t.eq(played, true, "GO with all seats ready runs the game")
  t.eq(econ.opsOf("start"), 1, "and antes exactly once")
  t.eq(econ.opsOf("finish"), 1, "and resolves exactly once")

  -- Assert WHAT reached finish, not merely that it was called. resolve(nil) also calls finish --
  -- with {} -- and mp_econ reads an all-zero score table as a TIE, splitting the pot evenly. So a
  -- deleted resolve(scores) would silently turn "winner takes $20" into "both players refunded"
  -- with this suite still green.
  local fin
  for _, c in ipairs(econ._calls) do if c.op == "finish" then fin = c end end
  t.ok(fin ~= nil, "finish was called")
  t.eq(fin.scores[1], 5, "the REAL scores reach finish -- {} would tie-split the pot, not pay the winner")
  t.eq(fin.scores[2], 3, "for both seats")
end

-- ---- THE CAPTURE: balances are read BEFORE start(), not after ----
do
  local econ = fakeEcon()
  local lobby = require("lobby")
  -- status() changes after start(): if the runner captured late it would read the POST-ante number
  -- and the results screen would animate from the wrong place (a drain that never appears).
  local origStart = econ.start
  econ.start = function()
    local r = { origStart() }
    econ._status = { phase = "playing", pot = 20, seats = {
      { player = "alice", balance = 90 }, { player = "bob", balance = 90 } } }
    return unpack(r)
  end
  local events = {
    { "monitor_touch", "m", 13, 12 },   -- seat 1 READY
    { "monitor_touch", "m", 31, 12 },   -- seat 2 READY
    { "monitor_touch", "m", 21, 18 },   -- GO
    { "key", 16 },
  }
  local _, win = runner({ play = function() return { [1] = 5, [2] = 3 } end }, events, econ)
  t.ok(win.find("100"),
       "the results screen animates from the PRE-ante balance -- capture happens before start()")
end

-- ---- a deny is reported and nothing is played ----
do
  local econ = fakeEcon{ start = { "deny", "timeout", 1 } }
  local lobby = require("lobby")
  local played = false
  local events = {
    { "monitor_touch", "m", 13, 12 },   -- seat 1 READY
    { "monitor_touch", "m", 31, 12 },   -- seat 2 READY
    { "monitor_touch", "m", 21, 18 },   -- GO
    { "key", 16 },
  }
  local _, win = runner({ play = function() played = true; return {} end }, events, econ)
  t.eq(played, false, "a denied GO does not run the game")
  t.ok(win.find("HUB OFFLINE"), "and the lobby says HUB OFFLINE, not INSUFFICIENT")
end

-- ---- the touch branch's OWN re-arm, isolated ----
-- A deny reaches the hub (swallowing the outstanding timer via econ.start()) but never enters
-- cfg.play, so nothing else in the framework re-arms afterward -- unlike a staked/free GO, which
-- also gets a re-arm right after econ.start() (needed for ctx.tick()). This is the one case that
-- depends SOLELY on the touch branch's own post-handler re-arm. The script runs dry right after the
-- GO tap, forcing a filler tick exactly where a lost re-arm deadlocks.
do
  local econ = fakeEcon{ start = { "deny", "timeout", 1 } }
  local events = {
    { "monitor_touch", "m", 13, 12 },   -- seat 1 READY
    { "monitor_touch", "m", 31, 12 },   -- seat 2 READY
    { "monitor_touch", "m", 21, 18 },   -- GO -> deny
  }
  local res = runner({ play = function() return {} end }, events, econ, 1)
  t.eq(res, "sleep",
       "presence goes away right after a denied GO -- reached only if the touch branch's own "
    .. "re-arm survived it")
end

-- ---- disk events reach mp_econ ----
do
  local econ = fakeEcon()
  -- Only the disk event is scripted -- the script runs dry immediately after it, so the very next
  -- pullEvent MUST come from a re-armed timer. This is what makes the disk-branch re-arm falsifiable:
  -- the old fakeOs (constant id, replayed forever) could never expose a lost re-arm here, because a
  -- trailing scripted "key" event would always be there to consume regardless.
  local res = runner({ play = function() return {} end }, { { "disk", "drive_0" } }, econ, 1)
  t.eq(res, "sleep",
       "presence goes away right after the disk event -- reached only if the re-arm survived it")
  t.ok(econ.opsOf("onEvent") >= 1, "disk events are folded into mp_econ so seats refresh")
end

-- ---- READY IS CLEARED on the way back to the lobby ----
do
  local econ = fakeEcon()
  local lobby = require("lobby")
  local plays = 0
  local events = {
    { "monitor_touch", "m", 13, 12 },   -- seat 1 READY
    { "monitor_touch", "m", 31, 12 },   -- seat 2 READY
    { "monitor_touch", "m", 21, 18 },   -- GO: match 1
    { "monitor_touch", "m", 21, 18 },   -- GO on results: skip to the lobby
    { "monitor_touch", "m", 21, 18 },   -- GO again: READY was cleared, so this must be INERT
    { "key", 16 },
  }
  runner({ play = function() plays = plays + 1; return { [1] = 5, [2] = 3 } end }, events, econ)
  t.eq(plays, 1,
       "after a match, READY is cleared -- a stale ready flag would ante a player who walked away")
  t.eq(econ.opsOf("reset"), 1, "and the engine is reset so a second match is possible at all")
end

-- ---- THE WIN FLASH: named by card id, drawn over the finished board ----
do
  local econ = fakeEcon()
  local lobby = require("lobby")
  local events = {
    { "monitor_touch", "m", 13, 12 },          -- seat 1 READY
    { "monitor_touch", "m", 31, 12 },          -- seat 2 READY
    { "monitor_touch", "m", 21, 18 },          -- GO
    { "key", 16 },
  }
  local _, win = runner({ flashTicks = 1, play = function() return { [1] = 5, [2] = 3 } end },
                        events, econ)
  t.ok(win.findEver("alice WON!"),
       "the flash names the WINNER BY CARD ID -- a player sees their own name at the moment of the win")
end

do
  -- An anonymous winner has no id, so the flash falls back to the seat label.
  local econ = fakeEcon()
  econ._status = { phase = "lobby", pot = 0, seats = {
    { player = nil, balance = nil }, { player = "bob", balance = 100 } } }
  local events = {
    { "monitor_touch", "m", 13, 12 },
    { "monitor_touch", "m", 31, 12 },
    { "monitor_touch", "m", 21, 18 },
    { "key", 16 },
  }
  local _, win = runner({ flashTicks = 1, play = function() return { [1] = 5, [2] = 1 } end },
                        events, econ)
  t.ok(win.findEver("LEFT WON!"), "an anonymous winner falls back to the seat label, never 'anon WON!'")
end

-- ---- the verdict headline appears on a STAKED result, not only a free one ----
do
  local econ = fakeEcon()
  local events = {
    { "monitor_touch", "m", 13, 12 },
    { "monitor_touch", "m", 31, 12 },
    { "monitor_touch", "m", 21, 18 },
    { "key", 16 },
  }
  local _, win = runner({ play = function() return { [1] = 5, [2] = 3 } end }, events, econ)
  t.ok(win.find("LEFT PLAYER WON"),
       "a staked results screen still states who won -- settled counters alone carry no verdict")
end

-- ---- ctx.tick() and the mid-match abort ----
-- A live pot must NEVER leave the loop unresolved: without resolve() on the way out, walking away
-- mid-match debits every seat and credits nobody, and the $ evaporates. Nothing exercised ctx.tick()
-- or this payout before -- both resolve paths could be deleted with the suite still green.
do
  local econ = fakeEcon()
  local ticks = 0
  local events = {
    { "monitor_touch", "m", 13, 12 },   -- seat 1 READY
    { "monitor_touch", "m", 31, 12 },   -- seat 2 READY
    { "monitor_touch", "m", 21, 18 },   -- GO
  }
  local res = runner({
    play = function(ctx)
      while ctx.tick() do
        ticks = ticks + 1
        if ticks > 50 then break end    -- guard: never spin if tick() stops reporting the abort
      end
      return { [1] = 3, [2] = 1 }
    end,
  }, events, econ, 3)                   -- presence goes away on the 3rd check, mid-rally

  t.ok(ticks >= 1, "play() actually ran through ctx.tick()")
  t.ok(ticks <= 50, "ctx.tick() reported the abort rather than looping forever")
  t.eq(res, "sleep", "walking away mid-match puts the station to sleep")
  t.eq(econ.opsOf("finish"), 1,
       "and RESOLVES the pot -- without this every seat is debited and nobody is paid")
end

t.done()
