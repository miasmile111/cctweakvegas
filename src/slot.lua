-- slot.lua — diegetic slot machine on ONE CC:Tweaked advanced monitor, lever-triggered.
--   Top monitor (1x2 portrait) shows 3 spinning reels; a redstone LEVER spins them.
--   Run:  slot        -> play (pull the lever to spin)
--   Run:  slot test   -> list monitors + sizes AND live redstone levels per side (fill config)
--
-- Wiring: place the ADVANCED top monitor (1 wide x 2 tall). Wire your lever so its redstone
-- reaches a side of the computer; the game spins when that side's ANALOG level hits SPIN_LEVEL.
-- Run `slot test` to find the monitor name + which side the lever feeds, then set config below.
-- Re-host + re-import after editing (HTTP snapshot).

-- ---- config ----------------------------------------------------------------
local TOP_NAME   = "top"     -- the 1x2 portrait monitor (side name if touching, else monitor_N)
local TOP_SCALE  = 0.5
local SPIN_SIDE  = "back"    -- computer side the lever's redstone feeds
local SPIN_LEVEL = 15        -- spin when analog signal on SPIN_SIDE reaches this (lever ramps 0->15)
-- ----------------------------------------------------------------------------

local args = { ... }

local subpixel = require("subpixel")
local SYMBOLS  = require("slot_symbols")
local logic    = require("slot_logic")

local RED, YELLOW, GREEN, WHITE, BLACK, GREY = 16384, 16, 8192, 1, 32768, 128
local SYM_W, SYM_H = 8, 9
local SYMBOL_PX = SYM_H + 2   -- one symbol slot's pixel height (sprite + gap between symbols)

-- Animated background: these unused colour slots get redefined at runtime to a drifting
-- deep-blue <-> teal gradient (see updateGradient). None collide with the symbol/UI colours.
local GRAD = { 2048, 512, 8, 1024, 64 }   -- blue, cyan, lightBlue, purple, pink palette slots
local GRAD_DEEP = { 0.00, 0.10, 0.65 }    -- vivid blue (r,g,b 0..1) — bright on purpose to verify
local GRAD_TEAL = { 0.00, 0.75, 0.65 }    -- vivid teal

local function findMon(name)
  local m = peripheral.wrap(name)
  if not m or peripheral.getType(name) ~= "monitor" then
    error(("Monitor '%s' not found. Run `slot test` to list names, then edit config."):format(name), 0)
  end
  return m
end

-- layout computed from the canvas size: reels live in the middle ~80%, leaving a 10% lane on
-- each side for the animated bulb columns so they never overlap the play area.
local function topLayout(cv)
  local playTop = math.floor(cv.h * 0.45)              -- upper ~45% reserved (future scoreboard)
  local marginX = math.max(2, math.floor(cv.w * 0.10)) -- 10% bulb lane each side
  local zoneW   = cv.w - 2 * marginX
  local gap     = math.floor((zoneW - 3 * SYM_W) / 2)  -- leftover space split into 2 reel gaps
  if gap < 0 then gap = 0 end
  local startX  = marginX + math.floor((zoneW - (3 * SYM_W + 2 * gap)) / 2) + 1
  local xs = {}
  for i = 1, 3 do xs[i] = startX + (i - 1) * (SYM_W + gap) end
  local bannerTop = cv.h - 5
  local paylineY  = playTop + math.floor((bannerTop - playTop - SYM_H) / 2)  -- center reels
  return { playTop = playTop, marginX = marginX, xs = xs, paylineY = paylineY, bannerTop = bannerTop }
end

