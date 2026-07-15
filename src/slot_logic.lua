-- slot_logic.lua — pure reel/win logic (no CC globals; RNG injected). Testable under luajit.
local L = {}
L.NUM_SYMBOLS = 4
local SPIN_SPEED = 3   -- subpixels of blur scroll per tick while spinning

function L.newReel(finalSymbol, stopTick)
  return { final = finalSymbol, stopTick = stopTick, offset = 0, stopped = false }
end

function L.stepReel(reel, tick, symbolPx)
  if reel.stopped then return true end
  if tick >= reel.stopTick then
    reel.offset = 0
    reel.stopped = true
  else
    reel.offset = (reel.offset + SPIN_SPEED) % symbolPx
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
