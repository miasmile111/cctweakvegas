-- pixelfont.lua — tiny subpixel bitmap fonts for the slot machine: the "WIN:" label and the big
-- "slashed" number font for the win amount. Pure (no CC globals, so it unit-tests under luajit);
-- draws into any canvas exposing setPixel(x, y, color) — e.g. src/lib/subpixel. 1-indexed coords.
-- Glyphs are rows of strings; "#" = on (drawn in `color`), anything else = off (skipped).
local M = {}

-- "WIN:" label — the owner's exact drawing (W 5x4, I 3x4, N 4x4, colon 1x4), see docs/mockups.
M.WIN = {
  W    = { "#...#", "#.#.#", "#.#.#", ".#.#." },
  I    = { "###",   ".#.",   ".#.",   "###"   },
  N    = { "#..#",  "##.#",  "#.##",  "#..#"  },
  [":"] = { ".",    "#",     ".",     "#"     },
}

-- big "slashed" digits (4 wide x 6 tall) for the win amount — the owner drew the "0"; 1-9 match it.
M.BIG = {
  ["0"] = { "####", "#..#", "#.##", "##.#", "#..#", "####" },
  ["1"] = { ".##.", "..#.", "..#.", "..#.", "..#.", "..#." },
  ["2"] = { "####", "...#", "####", "#...", "#...", "####" },
  ["3"] = { "####", "...#", ".###", "...#", "...#", "####" },
  ["4"] = { "#..#", "#..#", "####", "...#", "...#", "...#" },
  ["5"] = { "####", "#...", "####", "...#", "...#", "####" },
  ["6"] = { "####", "#...", "####", "#..#", "#..#", "####" },
  ["7"] = { "####", "...#", "..#.", ".#..", ".#..", ".#.." },
  ["8"] = { "####", "#..#", "####", "#..#", "#..#", "####" },
  ["9"] = { "####", "#..#", "####", "...#", "...#", "####" },
}

local function glyphW(font, ch)
  local g = font[ch]
  return g and #g[1] or 0
end

-- total pixel width of a string in `font` with `gap` blank subpixels between glyphs
function M.textWidth(font, str, gap)
  gap = gap or 1
  local w = 0
  for i = 1, #str do w = w + glyphW(font, str:sub(i, i)) + gap end
  return w - gap
end

function M.drawGlyph(cv, font, ch, x, y, color)
  local g = font[ch]
  if not g then return end
  for r = 1, #g do
    local row = g[r]
    for c = 1, #row do
      if row:sub(c, c) == "#" then cv:setPixel(x + c - 1, y + r - 1, color) end
    end
  end
end

function M.drawText(cv, font, str, x, y, color, gap)
  gap = gap or 1
  local cx = x
  for i = 1, #str do
    local ch = str:sub(i, i)
    M.drawGlyph(cv, font, ch, cx, y, color)
    cx = cx + glyphW(font, ch) + gap
  end
end

-- draw horizontally centered across the whole canvas width (cv.w)
function M.drawCentered(cv, font, str, y, color, gap)
  gap = gap or 1
  local w = M.textWidth(font, str, gap)
  M.drawText(cv, font, str, math.floor((cv.w - w) / 2) + 1, y, color, gap)
end

return M
