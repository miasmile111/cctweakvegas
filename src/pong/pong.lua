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

-- ---- per-station wiring ----------------------------------------------------
-- pong.cfg is NOT in the package file list, so it survives `update pong` (which OVERWRITES
-- pong.lua). It is the ONLY place per-station wiring belongs. cfg always wins over discovery:
-- CC does not hand identically-built stations identical peripheral names.
--   drives=drive_0,drive_1     # seat order: left paddle first
local function readCfg()
  local out = {}
  if not fs.exists("pong.cfg") then return out end
  local f = fs.open("pong.cfg", "r")
  if not f then return out end
  local txt = f.readAll(); f.close()
  for k, v in txt:gmatch("([%w_]+)%s*=%s*([^\r\n#]+)") do
    out[k] = (v:gsub("%s+$", ""))
  end
  return out
end

local function splitList(s)
  if not s then return nil end
  local out = {}
  for item in s:gmatch("[^,%s]+") do out[#out + 1] = item end
  return #out > 0 and out or nil
end

local CFG   = readCfg()
local ANTE  = tonumber(CFG.ante) or 10

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

-- ===== DEBUG ECON HARNESS ===================================================
-- Native cell text on purpose. This is a harness for mp_econ, not a game: pong has no win
-- condition, no advert and no pixelfont alphabet to draw one with. Do not decorate it.
local econ                                   -- the mp_econ instance for this session
local GO_W, END_W = 6, 7                     -- button widths on the bottom row

local function btnHit(x, y)
  if y ~= H then return nil end
  if x <= GO_W then return "go" end
  if x > W - END_W then return "end" end
  return nil
end

-- top row, left: the seats. The score keeps the centre (draw() already put it there).
local function drawEcon()
  local st = econ.status()
  local parts = {}
  for i, s in ipairs(st.seats) do
    local who
    if s.antedId then who = s.antedId .. "*"          -- * = paid in; the seat is locked to this id
    elseif s.player then who = s.player
    else who = "anon" end
    if s.offline then
      parts[#parts + 1] = who .. " OFFLINE"
    elseif s.balance then
      parts[#parts + 1] = ("%s $%d"):format(who, s.balance)
    else
      parts[#parts + 1] = who
    end
  end
  win.setBackgroundColor(colors.black); win.setTextColor(colors.white)
  win.setCursorPos(1, 1)
  win.write(table.concat(parts, " | "):sub(1, W))
  if st.pot > 0 then
    local p = ("POT $%d"):format(st.pot)
    win.setCursorPos(math.max(1, W - #p + 1), 1)
    win.setTextColor(colors.yellow)
    win.write(p)
    win.setTextColor(colors.white)
  end
end

-- bottom row: [ GO ] ............... [ END ]
local function drawButtons()
  local gap = math.max(0, W - GO_W - END_W)
  win.setCursorPos(1, H)
  win.setBackgroundColor(colors.gray); win.setTextColor(colors.white)
  win.write(" GO   ")
  win.setBackgroundColor(colors.black)
  win.write(string.rep(" ", gap))
  win.setBackgroundColor(colors.gray)
  win.write(" END   ")
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
-- game each entry (fresh scores/ball). Returns "sleep" when the zone empties, or "quit" on Q.
local function play(mon, pres)
  ls, rs = 0, 0
  lp = math.floor((H - PADDLE_H) / 2) + 1
  rp = lp
  resetBall(math.random() < 0.5 and -1 or 1)

  econ = require("mp_econ").new{ drives = splitList(CFG.drives), ante = ANTE }
  local msg = nil                                  -- transient status line (deny reasons)

  local function render()
    draw()          -- the rally, unchanged
    drawEcon()
    drawButtons()
    if msg then
      win.setBackgroundColor(colors.black); win.setTextColor(colors.red)
      win.setCursorPos(1, 2); win.write(msg:sub(1, W))
      win.setTextColor(colors.white)
    end
    win.setVisible(true)
  end

  -- A live pot must never leave this loop unresolved. On the way out, whoever is ahead takes it --
  -- which is exactly what "the ante is forfeit" means when the player who walked off was losing.
  -- Without this, exiting mid-match debits both players and credits nobody: the $ evaporates.
  local function resolve()
    if econ.phase == "playing" then econ.finish{ [1] = ls, [2] = rs } end
  end

  local timer = os.startTimer(TICK)
  render()

  while true do
    local ev = { os.pullEvent() }
    if ev[1] == "timer" and ev[2] == timer then
      physics()
      render()
      if pres.gone() then resolve(); return "sleep" end
      timer = os.startTimer(TICK)

    elseif ev[1] == "monitor_touch" then
      local hit = btnHit(ev[3], ev[4])
      if hit == "go" then
        msg = nil
        local res, reason, seat = econ.start()
        if res == "deny" then
          if reason == "timeout" then msg = "HUB OFFLINE - nobody charged"
          elseif reason == "already playing" then msg = "MATCH ALREADY RUNNING"
          else msg = ("SEAT %d: %s - all antes refunded"):format(seat or 0, tostring(reason):upper()) end
        elseif res == "free" then
          msg = "FREE RALLY - 2 cards to play for a pot"
        end
        if res ~= "deny" then
          ls, rs = 0, 0                            -- reset only when a match actually (re)started
          resetBall(math.random() < 0.5 and -1 or 1)
        end
      elseif hit == "end" then
        local r = econ.finish{ [1] = ls, [2] = rs }
        if r.potWinner then
          msg = ("SEAT %d TAKES $%d"):format(r.potWinner, r.potShare[r.potWinner] or 0)
        else
          msg = ("SEAT %d WINS (no pot)"):format(r.matchWinner or 0)
        end
      end
      render()
      timer = os.startTimer(TICK)   -- re-arm unconditionally: a handler that touches the hub runs a
                                    -- nested event pump, and this loop only re-arms in its timer
                                    -- branch ([[event-pump-reentrancy]]). The cage does the same.

    elseif ev[1] == "disk" or ev[1] == "disk_eject" then
      econ.onEvent(ev)
      render()
      timer = os.startTimer(TICK)   -- refreshCard hits the hub: same reason as above

    elseif ev[1] == "rednet_message" then
      pres.fromEvent(ev)
    elseif ev[1] == "key" and ev[2] == keys.q then
      resolve(); return "quit"
    end
  end
end

require("idle_runner").run{ name = "pong", monitor = mon, zone = nil, play = play }
