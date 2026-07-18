-- test_pong_logic.lua — pong's rally physics and its win condition, with no monitor.
--
-- The physics is the ONE part of the 2026 prototype worth keeping; these tests pin its behaviour so
-- the rewrite around it cannot quietly change how the game feels.
package.path = "src/pong/?.lua;src/lib/?.lua;test/?.lua;" .. package.path
local t = require("runner")
local pl = require("pong_logic")

local function newGame()
  local s = pl.newState(57, 24, 6)
  pl.resetBall(s, 1, 0)
  return s
end

-- ---- clamp ----
do
  t.eq(pl.clamp(5, 1, 10), 5, "in range passes through")
  t.eq(pl.clamp(0, 1, 10), 1, "below clamps to lo")
  t.eq(pl.clamp(99, 1, 10), 10, "above clamps to hi")
end

-- ---- setup ----
do
  local s = newGame()
  t.eq(s.ls, 0, "left starts at 0")
  t.eq(s.rs, 0, "right starts at 0")
  t.ok(s.bx > 1 and s.bx < 57, "the ball starts on the field")
  t.ok(s.lp >= 1, "the left paddle starts on the field")
end

-- ---- paddles move, and cannot leave the field ----
do
  local s = newGame()
  local y0 = s.lp
  pl.step(s, -1, 0)
  t.ok(s.lp < y0, "-1 moves the left paddle up")
  pl.step(s, 1, 0); pl.step(s, 1, 0)
  t.ok(s.lp > y0 - 1, "+1 moves it back down")
end

do
  local s = newGame()
  for _ = 1, 200 do pl.step(s, -1, 0) end
  t.eq(s.lp, 1, "a paddle held up stops at the top edge, never off-field")
end

do
  local s = newGame()
  for _ = 1, 200 do pl.step(s, 0, 1) end
  t.eq(s.rp, 24 - 6 + 1, "a paddle held down stops with its whole body on the field")
end

-- ---- walls bounce ----
do
  local s = newGame()
  s.by, s.bvy = 1, -1
  pl.step(s, 0, 0)
  t.ok(s.bvy > 0, "the ball bounces off the top wall")
  s.by, s.bvy = 24, 1
  pl.step(s, 0, 0)
  t.ok(s.bvy < 0, "and off the bottom wall")
end

-- ---- scoring ----
do
  local s = newGame()
  s.bx, s.bvx = 1.2, -1        -- past the left paddle, heading out
  s.lp = 20                    -- paddle nowhere near it
  pl.step(s, 0, 0)
  t.eq(s.rs, 1, "a ball leaving the left edge scores for RIGHT")
  t.ok(s.bx > 1 and s.bx < 57, "and the ball is re-served onto the field")
end

do
  local s = newGame()
  s.bx, s.bvx = 56.5, 1
  s.rp = 1
  s.by = 20                    -- paddle nowhere near it
  pl.step(s, 0, 0)
  t.eq(s.ls, 1, "a ball leaving the right edge scores for LEFT")
end

-- ---- a paddle hit returns the ball and does NOT score ----
do
  local s = newGame()
  s.lp, s.paddleH = 10, 6
  s.by = 12                    -- squarely on the left paddle
  -- bx = 3.0 so the ball MOVES INTO the window [2,3] this frame. Starting at 2.4 would be an
  -- impossible state: the window is 1 cell wide and the ball steps 0.6, so an approaching ball
  -- always lands inside it -- a ball at 2.4 heading left has already been dealt with.
  s.bx, s.bvx, s.bvy = 3.0, -0.6, 0
  pl.step(s, 0, 0)
  t.ok(s.bvx > 0, "the ball comes off the left paddle heading right")
  t.eq(s.rs, 0, "and nobody scored")
end

-- the off-centre kick is the game's feel; a hit above the paddle's middle must send the ball up
do
  local s = newGame()
  s.lp = 10
  s.by = 10                    -- top of a 6-tall paddle, above its centre (13)
  s.bx, s.bvx, s.bvy = 3.0, -0.6, 0
  pl.step(s, 0, 0)
  t.ok(s.bvy < 0, "a hit above the paddle's centre kicks the ball upward")
end

do
  local s = newGame()
  s.lp = 10
  s.by = 15                    -- below the centre
  s.bx, s.bvx, s.bvy = 3.0, -0.6, 0
  pl.step(s, 0, 0)
  t.ok(s.bvy > 0, "a hit below the centre kicks it downward")
end

-- ---- FIRST TO 5 ----
do
  local s = newGame()
  t.eq(pl.isOver(s, 5), false, "0-0 is not over")
  s.ls = 4
  t.eq(pl.isOver(s, 5), false, "4 is not 5")
  s.ls = 5
  t.eq(pl.isOver(s, 5), true, "left reaching 5 ends the match")
end

do
  local s = newGame()
  s.rs = 5
  t.eq(pl.isOver(s, 5), true, "right reaching 5 ends it too")
end

do
  -- The match must terminate. A rally with a paddle parked away from the ball always concedes,
  -- so a bounded loop must reach 5 -- if this ever spins, the win condition is unreachable.
  local s = newGame()
  local n = 0
  while not pl.isOver(s, 5) and n < 20000 do pl.step(s, 0, 0); n = n + 1 end
  t.eq(pl.isOver(s, 5), true, "an unattended rally reaches 5 and the match terminates")
end

t.done()
