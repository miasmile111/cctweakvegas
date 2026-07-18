-- counter.lua — an eased, direction-tinted number. Pure: no peripherals, no drawing, no colours.
--
-- Extracted from cage.lua, where a balance that merely SNAPPED to its new value read as a glitch.
-- Easing it over ~24 frames and tinting it by direction turns a number into feedback: the player
-- reads "being paid" / "spending" before reading the digits.
--
--   local c = counter.new{ value = 100 }
--   c.setTarget(90); c.step(); c.value(); c.tint()   --> 90-ish, "down"
--
-- tint() returns SYMBOLS, not colours: this module runs under bare luajit in tests, where the CC
-- `colors` global does not exist. The caller maps "up"->yellow, "down"->pink, "rest"->white.
-- PINK, not red: stock red is luminance 114 against the cage's ~118 gold band, so a red number
-- vanishes on half the gradient drift -- and a cell holds only 2 colours, so no outline can save it.
local M = {}

local RAMP = 24   -- frames to close a gap; the slot's win count-up uses the same ramp

-- Step `cur` one frame toward `target`. Clamps, so it can never overshoot -- an overshoot would
-- show the player a balance they never had.
function M.easeToward(cur, target)
  if cur == target then return cur end
  local step = math.max(1, math.ceil(math.abs(target - cur) / RAMP))
  if cur < target then return math.min(target, cur + step) end
  return math.max(target, cur - step)
end

-- cfg.value = the starting (and initial target) value. Defaults to 0.
function M.new(cfg)
  cfg = cfg or {}
  local start = cfg.value or 0
  local self = { _v = start, _t = start }

  function self.setTarget(n) self._t = n end
  function self.step()       self._v = M.easeToward(self._v, self._t) end
  function self.value()      return self._v end
  function self.target()     return self._t end
  function self.atRest()     return self._v == self._t end

  function self.tint()
    if self._v < self._t then return "up"   end   -- climbing: gold
    if self._v > self._t then return "down" end   -- falling: pink
    return "rest"                                 -- white
  end

  return self
end

return M
