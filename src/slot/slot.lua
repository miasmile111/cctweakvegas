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
local SPIN_LEVEL = 13        -- spin when analog signal on SPIN_SIDE reaches this (lever ramps up to 15)
local ZONE = "all"  -- proximity zone this station answers to. "all" = any player in the hub's range.
                    -- (Per-station zones arrive with GPS; then set e.g. ZONE = "slot1".)
-- ----------------------------------------------------------------------------

local args = { ... }

local subpixel = require("subpixel")
local SYMBOLS  = require("slot_symbols")
local logic    = require("slot_logic")

local RED, YELLOW, GREEN, WHITE, BLACK, GREY, LIGHTGRAY = 16384, 16, 8192, 1, 32768, 128, 256
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

-- Layout: gradient fills the WHOLE canvas. A framed reel VIEWPORT sits in the lower-middle;
-- symbols are clipped to it (they roll in/out behind the top & bottom frame bars). Bulbs frame
-- all four sides. A banner row at the very bottom stays clear of bulbs for WIN/LOSE text.
local function topLayout(cv)
  local marginX = math.max(2, math.floor(cv.w * 0.10))  -- 10% side bulb lanes
  local zoneW   = cv.w - 2 * marginX
  local gap     = math.floor((zoneW - 3 * SYM_W) / 2)
  if gap < 0 then gap = 0 end
  local startX  = marginX + math.floor((zoneW - (3 * SYM_W + 2 * gap)) / 2) + 1
  local xs = {}
  for i = 1, 3 do xs[i] = startX + (i - 1) * (SYM_W + gap) end

  local barH      = math.max(3, math.floor(SYMBOL_PX * 0.7))  -- top/bottom frame bar thickness
  local bannerH   = 5
  local bannerTop = cv.h - bannerH + 1
  local viewTop   = math.floor(cv.h * 0.34) + barH            -- gradient/reserved space above
  local viewBot   = bannerTop - 1 - barH                      -- leave room for the bottom bar
  local paylineY  = math.floor((viewTop + viewBot) / 2 - SYM_H / 2)
  return {
    marginX = marginX, xs = xs, barH = barH,
    viewTop = viewTop, viewBot = viewBot, paylineY = paylineY, bannerTop = bannerTop,
    topBarY = viewTop - barH, botBarY = viewBot + 1,
  }
end

-- draw a sprite but only the rows that fall inside [yMin, yMax] — this clips reel symbols to the
-- viewport so they roll in/out behind the frame bars (the subpixel lib has no native clipping).
local function drawSpriteClipped(cv, x, y, sprite, yMin, yMax)
  y = math.floor(y)
  for dy = 0, sprite.h - 1 do
    local py = y + dy
    if py >= yMin and py <= yMax then
      for dx = 0, sprite.w - 1 do
        local col = sprite.px[dy * sprite.w + dx + 1]
        if col and col ~= 0 then cv:setPixel(x + dx, py, col) end
      end
    end
  end
end

-- one strip of symbols, rolling DOWNWARD, clipped to the viewport; pos==0 lands final on payline
local function drawReel(cv, x, reel, L)
  local n = logic.NUM_SYMBOLS
  local base = math.floor(reel.pos / SYMBOL_PX)
  for i = base - 1, base + 2 do
    local idx = ((reel.final - 1 + i) % n + n) % n + 1
    drawSpriteClipped(cv, x, L.paylineY + reel.pos - i * SYMBOL_PX, SYMBOLS[idx], L.viewTop, L.viewBot)
  end
end

-- a bulb: on = bright yellow; off = dim (grey normally, red during a win for a chase-of-red look)
local function bulb(cv, x, y, seed, bulbTick, result)
  local on
  if result == "win" then on = (bulbTick % 2 == 0)
  else on = ((seed + bulbTick) % 2 == 0) end
  cv:fillRect(x, y, 2, 2, on and YELLOW or (result == "win" and RED or GREY))
end

