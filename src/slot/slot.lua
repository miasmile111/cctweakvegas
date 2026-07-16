-- slot.lua — diegetic slot machine on ONE CC:Tweaked advanced monitor (1x2 portrait, 15x24 @ 0.5).
--   A redstone LEVER spins the reels; the three on-screen stake buttons are TAPPED (monitor_touch)
--   to pick $10 / $25 / $100. Layout built from the owner's mockup (docs/mockups/slot-v3.json →
--   docs/slot-v3-mockup-handoff.md; iterated in tools/slot-preview.html).
--   Run:  slot        -> play
--   Run:  slot test   -> list monitors + sizes AND live redstone levels per side (fill config)
--
-- Wiring: place the ADVANCED 1x2 monitor. Wire the spin lever so its redstone reaches a side of the
-- computer; the game spins when that side's ANALOG level hits SPIN_LEVEL. Run `slot test` to find the
-- monitor name + lever side, then set config below. Stake selection needs no wiring (touch the screen).
-- Re-host + re-import after editing (HTTP snapshot).

-- ---- config ----------------------------------------------------------------
local TOP_NAME   = "top"     -- the 1x2 portrait monitor (side name if touching, else monitor_N)
local TOP_SCALE  = 0.5
local SPIN_SIDE  = "back"    -- computer side the lever's redstone feeds
local SPIN_LEVEL = 13        -- spin when analog signal on SPIN_SIDE reaches this (lever ramps to 15)
-- Stake ($10/$25/$100) is selected by TAPPING the on-screen stake buttons (monitor_touch). No wiring.
-- Selection persists across spins and resets to $10 whenever the station goes idle (fresh play()).
local ZONE = "all"  -- proximity zone this station answers to. "all" = any player in the hub's range.
-- ----------------------------------------------------------------------------

local args = { ... }

local subpixel = require("subpixel")
local SYMBOLS  = require("slot_symbols")
local logic    = require("slot_logic")
local font     = require("pixelfont")
local STAKES   = require("slot_pay").STAKES   -- {10, 25, 100} — single source of truth for the ladder

local RED, YELLOW, GREEN, WHITE, BLACK, GREY = 16384, 16, 8192, 1, 32768, 128
local MAGENTA, GRAY = 4, 128                   -- stake buttons: selected magenta, others gray
local SYM_W, SYM_H = 8, 9
local SYMBOL_PX = SYM_H                          -- snug: each symbol fills exactly 3 cells (no gap)

-- Animated background: these unused colour slots get redefined at runtime to a drifting
-- deep-blue <-> teal gradient (see updateGradient). None collide with the symbol/UI colours.
local GRAD = { 2048, 512, 8, 1024, 64 }
local GRAD_DEEP = { 0.00, 0.10, 0.65 }
local GRAD_TEAL = { 0.00, 0.75, 0.65 }

local function findMon(name)
  local m = peripheral.wrap(name)
  if not m or peripheral.getType(name) ~= "monitor" then
    error(("Monitor '%s' not found. Run `slot test` to list names, then edit config."):format(name), 0)
  end
  return m
end

