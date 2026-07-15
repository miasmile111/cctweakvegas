-- slot_logic.lua — pure reel/win logic (no CC globals; RNG injected). Testable under luajit.
-- A reel scrolls continuously (pos grows by speed each tick), then once past its stopTick it
-- DECELERATES and snaps to a stop with pos aligned to 0 — that ease-out sells the "reel slowing
-- down" look. The landed symbol is reel.final (unchanged by the animation); win eval uses it.
local L = {}
L.NUM_SYMBOLS = 4

local SPIN_SPEED0 = 4      -- initial scroll speed (subpixels per tick)
local DECAY       = 0.75   -- speed multiplier each tick once past stopTick (ease-out)
local MIN_SPEED   = 0.6    -- once speed drops below this, snap to a full stop

function L.newReel(finalSymbol, stopTick)
  return { final = finalSymbol, stopTick = stopTick, pos = 0, speed = SPIN_SPEED0, stopped = false }
end

-- advance one tick; symbolPx = pixel height of one symbol slot (kept for the renderer's pos wrap)
function L.stepReel(reel, tick, symbolPx)
  if reel.stopped then return true end
  if tick >= reel.stopTick then
    reel.speed = reel.speed * DECAY
    if reel.speed < MIN_SPEED then
      reel.pos = 0            -- align so the payline lands exactly on reel.final
      reel.stopped = true
    else
      reel.pos = reel.pos + reel.speed
    end
  else
    reel.pos = reel.pos + reel.speed
  end
  return reel.stopped
end

function L.isWin(a, b, c)
  return a == b and b == c
end

function L.pickFinals(rng)
  local function pick() return 1 + math.floor(rng() * L.NUM_SYMBOLS) end
  return pick(), pick(), pick()
end

return L
