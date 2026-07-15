-- subpixel.lua — reusable CC:Tweaked teletext canvas.
-- Each character cell (chars 128-159) encodes a 2x3 subpixel block: the char's
-- FOREGROUND color fills the "on" subpixels, BACKGROUND the "off" ones. Any 2x3
-- block is thus 2 colors. Pure at load (no CC globals) so it tests under luajit;
-- render() binds to a passed-in monitor/term target.
local M = {}

local BLIT = "0123456789abcdef"
local function toBlit(color)   -- color is a power of two; hex digit = log2
  local n = 0
  while color > 1 do color = color / 2; n = n + 1 end
  return BLIT:sub(n + 1, n + 1)
end
M._toBlit = toBlit

-- c = { topL, topR, midL, midR, botL, botR } color numbers -> char, fgHex, bgHex
function M.encodeCell(c)
  -- pick most frequent color as background
  local counts = {}
  for i = 1, 6 do counts[c[i]] = (counts[c[i]] or 0) + 1 end
  local bg, best = c[1], -1
  for col, n in pairs(counts) do if n > best then best, bg = n, col end end
  -- foreground = first color that isn't bg (uniform cell -> fg == bg)
  local fg = bg
  for i = 1, 6 do if c[i] ~= bg then fg = c[i]; break end end
  -- low5 bitmask over positions 1..5 (bits 1,2,4,8,16); position 6 is the invert anchor
  local bits = { 1, 2, 4, 8, 16 }
  local low5 = 0
  for i = 1, 5 do if c[i] == fg then low5 = low5 + bits[i] end end
  local char, F, B
  if c[6] == fg then          -- bottom-right is foreground -> invert so it becomes bg
    char = 128 + (31 - low5)
    F, B = bg, fg
  else
    char = 128 + low5
    F, B = fg, bg
  end
  return string.char(char), toBlit(F), toBlit(B)
end

return M
