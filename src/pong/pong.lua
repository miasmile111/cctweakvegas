-- pong.lua — 2-player Pong on a CC:Tweaked monitor, controlled by IN-WORLD PRESSURE PLATES.
--
--   Run:  pong        -> play (normally auto-run by the startup supervisor)
--   Run:  pong test   -> live input monitor, to find which plate feeds which relay side
--
-- Diegetic controls: each player stands on an "up" or "down" pressure plate. The plates feed a
-- REDSTONE RELAY (not the computer's own sides), so the wiring lives in pong.cfg and is read
-- through lib/controls.
--
-- COMMISSIONING A FRESH STATION (no pong.cfg yet): run `pong test`. It requires no mapping at
-- all -- it shows the raw state of all six sides of the resolved source, live. Step on each
-- plate, note which side lights up, then write pong.cfg from what you saw.
--
-- This file is deliberately small. The lobby, the ante, the pot, the results screen and the money
-- animation all live in lib/match (the reusable framework); the rally physics lives in pong_logic.
-- What is left here is the station's wiring and how a rally is drawn.
--
-- Waking: pong wakes on hub PRESENCE (GPS proximity) like every other station. It needs an ENDER
-- MODEM ON A COMPUTER SIDE to self-locate -- gps.locate scans rs.getSides() only, never the cable.
local controls = require("controls")
local pl       = require("pong_logic")
local match    = require("match")

-- ---- config ----------------------------------------------------------------
local TEXT_SCALE = 0.5    -- 3x2 blocks @ 0.5 = 57x24 cells
local TARGET     = 5      -- first to 5 takes the match
local INPUTS     = { "p1_up", "p1_down", "p2_up", "p2_down" }

-- ---- per-station wiring ----------------------------------------------------
-- pong.cfg is NOT in the package file list, so it survives `update pong` (which OVERWRITES
-- pong.lua). It is the ONLY place per-station wiring belongs. cfg always wins over discovery:
-- CC does not hand identically-built stations identical peripheral names.
--
--   source  = relay          # or a peripheral name, or "computer"
--   p1_up   = left           # P1 up    (left paddle)
--   p1_down = front          # P1 down
--   p2_up   = right          # P2 up    (right paddle)
--   p2_down = back           # P2 down
--   drives  = drive_0,drive_1   # seat order: left paddle first
--   ante    = 10
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

local CFG  = readCfg()
local ANTE = tonumber(CFG.ante) or 10

local mon = peripheral.find("monitor")
if not mon then
  error("No monitor found. Attach a monitor (directly or via a wired modem) and rerun.", 0)
end
mon.setTextScale(TEXT_SCALE)

local TEST_MODE = ({ ... })[1] == "test"

-- Fail loud at boot: a miswired station stops here naming what it could not find, rather than
-- running with a paddle that silently reads "not pressed" forever. Test mode is the one exception:
-- it exists to commission a station that has NO mapping yet, so it requires zero inputs.
local ctl = controls.new{ cfg = CFG, inputs = TEST_MODE and {} or INPUTS }

-- ===== TEST MODE: identify which physical plate feeds which input ============
local function testMode(ctl)
  local W, H = mon.getSize()
  local win = window.create(mon, 1, 1, W, H, true)
  local timer = os.startTimer(0.1)
  while true do
    local ev = { os.pullEvent() }
    if ev[1] == "timer" and ev[2] == timer then
      win.setVisible(false)
      win.setBackgroundColor(colors.black)
      win.setTextColor(colors.white)
      win.clear()
      win.setCursorPos(1, 1)
      win.write("INPUT TEST via " .. ctl.sourceName() .. "  (Q quits)")
      win.setCursorPos(1, 2)
      win.write("Step on a plate: watch which SIDE lights up.")

      -- The raw sides. This is the half that works with NO cfg at all -- it is how you discover
      -- the wiring in the first place.
      local row = 4
      for _, side in ipairs(ctl.sides()) do
        win.setCursorPos(1, row)
        win.write(("%-8s %s"):format(side, ctl.rawGet(side) and "[ON] " or "[   ]"))
        row = row + 1
      end

      -- The logical mapping, if pong.cfg already names one. Absent on a fresh station, which is
      -- fine -- that is the state this tool exists to get you out of.
      row = row + 1
      win.setCursorPos(1, row); win.write("pong.cfg mapping:"); row = row + 1
      local mapped = false
      for _, name in ipairs(INPUTS) do
        local side = CFG[name]
        if side then
          mapped = true
          win.setCursorPos(1, row)
          win.write(("  %-9s -> %-8s %s"):format(name, side,
                    ctl.rawGet(side) and "[ON] " or "[   ]"))
          row = row + 1
        end
      end
      if not mapped then
        win.setCursorPos(1, row)
        win.write("  (none yet -- write pong.cfg from the sides above)")
      end

      win.setVisible(true)
      timer = os.startTimer(0.1)
    elseif ev[1] == "key" and ev[2] == keys.q then
      return
    end
  end
end

if TEST_MODE then
  testMode(ctl)
  mon.setBackgroundColor(colors.black); mon.clear(); mon.setCursorPos(1, 1); mon.setTextScale(1)
  print("Test mode done.")
  return
end

-- ===== THE RALLY ============================================================
math.randomseed(os.epoch("utc"))

local function fill(win, x, y, w, h, color)
  win.setBackgroundColor(color)
  local line = string.rep(" ", w)
  for i = 0, h - 1 do
    win.setCursorPos(x, y + i)
    win.write(line)
  end
end

local function drawRally(win, s)
  win.setVisible(false)
  win.setBackgroundColor(colors.black)
  win.clear()
  for y = 1, s.H, 2 do fill(win, math.floor(s.W / 2), y, 1, 1, colors.white) end   -- the net
  fill(win, s.leftX,  s.lp, 1, s.paddleH, colors.white)
  fill(win, s.rightX, s.rp, 1, s.paddleH, colors.white)
  fill(win, pl.clamp(math.floor(s.bx), 1, s.W), pl.clamp(math.floor(s.by), 1, s.H), 1, 1, colors.white)

  win.setBackgroundColor(colors.black); win.setTextColor(colors.white)
  local txt = s.ls .. "  " .. s.rs
  win.setCursorPos(math.max(1, math.floor(s.W / 2 - #txt / 2)), 1)
  win.write(txt)
  win.setVisible(true)
end

-- The game, as match sees it: draw a frame, yield, repeat, hand back the scores.
-- NOTE: no os.pullEvent here, ever. match owns the pump; ctx.tick() is the only yield.
local function play(ctx)
  local W, H = ctx.win.getSize()
  local s = pl.newState(W, H, math.max(3, math.floor(H / 4)))
  pl.resetBall(s, math.random() < 0.5 and -1 or 1,
               pl.BALL_SPEED * (math.random() < 0.5 and -1 or 1))

  while not pl.isOver(s, ctx.target) do
    local lpv, rpv = 0, 0
    if ctl.get("p1_up")   then lpv = lpv - 1 end
    if ctl.get("p1_down") then lpv = lpv + 1 end
    if ctl.get("p2_up")   then rpv = rpv - 1 end
    if ctl.get("p2_down") then rpv = rpv + 1 end

    pl.step(s, lpv, rpv)
    drawRally(ctx.win, s)

    if not ctx.tick() then break end   -- the zone emptied or the player quit: abort, keep the score
  end

  return { [1] = s.ls, [2] = s.rs }
end

require("idle_runner").run{
  name = "pong", monitor = mon, zone = nil,
  play = match.run{
    title      = "PONG",
    seatLabels = { "LEFT", "RIGHT" },
    minSeats   = 2,
    maxSeats   = 2,
    ante       = ANTE,
    target     = TARGET,
    drives     = splitList(CFG.drives),
    controls   = ctl,
    play       = play,
  },
}