-- Fixed 15x24 (30x72 subpixel) layout from the mockup. Cell row r -> top subpixel = (r-1)*3+1.
-- Header (native text) row 2; WIN: label rows 4-5; big amount rows 6-7 (nudged up 1px); top red bar
-- rows 8-9; reel 3x3 rows 11-19 (middle row 14-16 black, others gradient); bottom red bar rows 21-22;
-- stake buttons rows 23-24. Bulbs frame the reel (top/bottom bars + side lanes cols 1 & 15).
local function Rl(row) return (row - 1) * 3 + 1 end
-- stake button regions (subpixels): $10 cols 1-4, $25 cols 6-10, $100 cols 12-15 (gaps at col 5 & 11)
local STAKE_X = { 1, 11, 23 }   -- 1-indexed subpixel left edge
local STAKE_W = { 8, 10, 8 }
local STAKE_COL = { 1, 6, 12 }  -- cell column of each button
local STAKE_WC  = { 4, 5, 4 }   -- cell width of each button
local function topLayout()
  return {
    xs        = { 3, 11, 19 },              -- 3 reels, 8 subpx wide, cols 2-13
    winLblY   = Rl(4),                       -- "WIN:" label (rows 4-5)
    amtY      = Rl(6) - 1,                    -- win amount, nudged up 1 subpx (clears WIN: + top bar)
    topBarY   = Rl(8),  topBarH = 6,          -- top red bar (rows 8-9)
    reelTop   = Rl(11), reelBot = Rl(19) + 2, -- reel window (rows 11-19)
    midTop    = Rl(14), midBot = Rl(16) + 2,  -- black middle band (payline row, rows 14-16)
    paylineY  = Rl(14),                       -- middle symbol top
    botBarY   = Rl(21), botBarH = 6,          -- bottom red bar (rows 21-22)
    stakeY    = Rl(23),                       -- stake buttons (rows 23-24)
    sideTop   = Rl(9),  sideBot = Rl(21) + 2, -- side bulb lanes (cols 1 & 15, rows 9-21)
  }
end

-- draw a sprite but only rows inside [yMin, yMax] — clips reel symbols to the reel window
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

-- one reel: 3 symbols rolling downward, clipped to the window; pos==0 lands final on the payline
local function drawReel(cv, x, reel, L)
  local n = logic.NUM_SYMBOLS
  local base = math.floor(reel.pos / SYMBOL_PX)
  for i = base - 1, base + 2 do
    local idx = ((reel.final - 1 + i) % n + n) % n + 1
    drawSpriteClipped(cv, x, L.paylineY + reel.pos - i * SYMBOL_PX, SYMBOLS[idx], L.reelTop, L.reelBot)
  end
end

-- a bulb: on = bright yellow, off = dim grey (blinks by seed+tick parity)
local function bulb(cv, x, y, seed, bulbTick)
  cv:fillRect(x, y, 2, 2, ((seed + bulbTick) % 2 == 0) and YELLOW or GREY)
end

