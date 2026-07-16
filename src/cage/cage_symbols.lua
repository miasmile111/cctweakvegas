-- cage_symbols.lua — the cage's metals as subpixel sprite data (0 = transparent). 8x9 = 4x3 cells,
-- the project's standard symbol size (see slot_symbols, whose idiom this copies).
--
-- Colours are NUMERIC LITERALS, not colors.* — exactly as slot_symbols does it — so this module
-- loads under bare luajit for the offline PNG render harness and the unit tests. Do not "improve"
-- them into colors.orange; that breaks the harness.
--
-- ONE COLOUR PER SPRITE, deliberately. A sprite pixel plus the panel fill behind it is already the
-- 2 colours a cell can hold; a highlight would be a 3rd and encodeCell would eat it (see
-- [[monitor-ui]]). These read as flat metal silhouettes because that is what the hardware allows.
local W, H = 8, 9
local ORANGE, LIGHT_GRAY, YELLOW, LIGHT_BLUE = 2, 256, 16, 8   -- colours.orange/lightGray/yellow/lightBlue

local INGOT = { "________", "__####__", "_######_", "########",
                "########", "########", "_######_", "________", "________" }
local GEM   = { "________", "__####__", "_######_", "########",
                "_######_", "__####__", "___##___", "________", "________" }

-- build a single-colour sprite from H strings of W chars: "#" = on, anything else = transparent
local function make(rows, color)
  local px = {}
  for y = 1, H do
    local line = rows[y]
    for x = 1, W do px[(y - 1) * W + x] = (line:sub(x, x) == "#") and color or 0 end
  end
  return { w = W, h = H, px = px }
end

local M = {}
M.SPRITES = {
  copper  = make(INGOT, ORANGE),
  iron    = make(INGOT, LIGHT_GRAY),
  gold    = make(INGOT, YELLOW),
  diamond = make(GEM,   LIGHT_BLUE),
}

return M
