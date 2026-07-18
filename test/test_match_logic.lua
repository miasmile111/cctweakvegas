-- test_match_logic.lua — the pure half of the match state machine.
--
-- The rule with money behind it: READY IS PER-MATCH CONSENT, NEVER A STICKY FLAG. If ready survived
-- a match, a player who walked away is still "ready" and the next GO antes their card for a game
-- they are not at. Every path back to the lobby clears it.
package.path = "src/lib/?.lua;test/?.lua;" .. package.path
local t = require("runner")
local ml = require("match_logic")

-- ---- ready flags ----
do
  local r = ml.newReady(2)
  t.eq(#r, 2, "newReady sizes to the seat count")
  t.eq(r[1], false, "seats start not ready")
  t.eq(ml.allReady(r), false, "nobody ready -> GO is not live")

  ml.toggle(r, 1)
  t.eq(r[1], true, "toggle sets")
  t.eq(ml.allReady(r), false, "ONE seat ready is not enough -- GO stays inert")

  ml.toggle(r, 2)
  t.eq(ml.allReady(r), true, "both ready -> GO goes live")

  ml.toggle(r, 1)
  t.eq(r[1], false, "toggle clears")
  t.eq(ml.allReady(r), false, "un-readying takes GO back down")
end

do
  t.eq(ml.allReady(ml.newReady(0)), false, "a zero-seat station never enables GO")
end

do
  local r = ml.newReady(2)
  ml.toggle(r, 5)
  t.eq(ml.allReady(r), false, "an out-of-range toggle is ignored, not an error")
  ml.toggle(r, 0)
  t.eq(ml.allReady(r), false, "seat 0 is ignored too")
end

-- ---- balance capture: the results screen replays money that ALREADY moved ----
do
  local status = { seats = {
    { player = "alice", balance = 100 },
    { player = nil,     balance = nil },
  } }
  local before = ml.captureBalances(status)
  t.eq(before[1], 100, "a carded seat's balance is captured")
  t.eq(before[2], nil, "an anonymous seat captures nil, not 0 -- it has no balance to replay")
end

-- ---- deny copy: the three states must never collapse into one lie ----
do
  t.ok(ml.denyMessage("timeout", 2):find("HUB OFFLINE"),
       "a hub timeout says HUB OFFLINE, never INSUFFICIENT -- telling a player holding $500 they "
    .. "are broke is a lie about money")
  t.ok(ml.denyMessage("timeout", 2):find("nobody charged"), "and reassures that nobody was charged")
  t.ok(ml.denyMessage("already playing", 1):find("ALREADY RUNNING"), "double-GO is its own message")
  t.ok(ml.denyMessage("insufficient", 2):find("SEAT 2"), "a funds deny names the seat")
  t.ok(ml.denyMessage("insufficient", 2):find("REFUNDED"),
       "and says the other antes came back -- rule 1, never a partial pot")
  t.ok(ml.denyMessage("unknown", 3):find("SEAT 3"), "an unknown reason still names the seat")
end

-- The message line is native cell-text on a 57-cell canvas. Capping at 55 keeps one cell of margin
-- at each edge; an ASCII hyphen is used throughout because an em dash is not reliably present in
-- CC's charset and renders as a box.
do
  for _, r in ipairs({ "timeout", "already playing", "insufficient", "unknown" }) do
    local m = ml.denyMessage(r, 2)
    t.ok(#m <= 55, "deny copy for '" .. r .. "' fits the 55-cell cap")
    t.eq(m:find("\226"), nil, "deny copy for '" .. r .. "' is pure ASCII (no em dash)")
  end
  t.ok(#ml.denyMessage(("x"):rep(200), 2) <= 55, "even a pathological reason string is capped")
end

-- ---- staked vs free ----
do
  t.eq(ml.staked(20), true, "a pot means the match was staked")
  t.eq(ml.staked(0), false, "no pot means a free match")
end

-- ---- free result text ----
do
  local labels = { "LEFT", "RIGHT" }
  t.eq(ml.freeResultText(labels, { [1] = 5, [2] = 3 }), "LEFT PLAYER WON", "left takes it")
  t.eq(ml.freeResultText(labels, { [1] = 2, [2] = 5 }), "RIGHT PLAYER WON", "right takes it")
  t.eq(ml.freeResultText(labels, { [1] = 5 }),          "LEFT PLAYER WON",
       "a missing score counts as 0")
  t.eq(ml.freeResultText(labels, { [1] = 3, [2] = 3 }), "LEFT PLAYER WON",
       "a tie goes to the lowest seat -- pong cannot tie at first-to-5, this is only a guard")
end

-- ---- the win flash: the beat between the last rally point and the money ----
do
  local labels = { "LEFT", "RIGHT" }
  local carded = { seats = { { player = "alice" }, { player = "bob" } } }
  t.eq(ml.winnerText(labels, carded, { [1] = 5, [2] = 3 }), "alice WON!",
       "a carded winner is named by their card id -- the player sees THEIR name, not a seat")
  t.eq(ml.winnerText(labels, carded, { [1] = 2, [2] = 5 }), "bob WON!", "and so is seat 2")
end

do
  -- An anonymous winner has no id to show, so it falls back to the seat label. It must never
  -- render "anon WON!" or an empty name.
  local anon = { seats = { { player = nil }, { player = "bob" } } }
  t.eq(ml.winnerText({ "LEFT", "RIGHT" }, anon, { [1] = 5, [2] = 1 }), "LEFT WON!",
       "an anonymous winner falls back to the seat label")
end

do
  local long = { seats = { { player = "bartholomew-the-longwinded" }, { player = "bob" } } }
  local txt = ml.winnerText({ "LEFT", "RIGHT" }, long, { [1] = 5, [2] = 0 })
  t.ok(#txt <= 24, "a long id is truncated so the flash panel cannot overflow the canvas")
  t.ok(txt:find("WON!"), "and it still says WON!")
end

do
  local empty = { seats = { { player = "" }, { player = "bob" } } }
  t.eq(ml.winnerText({ "LEFT", "RIGHT" }, empty, { [1] = 5, [2] = 1 }), "LEFT WON!",
       "an EMPTY-string id falls back to the seat label -- '' is truthy in Lua, so it must be "
    .. "rejected explicitly or the flash reads ' WON!' with no winner on it")
end

-- ---- result rows: from balanceAtGO to balanceNow ----
do
  local labels = { "LEFT", "RIGHT" }
  local before = { [1] = 100, [2] = 100 }
  local status = { seats = {
    { player = "alice", balance = 110 },   -- anted 10, won the 20 pot
    { player = "bob",   balance = 90  },   -- anted 10, lost it
  } }
  local rows = ml.resultRows(labels, before, status, { [1] = 5, [2] = 3 })

  t.eq(#rows, 2, "one row per seat")
  t.eq(rows[1].label, "LEFT", "row carries the seat label")
  t.eq(rows[1].id, "alice", "row carries the card id")
  t.eq(rows[1].from, 100, "the winner's counter starts where it was at GO")
  t.eq(rows[1].to, 110, "and climbs past its own start -- ante back, plus the pot")
  t.eq(rows[2].from, 100, "the loser starts at the same place")
  t.eq(rows[2].to, 90, "and drains by the ante")
end

do
  -- An anonymous seat has no money to replay; it must still appear, so the screen shows a seat
  -- that played rather than silently omitting a player.
  local rows = ml.resultRows({ "LEFT", "RIGHT" },
    { [1] = 100 },
    { seats = { { player = "alice", balance = 90 }, { player = nil, balance = nil } } },
    { [1] = 5, [2] = 1 })
  t.eq(#rows, 2, "the anonymous seat still gets a row")
  t.eq(rows[2].id, nil, "with no id")
  t.eq(rows[2].from, nil, "and nothing to animate")
  t.eq(rows[2].to, nil, "at either end")
end

-- ---- newReady must return a FRESH table every call ----
-- This is the module's central promise -- ready is per-match consent, never sticky. A cached or
-- shared table would make a flag survive a match, and the next GO would ante the card of a player
-- who had already walked away. Proven necessary: a cached-table implementation passed every other
-- assertion in this file.
do
  local a = ml.newReady(2)
  local b = ml.newReady(2)
  t.ok(a ~= b, "two calls return two DIFFERENT tables, never one shared one")

  ml.toggle(a, 1)
  t.eq(b[1], false, "mutating one ready table does not touch another")

  local c = ml.newReady(2)
  t.eq(c[1], false, "a table made AFTER another was toggled still starts clean")
  t.eq(c[2], false, "in both seats")
end

t.done()
