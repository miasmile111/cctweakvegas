-- pong.lua — 2-player Pong on a CC:Tweaked monitor, controlled by IN-WORLD PRESSURE PLATES
-- Diegetic controls: each player stands on an "up" or "down" pressure plate wired to a
-- side of the computer. Watch the in-world monitor, not the GUI.
--
--   Run:  pong          -> play
--   Run:  pong test     -> live side monitor, to find which plate feeds which side
--
-- Wiring: connect 4 pressure plates, each to a different side of the computer (via redstone
-- dust). Put the MONITOR on a WIRED MODEM so it doesn't use up a side. Then run `pong test`,
-- step on each plate, note which side lights up, and set the SIDES map below to match.

-- ---- config ----------------------------------------------------------------
local SIDES = {
  left_up    = "left",    -- P1 up     (left paddle)
  left_down  = "front",   -- P1 down
  right_up   = "right",   -- P2 up     (right paddle)
  right_down = "back",    -- P2 down
}
local TEXT_SCALE  = 0.5    -- smaller = more cells = smoother; try 1 for chunkier
local TICK        = 0.05   -- seconds per physics frame (~20 fps)
local PADDLE_STEP = 1      -- cells the paddle moves per tick while its plate is held
local BALL_SPEED  = 0.6    -- cells the ball moves per tick
-- ----------------------------------------------------------------------------

local mon = peripheral.find("monitor")
if not mon then
  error("No monitor found. Attach a monitor (directly or via a wired modem) and rerun.", 0)
end
mon.setTextScale(TEXT_SCALE)
local W, H = mon.getSize()
local win = window.create(mon, 1, 1, W, H, true)   -- offscreen buffer -> no flicker

-- ===== TEST MODE: identify which physical plate feeds which computer side =====
local function testMode()
  local all = { "top", "bottom", "left", "right", "front", "back" }
  local timer = os.startTimer(0.1)
  while true do
    local ev = { os.pullEvent() }
    if ev[1] == "timer" and ev[2] == timer then
      win.setVisible(false)
      win.setBackgroundColor(colors.black)
      win.setTextColor(colors.white)
      win.clear()
      win.setCursorPos(1, 1)
      win.write("SIDE TEST - step on plates (Q quits)")
      for i, s in ipairs(all) do
        win.setCursorPos(1, i + 1)
        win.write(string.format("%-7s %s", s, redstone.getInput(s) and "[ON] " or "[   ]"))
      end
      win.setVisible(true)
      timer = os.startTimer(0.1)
    elseif ev[1] == "key" and ev[2] == keys.q then
      return
    end
  end
end

if ({ ... })[1] == "test" then
  testMode()
  mon.setBackgroundColor(colors.black); mon.clear(); mon.setCursorPos(1, 1); mon.setTextScale(1)
  print("Test mode done.")
  return
end

-- ===== GAME =================================================================
math.randomseed(os.epoch("utc"))

local PADDLE_H = math.max(3, math.floor(H / 4))
local LEFT_X   = 2
local RIGHT_X  = W - 1

local lp = math.floor((H - PADDLE_H) / 2) + 1   -- left paddle top row
local rp = lp
local lpv, rpv = 0, 0                            -- paddle velocity: -1 up, 1 down
local bx, by, bvx, bvy                           -- ball position + velocity (fractional)
local ls, rs = 0, 0                              -- scores

local function clamp(v, lo, hi)
  if v < lo then return lo elseif v > hi then return hi else return v end
end

local function resetBall(dir)
  bx, by = W / 2, H / 2
  bvx = BALL_SPEED * dir
  bvy = BALL_SPEED * (math.random() < 0.5 and -1 or 1)
end

local function fill(x, y, w, h, color)
  win.setBackgroundColor(color)
  local line = string.rep(" ", w)
  for i = 0, h - 1 do
    win.setCursorPos(x, y + i)
    win.write(line)
  end
end

-- read the four physical plates each tick (a held plate emits no event, so we POLL)
local function readPlates()
  lpv, rpv = 0, 0
  if redstone.getInput(SIDES.left_up)    then lpv = lpv - 1 end
  if redstone.getInput(SIDES.left_down)  then lpv = lpv + 1 end
  if redstone.getInput(SIDES.right_up)   then rpv = rpv - 1 end
  if redstone.getInput(SIDES.right_down) then rpv = rpv + 1 end
end

local function draw()
  win.setVisible(false)
  win.setBackgroundColor(colors.black)
  win.clear()
  for y = 1, H, 2 do fill(math.floor(W / 2), y, 1, 1, colors.white) end   -- net
  fill(LEFT_X,  lp, 1, PADDLE_H, colors.white)
  fill(RIGHT_X, rp, 1, PADDLE_H, colors.white)
  fill(clamp(math.floor(bx), 1, W), clamp(math.floor(by), 1, H), 1, 1, colors.white)
  win.setBackgroundColor(colors.black); win.setTextColor(colors.white)
  local s = ls .. "  " .. rs
  win.setCursorPos(math.max(1, math.floor(W / 2 - #s / 2)), 1)
  win.write(s)
  win.setVisible(true)
end

local function physics()
  readPlates()
  lp = clamp(lp + lpv * PADDLE_STEP, 1, H - PADDLE_H + 1)
  rp = clamp(rp + rpv * PADDLE_STEP, 1, H - PADDLE_H + 1)

  bx = bx + bvx
  by = by + bvy
  if by < 1 then by, bvy = 1, -bvy end
  if by > H then by, bvy = H, -bvy end

  if bx <= LEFT_X + 1 and bx >= LEFT_X and by >= lp and by < lp + PADDLE_H then
    bx, bvx = LEFT_X + 1, math.abs(bvx)
    bvy = bvy + (by - (lp + PADDLE_H / 2)) * 0.15
  end
  if bx >= RIGHT_X - 1 and bx <= RIGHT_X and by >= rp and by < rp + PADDLE_H then
    bx, bvx = RIGHT_X - 1, -math.abs(bvx)
    bvy = bvy + (by - (rp + PADDLE_H / 2)) * 0.15
  end

  if bx < 1 then rs = rs + 1; resetBall(1) end
  if bx > W then ls = ls + 1; resetBall(-1) end
end

-- ACTIVE session: pong's physics loop, run by idle_runner while a player is present. Resets the
-- game each entry (fresh scores/ball). Returns "sleep" when the zone empties (no round to finish),
-- or "quit" on the operator's Q.
local function play(mon, pres)
  ls, rs = 0, 0
  lp = math.floor((H - PADDLE_H) / 2) + 1
  rp = lp
  resetBall(math.random() < 0.5 and -1 or 1)
  local timer = os.startTimer(TICK)
  draw()

  while true do
    local ev = { os.pullEvent() }
    if ev[1] == "timer" and ev[2] == timer then
      physics()
      draw()
      if pres.gone() then return "sleep" end   -- zone empty: stop (no round to finish)
      timer = os.startTimer(TICK)
    elseif ev[1] == "rednet_message" then
      pres.fromEvent(ev)
    elseif ev[1] == "key" and ev[2] == keys.q then
      return "quit"
    end
  end
end

require("idle_runner").run{ name = "pong", monitor = mon, zone = nil, play = play }
