-- pong_logic.lua — pong's rally physics and win condition. Pure: no monitor, no redstone, no events.
--
-- This is the ONE part of the original 2026 prototype worth keeping. It is hoisted out of pong.lua
-- so it can be tested offline (the slot_logic / slot.lua split), and so the rewrite around it
-- cannot quietly change how the game feels.
local M = {}

M.PADDLE_STEP = 1      -- cells a paddle moves per frame while its plate is held
M.BALL_SPEED  = 0.6    -- cells the ball moves per frame

function M.clamp(v, lo, hi)
  if v < lo then return lo elseif v > hi then return hi else return v end
end

function M.newState(W, H, paddleH)
  local top = math.floor((H - paddleH) / 2) + 1
  return {
    W = W, H = H, paddleH = paddleH,
    leftX = 2, rightX = W - 1,
    lp = top, rp = top,
    bx = W / 2, by = H / 2, bvx = M.BALL_SPEED, bvy = 0,
    ls = 0, rs = 0,
  }
end

-- dir = 1 serves right, -1 serves left. vy is the vertical component; the caller supplies it so
-- this module stays deterministic (pong.lua randomises it).
function M.resetBall(s, dir, vy)
  s.bx, s.by = s.W / 2, s.H / 2
  s.bvx = M.BALL_SPEED * dir
  s.bvy = vy or 0
end

-- One physics frame. lpv/rpv are -1 (up), 0 (still) or 1 (down).
function M.step(s, lpv, rpv)
  s.lp = M.clamp(s.lp + (lpv or 0) * M.PADDLE_STEP, 1, s.H - s.paddleH + 1)
  s.rp = M.clamp(s.rp + (rpv or 0) * M.PADDLE_STEP, 1, s.H - s.paddleH + 1)

  s.bx = s.bx + s.bvx
  s.by = s.by + s.bvy
  if s.by < 1    then s.by, s.bvy = 1, -s.bvy end
  if s.by > s.H  then s.by, s.bvy = s.H, -s.bvy end

  -- Paddle hits (checked AFTER ball movement -- this is what the in-world-verified original
  -- prototype does). The off-centre kick is the game's whole feel: the further from the paddle's
  -- middle the ball lands, the harder it is deflected.
  -- Checking after movement is safe against tunneling: the window is 1 cell wide (leftX..leftX+1)
  -- and the ball steps 0.6 per frame, so an approaching ball always lands inside the window on
  -- some frame -- it can never skip over it.
  if s.bx <= s.leftX + 1 and s.bx >= s.leftX and s.by >= s.lp and s.by < s.lp + s.paddleH then
    s.bx, s.bvx = s.leftX + 1, math.abs(s.bvx)
    s.bvy = s.bvy + (s.by - (s.lp + s.paddleH / 2)) * 0.15
  end
  if s.bx >= s.rightX - 1 and s.bx <= s.rightX and s.by >= s.rp and s.by < s.rp + s.paddleH then
    s.bx, s.bvx = s.rightX - 1, -math.abs(s.bvx)
    s.bvy = s.bvy + (s.by - (s.rp + s.paddleH / 2)) * 0.15
  end

  if s.bx < 1   then s.rs = s.rs + 1; M.resetBall(s,  1, s.bvy) end
  if s.bx > s.W then s.ls = s.ls + 1; M.resetBall(s, -1, s.bvy) end

  return s
end

-- FIRST TO `target`. The original prototype had no win condition at all -- a debug END button
-- resolved the match, which is why it could never have a results screen.
function M.isOver(s, target)
  return s.ls >= target or s.rs >= target
end

return M
