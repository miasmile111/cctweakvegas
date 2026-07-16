-- slot_logic.lua — pure reel/win logic (no CC globals; RNG injected). Testable under luajit.
-- A reel scrolls at a constant speed, then once past its stopTick it EASES (never snaps) into the
-- nearest position AHEAD where reel.final lands on the payline. reel.final is centred exactly when
-- pos is a multiple of NUM_SYMBOLS*symbolPx, so easing to that multiple lands cleanly with no
-- rubber-band jump. reel.final is unchanged by the animation; win eval uses it.
local L = {}
L.NUM_SYMBOLS = 4

local SPIN_SPEED = 4      -- constant scroll speed while spinning (subpixels per tick)
local EASE       = 0.28   -- ease-out: fraction of the remaining distance covered per tick when landing
local MIN_SPEED  = 0.6    -- minimum crawl so the reel always reaches its target
local SNAP       = 0.75   -- within this many subpixels of the target -> land exactly on it (sub-pixel)

function L.newReel(finalSymbol, stopTick)
  return { final = finalSymbol, stopTick = stopTick, pos = 0, speed = SPIN_SPEED, stopped = false, target = nil }
end

-- advance one tick; symbolPx = pixel height of one symbol slot (the renderer wraps pos by it)
function L.stepReel(reel, tick, symbolPx)
  if reel.stopped then return true end
  if tick < reel.stopTick then
    reel.pos = reel.pos + reel.speed             -- constant-speed spin
    return false
  end
  -- past the stop tick: pick an aligned target once, then ease into it (always moving forward)
  if not reel.target then
    local period = L.NUM_SYMBOLS * symbolPx       -- pos values a full symbol-cycle apart re-centre final
    reel.target = math.ceil((reel.pos + symbolPx) / period) * period   -- next final-aligned stop, ahead
  end
  local dist = reel.target - reel.pos
  if dist <= SNAP then
    reel.pos = reel.target                        -- final now sits exactly on the payline
    reel.stopped = true
  else
    reel.pos = reel.pos + math.max(MIN_SPEED, dist * EASE)   -- ease-out toward the target
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