local function drawReel(cv, x, centerY, reel)
  if reel.stopped then
    -- landed: final symbol on the payline, static neighbours above/below
    cv:drawSprite(x, centerY, SYMBOLS[reel.final])
    cv:drawSprite(x, centerY - SYMBOL_PX, SYMBOLS[(reel.final % logic.NUM_SYMBOLS) + 1])
    cv:drawSprite(x, centerY + SYMBOL_PX, SYMBOLS[((reel.final - 2) % logic.NUM_SYMBOLS) + 1])
  else
    -- spinning: a strip of symbols rolls upward continuously, wrapping every SYMBOL_PX
    local shift = reel.pos % SYMBOL_PX
    local top   = math.floor(reel.pos / SYMBOL_PX)
    for k = -1, 2 do
      local idx = ((reel.final + top + k) % logic.NUM_SYMBOLS) + 1
      cv:drawSprite(x, centerY - shift + (k - 1) * SYMBOL_PX, SYMBOLS[idx])
    end
  end
end

local function drawTop(cv, reels, bulbTick, result)
  cv:clear(BLACK)                         -- reserved area (above playTop) stays black
  local L = topLayout(cv)
  -- animated gradient background across the play region (colours are palette-driven; the RGB
  -- of the GRAD slots drifts over time in updateGradient, recolouring these bands for free)
  local bandH = math.ceil((L.bannerTop - L.playTop) / #GRAD)
  for b = 1, #GRAD do
    cv:fillRect(1, L.playTop + (b - 1) * bandH, cv.w, bandH, GRAD[b])
  end
  -- marquee bar (flashes gold on a win)
  local marq = (result == "win" and bulbTick % 2 == 0) and YELLOW or RED
  cv:fillRect(1, L.playTop, cv.w, 3, marq)
  -- payline highlight band
  cv:fillRect(1, L.paylineY - 1, cv.w, SYM_H + 2, GREY)
  -- reels (middle 80%)
  for i = 1, 3 do
    drawReel(cv, L.xs[i], L.paylineY, reels[i])
  end
  -- bulb lanes in the outer 10% (chase normally; all flash together on a win)
  for y = L.playTop, L.bannerTop - 2, 4 do
    local on
    if result == "win" then on = (bulbTick % 2 == 0)
    else on = ((math.floor(y / 4) + bulbTick) % 2 == 0) end
    local c = on and YELLOW or (result == "win" and RED or GREY)
    cv:fillRect(1, y, 2, 2, c)
    cv:fillRect(cv.w - 1, y, 2, 2, c)
  end
  -- result banner (text overlay is written by drawTopFrame, on top of this fill)
  if result == "win" then
    cv:fillRect(1, L.bannerTop, cv.w, 5, GREEN)
  elseif result == "lose" then
    cv:fillRect(1, L.bannerTop, cv.w, 5, RED)
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
  print("Live redstone levels (pull your lever; Q quits):")
  local sides = { "top", "bottom", "left", "right", "front", "back" }
  local timer = os.startTimer(0.2)
  while true do
    local ev = { os.pullEvent() }
    if ev[1] == "timer" and ev[2] == timer then
      local _, row = term.getCursorPos()
      term.setCursorPos(1, math.max(1, row))
      local parts = {}
      for _, s in ipairs(sides) do
        parts[#parts + 1] = ("%s=%2d"):format(s, redstone.getAnalogInput(s))
      end
      term.clearLine()
      io.write(table.concat(parts, "  "))
      term.setCursorPos(1, row)
      timer = os.startTimer(0.2)
    elseif ev[1] == "key" and ev[2] == keys.q then
      print("")
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

local topMon = findMon(TOP_NAME); topMon.setTextScale(TOP_SCALE)
local tw, th = topMon.getSize()
local topWin = window.create(topMon, 1, 1, tw, th, true)   -- offscreen buffer -> no flicker
local topCv  = subpixel.new(topWin)

local TICK = 0.05

-- capture the gradient slots' original palette so we can restore it on exit
local gradOrig = {}
for i = 1, #GRAD do gradOrig[i] = { topMon.getPaletteColour(GRAD[i]) } end

-- drift the GRAD palette slots along a deep-blue <-> teal wave; changing the palette recolours
-- the already-drawn background bands with no redraw, so this costs ~5 calls/tick (basically free)
local function updateGradient(phase)
  for i = 1, #GRAD do
    local a = 0.5 + 0.5 * math.sin(phase + i * 0.9)
    local r = GRAD_DEEP[1] + (GRAD_TEAL[1] - GRAD_DEEP[1]) * a
    local g = GRAD_DEEP[2] + (GRAD_TEAL[2] - GRAD_DEEP[2]) * a
    local b = GRAD_DEEP[3] + (GRAD_TEAL[3] - GRAD_DEEP[3]) * a
    topMon.setPaletteColour(GRAD[i], r, g, b)
    topWin.setPaletteColour(GRAD[i], r, g, b)
  end
end

-- draw one full top-monitor frame (subpixel graphics + banner text overlay), flushed at once
local function drawTopFrame(reels, bulbTick, result)
  topWin.setVisible(false)
  drawTop(topCv, reels, bulbTick, result)
  if result == "win" or result == "lose" then
    local label = (result == "win") and "WIN!" or "LOSE"
    topWin.setTextColor(WHITE)
    topWin.setBackgroundColor(result == "win" and GREEN or RED)
    topWin.setCursorPos(math.floor((tw - #label) / 2) + 1, th)
    topWin.write(label)
  end
  topWin.setVisible(true)
end

local function newSpin()
  local a, b, c = logic.pickFinals(rng)
  return {
    logic.newReel(a, 12),   -- staggered stop ticks (reel 1, 2, 3)
    logic.newReel(b, 20),
    logic.newReel(c, 28),
  }
end

local state = "idle"        -- idle | spinning | result
local reels = newSpin()
for _, r in ipairs(reels) do r.stopped = true end
local tick, spinTick, resultAt, result = 0, 0, nil, nil
local armed = true          -- rising-edge guard: only spin when the lever crosses UP to SPIN_LEVEL

updateGradient(0)
drawTopFrame(reels, 0, nil)
local timer = os.startTimer(TICK)

while true do
  local ev = { os.pullEvent() }
  if ev[1] == "timer" and ev[2] == timer then
    tick = tick + 1
    updateGradient(tick * 0.05)   -- slow blue<->teal drift, every state

    -- read the physical lever (poll every tick — a held signal fires no event)
    local lvl = redstone.getAnalogInput(SPIN_SIDE)
    if state == "idle" and armed and lvl >= SPIN_LEVEL then
      reels = newSpin()
      state, spinTick, armed = "spinning", 0, false
    end
    if lvl < SPIN_LEVEL then armed = true end   -- re-arm once the lever drops back

    if state == "spinning" then
      spinTick = spinTick + 1
      local allStopped = true
      for _, r in ipairs(reels) do
        if not logic.stepReel(r, spinTick, SYMBOL_PX) then allStopped = false end
      end
      drawTopFrame(reels, tick, nil)
      if allStopped then
        result = logic.isWin(reels[1].final, reels[2].final, reels[3].final) and "win" or "lose"
        drawTopFrame(reels, tick, result)
        state, resultAt = "result", tick
      end
    elseif state == "result" then
      drawTopFrame(reels, tick, result)         -- keep the win flash / banner animating
      if tick - resultAt > 40 then              -- ~2s banner, then back to attract
        result = nil
        state = "idle"
        drawTopFrame(reels, tick, nil)
      end
    else -- idle: keep the attract bulbs alive
      drawTopFrame(reels, tick, nil)
    end

    timer = os.startTimer(TICK)
  elseif ev[1] == "key" and ev[2] == keys.q then
    break
  end
end

-- cleanup: restore the gradient slots to their original palette, then clear
for i = 1, #GRAD do
  local o = gradOrig[i]
  topMon.setPaletteColour(GRAD[i], o[1], o[2], o[3])
end
topMon.setBackgroundColor(colors.black); topMon.clear(); topMon.setCursorPos(1, 1); topMon.setTextScale(1)
print("Thanks for playing Slots!")
