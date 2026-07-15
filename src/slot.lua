-- slot.lua — diegetic slot machine on two CC:Tweaked advanced monitors.
--   Top monitor (1x2 portrait) shows the reels; front monitor (1x1) is the touch SPIN button.
--   Run:  slot          -> play (tap the front monitor to spin)
--   Run:  slot test     -> list monitors + sizes, echo touch coords (to fill config below)
--
-- Wiring: put BOTH advanced monitors on a wired modem + networking cable so they don't use up
-- computer sides. Run `slot test`, note each monitor's network name + which one is front/top,
-- then set TOP_NAME / FRONT_NAME below. Re-host + re-import after editing (HTTP snapshot).

-- ---- config ----------------------------------------------------------------
local TOP_NAME   = "monitor_0"   -- 1x2 portrait play monitor (network name)
local FRONT_NAME = "monitor_1"   -- 1x1 touch button monitor
local TOP_SCALE  = 0.5
local FRONT_SCALE = 0.5
-- ----------------------------------------------------------------------------

local args = { ... }

local function findMon(name)
  local m = peripheral.wrap(name)
  if not m or peripheral.getType(name) ~= "monitor" then
    error(("Monitor '%s' not found. Run `slot test` to list names, then edit config."):format(name), 0)
  end
  return m
end

local subpixel = require("subpixel")
local SYMBOLS  = require("slot_symbols")
local logic    = require("slot_logic")

local RED, YELLOW, GREEN, WHITE, BLACK, GREY = 16384, 16, 8192, 1, 32768, 128
local SYM_W, SYM_H = 8, 9
local REEL_GAP = 2

-- layout computed from the canvas size so it fits any real monitor
local function topLayout(cv)
  local playTop = math.floor(cv.h * 0.45)         -- upper ~45% reserved for scoreboard
  local reelsX  = math.floor((cv.w - (3 * SYM_W + 2 * REEL_GAP)) / 2) + 1
  local paylineY = playTop + 12                    -- center row baseline
  return { playTop = playTop, reelsX = reelsX, paylineY = paylineY }
end

local function drawReel(cv, x, centerY, reel, tick, i)
  -- center symbol: while spinning, cycle through symbols; once stopped, show the final result
  local center
  if reel.stopped then
    center = SYMBOLS[reel.final]
  else
    local ci = ((reel.final + tick * 2 + i) % logic.NUM_SYMBOLS) + 1
    center = SYMBOLS[ci]
  end
  cv:drawSprite(x, centerY, center)
  -- dim spin-past neighbors above/below (drawn darker by overlaying a translucent-ish band:
  -- simplest: draw neighbor sprites shifted by offset; CC has no alpha, so we just draw them)
  local above = SYMBOLS[(reel.final % logic.NUM_SYMBOLS) + 1]
  local below = SYMBOLS[((reel.final - 2) % logic.NUM_SYMBOLS) + 1]
  cv:drawSprite(x, centerY - SYM_H - 1 + (reel.offset or 0), above)
  cv:drawSprite(x, centerY + SYM_H + 1 + (reel.offset or 0), below)
end

local function drawTop(cv, reels, phase, bulbTick, result)
  cv:clear(BLACK)
  local L = topLayout(cv)
  -- marquee bar
  cv:fillRect(1, L.playTop, cv.w, 3, RED)
  -- payline highlight band
  cv:fillRect(1, L.paylineY - 1, cv.w, SYM_H + 2, GREY)
  -- reels
  for i = 1, 3 do
    local x = L.reelsX + (i - 1) * (SYM_W + REEL_GAP)
    drawReel(cv, x, L.paylineY, reels[i], bulbTick, i)
  end
  -- chasing bulb columns (both sides)
  for y = L.playTop, cv.h - 3, 4 do
    local on = ((math.floor(y / 4) + bulbTick) % 2 == 0)
    local c = on and YELLOW or GREY
    cv:fillRect(1, y, 2, 2, c)
    cv:fillRect(cv.w - 1, y, 2, 2, c)
  end
  -- result banner
  if result == "win" then
    cv:fillRect(1, cv.h - 5, cv.w, 5, GREEN)
  elseif result == "lose" then
    cv:fillRect(1, cv.h - 5, cv.w, 5, RED)
  end
  cv:render()
end

local ORANGE = 2

local function drawBorder(cv, tick)
  -- march a lit cell around the perimeter; every 3rd perimeter slot is "on"
  local lit = YELLOW
  local dim = ORANGE
  local i = 0
  local function seg(x, y) local on = ((i + tick) % 3 == 0); cv:fillRect(x, y, 2, 2, on and lit or dim); i = i + 1 end
  for x = 1, cv.w - 1, 2 do seg(x, 1) end
  for y = 3, cv.h - 1, 2 do seg(cv.w - 1, y) end
  for x = cv.w - 1, 1, -2 do seg(x, cv.h - 1) end
  for y = cv.h - 1, 3, -2 do seg(1, y) end
end

