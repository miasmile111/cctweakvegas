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

local function drawReel(cv, x, centerY, reel, dimAbove)
  -- center symbol
  cv:drawSprite(x, centerY, SYMBOLS[reel.final])
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
    drawReel(cv, x, L.paylineY, reels[i], true)
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

-- (play mode wired up in later tasks)
local topMon = findMon(TOP_NAME)
topMon.setTextScale(TOP_SCALE)
local topCv = subpixel.new(topMon)
local demoReels = {
  logic.newReel(1, 0), logic.newReel(1, 0), logic.newReel(1, 0),
}
for _, r in ipairs(demoReels) do r.stopped = true end
drawTop(topCv, demoReels, "idle", 0, "win")
print("Rendered a demo frame to the top monitor. Ctrl+T to exit.")
