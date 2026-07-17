-- slot_style.lua — the slot station's shared visual kit: the animated gradient's palette slots and
-- ramp, the bulb, and the colour numbers. Required by BOTH slot.lua (the play screen) and
-- slot_advert.lua (the idle screen) so the idle face and the play face cannot drift apart — before
-- this, these constants lived only in slot.lua and the advert had no way to look like the machine.
--
-- Pure (no CC globals): gradientRGB returns numbers rather than calling setPaletteColour, because
-- slot.lua sets the palette on TWO targets (the monitor and its window) and this module has no
-- business knowing that. Keeps it unit-testable under luajit.
local M = {}

M.RED, M.YELLOW, M.GREEN, M.WHITE, M.BLACK, M.GREY = 16384, 16, 8192, 1, 32768, 128
M.GRAY = 128   -- alias: slot.lua's stake buttons spell it this way

-- Unused colour slots, redefined at runtime to a drifting deep-blue <-> teal gradient.
-- None collide with the symbol/UI colours above.
M.GRAD = { 2048, 512, 8, 1024, 64 }
M.GRAD_DEEP = { 0.00, 0.10, 0.65 }
M.GRAD_TEAL = { 0.00, 0.75, 0.65 }

-- The ramp for band `i` at `phase`, as r, g, b in 0..1. Each band is offset a little around the
-- sine so the five slots read as a moving gradient rather than five blocks pulsing in lockstep.
-- Callers do their own setPaletteColour (see the header).
function M.gradientRGB(i, phase)
  local a = 0.5 + 0.5 * math.sin(phase + i * 0.9)
  return M.GRAD_DEEP[1] + (M.GRAD_TEAL[1] - M.GRAD_DEEP[1]) * a,
         M.GRAD_DEEP[2] + (M.GRAD_TEAL[2] - M.GRAD_DEEP[2]) * a,
         M.GRAD_DEEP[3] + (M.GRAD_TEAL[3] - M.GRAD_DEEP[3]) * a
end

-- Paint the 5 gradient bands across the whole canvas. math.ceil so the last band overshoots rather
-- than leaving an unpainted stripe at the bottom (setPixel bounds-checks, so overshoot is free).
function M.bandFill(cv)
  local bandH = math.ceil(cv.h / #M.GRAD)
  for b = 1, #M.GRAD do cv:fillRect(1, 1 + (b - 1) * bandH, cv.w, bandH, M.GRAD[b]) end
end

-- A bulb: on = bright yellow, off = dim grey (blinks by seed+tick parity). A static screen passes
-- bulbTick = 0 and gets a fixed on/off pattern from the seed alone.
function M.bulb(cv, x, y, seed, bulbTick)
  cv:fillRect(x, y, 2, 2, ((seed + bulbTick) % 2 == 0) and M.YELLOW or M.GREY)
end

return M