-- draw the whole subpixel layer (everything except the native cell-text overlays)
local function drawTop(cv, reels, bulbTick, result, stakeIdx, dispAmt)
  local L = topLayout()
  -- gradient bands across the whole canvas (palette-driven; recoloured for free each tick)
  local bandH = math.ceil(cv.h / #GRAD)
  for b = 1, #GRAD do cv:fillRect(1, 1 + (b - 1) * bandH, cv.w, bandH, GRAD[b]) end
  -- reel: ONLY the middle band is black; top & bottom symbol rows ride the gradient
  cv:fillRect(1, L.midTop, cv.w, L.midBot - L.midTop + 1, BLACK)
  for i = 1, 3 do drawReel(cv, L.xs[i], reels[i], L) end
  -- red frame bars — flash yellow on a win (BARS ONLY, not the symbols)
  local barCol = (result == "win" and bulbTick % 2 == 0) and YELLOW or RED
  cv:fillRect(1, L.topBarY, cv.w, L.topBarH, barCol)
  cv:fillRect(1, L.botBarY, cv.w, L.botBarH, barCol)
  -- stake row: on a result the OUTCOME OVERLAY (green/red) covers it; otherwise gray row + magenta selected
  if result == "win" or result == "lose" then
    cv:fillRect(1, L.stakeY, cv.w, 6, result == "win" and GREEN or RED)
  else
    cv:fillRect(1, L.stakeY, cv.w, 6, GRAY)
    cv:fillRect(STAKE_X[stakeIdx], L.stakeY, STAKE_W[stakeIdx], 6, MAGENTA)
  end
  -- bulbs: a row on each frame bar + vertical lanes down cols 1 & 15
  for x = 2, cv.w - 2, 4 do
    bulb(cv, x, L.topBarY + 2, math.floor(x / 4), bulbTick)
    bulb(cv, x, L.botBarY + 2, math.floor(x / 4), bulbTick)
  end
  for y = L.sideTop, L.sideBot, 4 do
    bulb(cv, 1, y, math.floor(y / 4), bulbTick)
    bulb(cv, cv.w - 1, y, math.floor(y / 4), bulbTick)
  end
  -- WIN: label + big count-up amount (custom subpixel fonts)
  font.drawCentered(cv, font.WIN, "WIN:", L.winLblY, WHITE, 1)
  font.drawCentered(cv, font.BIG, tostring(dispAmt or 0), L.amtY, WHITE, 1)
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
      term.setCursorPos(1, math.max(1, row)); term.clearLine()
      local parts = {}
      for _, s in ipairs(sides) do parts[#parts + 1] = ("%s=%2d"):format(s, redstone.getAnalogInput(s)) end
      io.write(table.concat(parts, "  ")); term.setCursorPos(1, row)
      timer = os.startTimer(0.2)
    elseif ev[1] == "key" and ev[2] == keys.q then
      print(""); return
    end
  end
end

if args[1] == "test" then
  testMode(); print("Test mode done."); return
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

-- one full frame: the subpixel layer, then native cell-text overlays (header, stake labels, outcome
-- word) — native text isn't subpixel, so it's written straight to the window like topWin.write.
local function drawTopFrame(reels, bulbTick, result, status, stakeIdx, dispAmt)
  local L = topLayout()
  topWin.setVisible(false)
  drawTop(topCv, reels, bulbTick, result, stakeIdx, dispAmt)
  -- header (row 2): "<id>: <bal> MB", or INSUFFICIENT / FREE PLAY. bg = gradient slot so it rides it.
  local hdr
  if status.denied then hdr = "INSUFFICIENT"
  elseif status.player then hdr = ("%s: %d MB"):format(status.player, status.balance or 0)
  else hdr = "FREE PLAY" end
  topWin.setTextColor(WHITE); topWin.setBackgroundColor(GRAD[1])
  topWin.setCursorPos(math.max(1, math.floor((tw - #hdr) / 2) + 1), 2); topWin.write(hdr)
  -- stake row: outcome word on a result, otherwise the three "$<n>" labels (native, in the top cell)
  if result == "win" or result == "lose" then
    local word = (result == "win") and "WIN" or "Loss"
    topWin.setTextColor(WHITE); topWin.setBackgroundColor(result == "win" and GREEN or RED)
    topWin.setCursorPos(math.floor((tw - #word) / 2) + 1, 23); topWin.write(word)
  else
    for i = 1, #STAKES do
      local sel = (i == stakeIdx)
      local lbl = "$" .. STAKES[i]
      topWin.setTextColor(sel and BLACK or WHITE)
      topWin.setBackgroundColor(sel and MAGENTA or GRAY)
      topWin.setCursorPos(STAKE_COL[i] + math.floor((STAKE_WC[i] - #lbl) / 2), 23); topWin.write(lbl)
    end
  end
  topWin.setVisible(true)
end

local function newSpin()
  local a, b, c = logic.pickFinals(rng)
  return { logic.newReel(a, 12), logic.newReel(b, 20), logic.newReel(c, 28) }
end

local function restorePalette()
  for i = 1, #GRAD do
    local o = gradOrig[i]
    topMon.setPaletteColour(GRAD[i], o[1], o[2], o[3])
  end
end

-- map a monitor touch (cell col) to a stake index, or nil if not on the stake row
local function stakeAt(tx, ty)
  if ty < 23 then return nil end
  if tx <= 5 then return 1 elseif tx <= 10 then return 2 else return 3 end
end

-- ACTIVE session: the 0.05s timer loop (attract -> spinning -> result), run by idle_runner while a
-- player is present. Returns "sleep" when the zone empties in attract, or "quit" on the operator's Q.
local function play(mon, pres)
  local state = "attract"
  local econ = require("sp_econ").new{ zone = ZONE, pay = require("slot_pay") }
  local reels = newSpin(); for _, r in ipairs(reels) do r.stopped = true end
  local tick, spinTick, resultAt, result = 0, 0, nil, nil
  local armed = true                     -- rising-edge guard so a held lever doesn't auto-respin
  local stakeIdx = 1                     -- selected stake ($10); a play()-local, so it resets on wake
  local dispAmt, wonTarget = 0, 0        -- win-amount count-up: dispAmt eases toward wonTarget

  updateGradient(0)
  drawTopFrame(reels, 0, nil, econ.status(), stakeIdx, dispAmt)
  local timer = os.startTimer(TICK)

  while true do
    local ev = { os.pullEvent() }
    if ev[1] == "timer" and ev[2] == timer then
      tick = tick + 1
      updateGradient(tick * 0.05)

      local lvl = redstone.getAnalogInput(SPIN_SIDE)
      if state == "attract" and armed and lvl >= SPIN_LEVEL then
        local mode = econ.tryBet(STAKES[stakeIdx])   -- "staked" | "free" | "deny"
        if mode == "deny" then
          armed = false                              -- consume the pull; header shows INSUFFICIENT
        else
          reels = newSpin()
          state, spinTick, armed = "spinning", 0, false
          dispAmt, wonTarget = 0, 0
        end
      end
      if lvl < SPIN_LEVEL then armed = true end

      if state == "spinning" then
        spinTick = spinTick + 1
        local allStopped = true
        for _, r in ipairs(reels) do
          if not logic.stepReel(r, spinTick, SYMBOL_PX) then allStopped = false end
        end
        drawTopFrame(reels, tick, nil, econ.status(), stakeIdx, dispAmt)
        if allStopped then
          result = logic.isWin(reels[1].final, reels[2].final, reels[3].final) and "win" or "lose"
          wonTarget = econ.settle({ reels[1].final, reels[2].final, reels[3].final })
          dispAmt = 0
          drawTopFrame(reels, tick, result, econ.status(), stakeIdx, dispAmt)
          state, resultAt = "result", tick
        end
      elseif state == "result" then
        if wonTarget > 0 and dispAmt < wonTarget then
          dispAmt = math.min(wonTarget, dispAmt + math.max(1, math.ceil(wonTarget / 24)))  -- count up
        end
        drawTopFrame(reels, tick, result, econ.status(), stakeIdx, dispAmt)
        if tick - resultAt > 40 then                 -- ~2s result window, then back to attract
          result, dispAmt, wonTarget = nil, 0, 0
          state = "attract"
          drawTopFrame(reels, tick, nil, econ.status(), stakeIdx, dispAmt)
        end
      else -- attract
        drawTopFrame(reels, tick, nil, econ.status(), stakeIdx, dispAmt)
        if pres.gone() then restorePalette(); return "sleep" end
      end

      timer = os.startTimer(TICK)
    elseif ev[1] == "rednet_message" then
      pres.fromEvent(ev); econ.onEvent(ev)
    elseif ev[1] == "disk" or ev[1] == "disk_eject" then
      econ.onEvent(ev)                               -- card inserted/removed: re-read balance
    elseif ev[1] == "monitor_touch" then
      local sIdx = stakeAt(ev[3], ev[4])             -- tap a stake button to select (idle only)
      if state == "attract" and sIdx then
        stakeIdx = sIdx
        drawTopFrame(reels, tick, nil, econ.status(), stakeIdx, dispAmt)
      end
    elseif ev[1] == "key" and ev[2] == keys.q then
      restorePalette(); return "quit"
    end
  end
end

require("idle_runner").run{
  name = "slot", monitor = topMon, zone = ZONE,
  wake = { side = SPIN_SIDE, level = SPIN_LEVEL }, play = play,
}