local function drawTop(cv, reels, bulbTick, result)
  local L = topLayout(cv)
  -- gradient background across the ENTIRE canvas (palette-driven; recoloured for free each tick)
  local bandH = math.ceil(cv.h / #GRAD)
  for b = 1, #GRAD do
    cv:fillRect(1, 1 + (b - 1) * bandH, cv.w, bandH, GRAD[b])
  end
  -- payline highlight (brighter, behind the symbols)
  cv:fillRect(1, L.paylineY - 1, cv.w, SYM_H + 2, LIGHTGRAY)
  -- reels, clipped to the viewport
  for i = 1, 3 do drawReel(cv, L.xs[i], reels[i], L) end
  -- top & bottom frame bars over the reel edges (flash gold on a win)
  local barCol = (result == "win" and bulbTick % 2 == 0) and YELLOW or RED
  cv:fillRect(1, L.topBarY, cv.w, L.barH, barCol)
  cv:fillRect(1, L.botBarY, cv.w, L.barH, barCol)
  -- bulbs around all four sides, on top of the bars
  local topRow = L.topBarY + math.floor(L.barH / 2) - 1
  local botRow = L.botBarY + math.floor(L.barH / 2) - 1
  for x = L.marginX, cv.w - L.marginX, 4 do
    bulb(cv, x, topRow, math.floor(x / 4), bulbTick, result)
    bulb(cv, x, botRow, math.floor(x / 4), bulbTick, result)
  end
  for y = L.viewTop, L.viewBot, 4 do
    bulb(cv, 1, y, math.floor(y / 4), bulbTick, result)
    bulb(cv, cv.w - 1, y, math.floor(y / 4), bulbTick, result)
  end
  -- result banner at the very bottom (below all bulbs; text overlay written by drawTopFrame)
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

-- draw one full top-monitor frame (subpixel graphics + banner text overlay), flushed at once.
-- ACTIVE (player present) shows the reels only; the COME PLAY advert is the IDLE screen (slot_advert.draw),
-- not an overlay here. `attract` is accepted for call-site compatibility but no longer draws a banner.
local function drawTopFrame(reels, bulbTick, result, attract, status)
  topWin.setVisible(false)
  drawTop(topCv, reels, bulbTick, result)
  -- economy header in the reserved top rows (plain text over the gradient)
  if status then
    topWin.setTextColor(WHITE); topWin.setBackgroundColor(BLACK)
    topWin.setCursorPos(1, 1)
    if status.denied then
      topWin.write("INSUFFICIENT")
    elseif status.player then
      topWin.write(("%s $%d"):format(status.player, status.balance or 0))
      topWin.setCursorPos(1, 2); topWin.write(("stake %d  win %d"):format(status.stake, status.lastWin))
    else
      topWin.setCursorPos(1, 1); topWin.write("FREE PLAY")
      topWin.setCursorPos(1, 2); topWin.write("insert card to bet")
    end
  end
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

-- Monitor helpers ------------------------------------------------------------
local function restorePalette()
  for i = 1, #GRAD do
    local o = gradOrig[i]
    topMon.setPaletteColour(GRAD[i], o[1], o[2], o[3])
  end
end

-- ACTIVE session: the 0.05s timer loop (attract -> spinning -> result), run by idle_runner while a
-- player is present. Returns "sleep" when the zone empties in attract (a spin always finishes first),
-- or "quit" on the operator's Q.
local function play(mon, pres)
  local state = "attract"
  local econ = require("sp_econ").new{ zone = ZONE, pay = require("slot_pay") }
  local reels = newSpin(); for _, r in ipairs(reels) do r.stopped = true end
  local tick, spinTick, resultAt, result = 0, 0, nil, nil
  local armed = true       -- rising-edge guard so a held lever doesn't auto-respin

  updateGradient(0)
  drawTopFrame(reels, 0, nil, true, econ.status())
  local timer = os.startTimer(TICK)

  while true do
    local ev = { os.pullEvent() }
    if ev[1] == "timer" and ev[2] == timer then
      tick = tick + 1
      updateGradient(tick * 0.05)

      local lvl = redstone.getAnalogInput(SPIN_SIDE)
      if state == "attract" and armed and lvl >= SPIN_LEVEL then
        local mode = econ.tryBet()               -- "staked" | "free" | "deny"
        if mode == "deny" then
          armed = false                          -- consume the pull; header shows INSUFFICIENT
        else
          reels = newSpin()
          state, spinTick, armed = "spinning", 0, false
        end
      end
      if lvl < SPIN_LEVEL then armed = true end

      if state == "spinning" then
        spinTick = spinTick + 1
        local allStopped = true
        for _, r in ipairs(reels) do
          if not logic.stepReel(r, spinTick, SYMBOL_PX) then allStopped = false end
        end
        drawTopFrame(reels, tick, nil, false, econ.status())
        if allStopped then
          result = logic.isWin(reels[1].final, reels[2].final, reels[3].final) and "win" or "lose"
          econ.settle({ reels[1].final, reels[2].final, reels[3].final })
          drawTopFrame(reels, tick, result, false, econ.status())
          state, resultAt = "result", tick
        end
      elseif state == "result" then
        drawTopFrame(reels, tick, result, false, econ.status())
        if tick - resultAt > 40 then           -- ~2s banner, then back to attract
          result = nil
          state = "attract"
          drawTopFrame(reels, tick, nil, true, econ.status())
        end
      else -- attract
        drawTopFrame(reels, tick, nil, true, econ.status())
        if pres.gone() then restorePalette(); return "sleep" end  -- zone emptied: restore palette, sleep
      end

      timer = os.startTimer(TICK)
    elseif ev[1] == "rednet_message" then
      pres.fromEvent(ev)                        -- update presence; sleep decision happens in attract
      econ.onEvent(ev)
    elseif ev[1] == "disk" or ev[1] == "disk_eject" then
      econ.onEvent(ev)                          -- card inserted/removed: re-read balance
    elseif ev[1] == "key" and ev[2] == keys.q then
      restorePalette()
      return "quit"
    end
  end
end

require("idle_runner").run{
  name = "slot", monitor = topMon, zone = ZONE,
  wake = { side = SPIN_SIDE, level = SPIN_LEVEL }, play = play,
}