local function drawButton(cv, state, borderTick)
  cv:clear(BLACK)
  local m = 4                                   -- border margin
  local x, y, w, h = m, m, cv.w - 2 * m, cv.h - 2 * m
  local pressed = (state ~= "idle")
  local hi, lo = WHITE, GREY
  if pressed then hi, lo = GREY, WHITE end
  cv:fillRect(x, y, w, h, RED)
  -- bevel: top + left highlight, bottom + right shadow (swapped when pressed)
  cv:fillRect(x, y, w, 1, hi); cv:fillRect(x, y, 1, h, hi)
  cv:fillRect(x, y + h - 1, w, 1, lo); cv:fillRect(x + w - 1, y, 1, h, lo)
  drawBorder(cv, borderTick)
  cv:render()
  -- label via monitor text overlay (crisp) — draw after render using the raw monitor:
  return state == "locked" and "WAIT" or "SPIN"
end

local function testMode()
  print("Attached monitors:")
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "monitor" then
      local m = peripheral.wrap(name)
      m.setTextScale(0.5)
      local w, h = m.getSize()
      print(("  %s  ->  %d x %d  @0.5"):format(name, w, h))
    end
  end
  print("Tap a monitor (Q to quit). Coords print below:")
  while true do
    local ev = { os.pullEvent() }
    if ev[1] == "monitor_touch" then
      print(("touch: %s  x=%d y=%d"):format(ev[2], ev[3], ev[4]))
    elseif ev[1] == "key" and ev[2] == keys.q then
      return
    end
  end
end

if args[1] == "test" then
  testMode()
  print("Test mode done.")
  return
end

-- ===== PLAY =================================================================
math.randomseed(os.epoch("utc"))
local rng = function() return math.random() end

local topMon = findMon(TOP_NAME);   topMon.setTextScale(TOP_SCALE)
local frontMon = findMon(FRONT_NAME); frontMon.setTextScale(FRONT_SCALE)
local tw, th = topMon.getSize()
local topWin = window.create(topMon, 1, 1, tw, th, true)     -- offscreen buffer -> no flicker
local fw, fh = frontMon.getSize()
local frontWin = window.create(frontMon, 1, 1, fw, fh, true) -- offscreen buffer -> no flicker
local topCv = subpixel.new(topWin)
local frontCv = subpixel.new(frontWin)

local TICK = 0.05
local SYMBOL_PX = SYM_H + 2

local function drawFront(state, borderTick)
  local label = drawButton(frontCv, state, borderTick)
  frontWin.setTextColor(WHITE)
  frontWin.setCursorPos(math.floor((fw - #label) / 2) + 1, math.floor(fh / 2) + 1)
  frontWin.write(label)
end

local function newSpin()
  local a, b, c = logic.pickFinals(rng)
  return {
    logic.newReel(a, 12),   -- staggered stop ticks
    logic.newReel(b, 20),
    logic.newReel(c, 28),
  }
end

local state = "idle"        -- idle | spinning | result
local reels = newSpin()
for _, r in ipairs(reels) do r.stopped = true end
local tick, spinTick, resultAt, result = 0, 0, nil, nil

topWin.setVisible(false); drawTop(topCv, reels, "idle", 0, nil); topWin.setVisible(true)
frontWin.setVisible(false); drawFront("idle", 0); frontWin.setVisible(true)
local timer = os.startTimer(TICK)

while true do
  local ev = { os.pullEvent() }
  if ev[1] == "timer" and ev[2] == timer then
    tick = tick + 1
    if state == "spinning" then
      spinTick = spinTick + 1
      local allStopped = true
      for _, r in ipairs(reels) do
        if not logic.stepReel(r, spinTick, SYMBOL_PX) then allStopped = false end
      end
      topWin.setVisible(false); drawTop(topCv, reels, "spin", tick, nil); topWin.setVisible(true)
      frontWin.setVisible(false); drawFront("locked", tick); frontWin.setVisible(true)
      if allStopped then
        result = logic.isWin(reels[1].final, reels[2].final, reels[3].final) and "win" or "lose"
        topWin.setVisible(false); drawTop(topCv, reels, "result", tick, result); topWin.setVisible(true)
        state, resultAt = "result", tick
      end
    elseif state == "result" then
      frontWin.setVisible(false); drawFront("idle", tick); frontWin.setVisible(true)
      if tick - resultAt > 40 then          -- ~2s banner
        result = nil
        topWin.setVisible(false); drawTop(topCv, reels, "idle", tick, nil); topWin.setVisible(true)
        state = "idle"
      end
    else -- idle: keep the attract border + bulbs alive
      topWin.setVisible(false); drawTop(topCv, reels, "idle", tick, nil); topWin.setVisible(true)
      frontWin.setVisible(false); drawFront("idle", tick); frontWin.setVisible(true)
    end
    timer = os.startTimer(TICK)
  elseif ev[1] == "monitor_touch" and ev[2] == FRONT_NAME and state == "idle" then
    reels = newSpin()
    state, spinTick = "spinning", 0
    frontWin.setVisible(false); drawFront("pressed", tick); frontWin.setVisible(true)
  elseif ev[1] == "key" and ev[2] == keys.q then
    break
  end
end

-- cleanup
for _, m in ipairs({ topMon, frontMon }) do
  m.setBackgroundColor(colors.black); m.clear(); m.setCursorPos(1, 1); m.setTextScale(1)
end
print("Thanks for playing Slots!")
