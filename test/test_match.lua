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
-- ever written, never reset. find() searches `_log` on purpose: the win flash is drawn, pumped for
-- flashTicks frames, then unconditionally overwritten by the results screen's own clear() in the
-- SAME synchronous call (no event boundary in between) -- that overwrite is the whole point of a
-- transient flash. A find() scoped to only the current frame could therefore never observe the
-- flash text once the match finished, which would make the win-flash assertions below unfalsifiable
-- fails, not a real check of what was drawn.
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
    for _, e in ipairs(w._log) do
      if tostring(e.text):find(p, 1, true) then return e end
    end
  end
  return w
end

-- Scripted event source. Entries are handed out in order; once the script runs dry it emits filler
-- timer ticks so a phase that legitimately waits (the win flash, the results dwell) does not have
-- to have every tick spelled out. A hard cap still catches a loop that never returns.
--
-- startTimer always returns the SAME id so a scripted { "timer", 1 } is always the live timer --
-- the real code re-arms constantly and only id equality matters.
local TIMER_ID = 1
local function fakeOs(events)
  local i, filler = 0, 0
  return {
    pullEvent = function()
      i = i + 1
      if events[i] then return unpack(events[i]) end
      filler = filler + 1
      if filler > 2000 then error("EVENTS EXHAUSTED -- the match loop never returned", 0) end
      return "timer", TIMER_ID
    end,
    startTimer = function() return TIMER_ID end,
    epoch = function() return 0 end,
  }
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
  function e.onEvent(ev) e._calls[#e._calls + 1] = { op = "onEvent", ev = ev } end
  function e.status() return e._status end
  function e.cardedCount() return 2 end
  function e.start()
    e._calls[#e._calls + 1] = { op = "start" }
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
  local play = match.run{
    title = "PONG", seatLabels = { "LEFT", "RIGHT" },
    minSeats = 2, maxSeats = 2, ante = 10, target = 5,
    controls = {}, drives = { "drive_0", "drive_1" },
    flashTicks = cfg.flashTicks or 0, resultTicks = cfg.resultTicks or 9999,
    play = cfg.play,
    deps = {
      mp_econ = { new = function() return econ end },
      window  = { create = function() return win end },
      os      = fakeOs(events),
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
                     { { "timer", 1 } }, econ, 1)
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
    { "timer", 1 },
    { "key", 16 },
  }
  local _, win = runner({ play = function() played = true; return {} end }, events, econ)
  t.eq(played, false, "a denied GO does not run the game")
  t.ok(win.find("HUB OFFLINE"), "and the lobby says HUB OFFLINE, not INSUFFICIENT")
end

-- ---- disk events reach mp_econ ----
do
  local econ = fakeEcon()
  runner({ play = function() return {} end },
         { { "disk", "drive_0" }, { "key", 16 } }, econ)
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
    { "timer", 1 },                            -- the one flash tick
    { "key", 16 },
  }
  local _, win = runner({ flashTicks = 1, play = function() return { [1] = 5, [2] = 3 } end },
                        events, econ)
  t.ok(win.find("alice WON!"),
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
    { "timer", 1 },
    { "key", 16 },
  }
  local _, win = runner({ flashTicks = 1, play = function() return { [1] = 5, [2] = 1 } end },
                        events, econ)
  t.ok(win.find("LEFT WON!"), "an anonymous winner falls back to the seat label, never 'anon WON!'")
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

t.done()
