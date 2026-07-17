-- pixelfont.lua — tiny subpixel bitmap fonts, shared across stations: the slot's "WIN:" label and
-- big "slashed" number font, plus the cage's SIGN_SM/SIGN_LG "$" glyphs. Pure (no CC globals, so it
-- unit-tests under luajit); draws into any canvas exposing setPixel(x, y, color) — e.g.
-- src/lib/subpixel. 1-indexed coords.
-- Glyphs are rows of strings; "#" = on (drawn in `color`), anything else = off (skipped).
local M = {}

-- "WIN:" label — the owner's exact drawing (W 5x4, I 3x4, N 4x4, colon 1x4), see docs/mockups.
M.WIN = {
  W    = { "#...#", "#.#.#", "#.#.#", ".#.#." },
  I    = { "###",   ".#.",   ".#.",   "###"   },
  N    = { "#..#",  "##.#",  "#.##",  "#..#"  },
  [":"] = { ".",    "#",     ".",     "#"     },
}

-- The big square font: 6 rows tall, base 4 wide (M/W are 5), full-width top/bottom
-- bars, 1px stems, square corners. The owner drew the "0" (slashed, so 0 ~= O); 1-9
-- were extrapolated from it and are in-world verified -- DO NOT REDRAW THEM.
-- A-Z + punctuation extrapolated from the same style, 2026-07-17.
--
-- Letters and digits share ONE table on purpose: drawText takes a single `font`, so a
-- mixed string ("COPPER $25", "WIN 100") is only possible if they live together. It
-- also means slot.lua's and cage.lua's existing BIG call sites need no change.
M.BIG = {
  -- digits (owner-drawn "0"; 1-9 match it). Shipped + verified -- do not touch.
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

  -- letters
  ["A"] = { "####", "#..#", "####", "#..#", "#..#", "#..#" },
  ["B"] = { "###.", "#..#", "###.", "#..#", "#..#", "###." },
  ["C"] = { "####", "#...", "#...", "#...", "#...", "####" },
  ["D"] = { "###.", "#..#", "#..#", "#..#", "#..#", "###." },
  ["E"] = { "####", "#...", "####", "#...", "#...", "####" },
  ["F"] = { "####", "#...", "####", "#...", "#...", "#..." },
  ["G"] = { "####", "#...", "#.##", "#..#", "#..#", "####" },
  ["H"] = { "#..#", "#..#", "####", "#..#", "#..#", "#..#" },
  ["I"] = { "####", ".##.", ".##.", ".##.", ".##.", "####" },
  ["J"] = { "####", "..#.", "..#.", "..#.", "#.#.", ".##." },
  ["K"] = { "#..#", "#.#.", "##..", "##..", "#.#.", "#..#" },
  ["L"] = { "#...", "#...", "#...", "#...", "#...", "####" },
  -- M and W are the only 5-wide letters: at 4 they have no interior column and read
  -- as blobs against N. pixelfont is variable-width already, so this costs nothing.
  ["M"] = { "#...#", "##.##", "#.#.#", "#...#", "#...#", "#...#" },
  ["N"] = { "#..#", "##.#", "##.#", "#.##", "#.##", "#..#" },
  ["O"] = { "####", "#..#", "#..#", "#..#", "#..#", "####" },
  ["P"] = { "####", "#..#", "####", "#...", "#...", "#..." },
  -- Q's tail pokes out of the bottom-right instead of costing a 5th column. The cost
  -- is a 5-row bowl where every other letter's body is 6, so Q reads slightly short.
  -- Accepted (no advert copy has a Q); first glyph to redraw if the owner dislikes it.
  ["Q"] = { "####", "#..#", "#..#", "#.##", "####", "...#" },
  ["R"] = { "####", "#..#", "####", "##..", "#.#.", "#..#" },
  -- S is CHAMFERED top-left and bottom-right. A naive square S is byte-identical to
  -- the "5" above; this is the same disambiguation the slashed "0" does for 0-vs-O.
  ["S"] = { ".###", "#...", "####", "...#", "...#", "###." },
  ["T"] = { "####", ".##.", ".##.", ".##.", ".##.", ".##." },
  ["U"] = { "#..#", "#..#", "#..#", "#..#", "#..#", "####" },
  ["V"] = { "#..#", "#..#", "#..#", "#..#", ".##.", ".##." },
  ["W"] = { "#...#", "#...#", "#...#", "#.#.#", "##.##", "#...#" },
  ["X"] = { "#..#", "#..#", ".##.", ".##.", "#..#", "#..#" },
  -- Y's stem is 2 wide: a 1-wide stem under a 4-wide top is off-centre in an even box.
  ["Y"] = { "#..#", "#..#", ".##.", ".##.", ".##.", ".##." },
  ["Z"] = { "####", "...#", "..#.", ".#..", "#...", "####" },

  -- punctuation
  ["!"] = { "#", "#", "#", "#", ".", "#" },
  [":"] = { ".", "#", ".", ".", "#", "." },
  ["-"] = { "....", "....", "####", "....", "....", "...." },
  ["."] = { ".", ".", ".", ".", ".", "#" },
  [","] = { "..", "..", "..", "..", ".#", "#." },

  -- THE SPACE IS 3 WIDE, NOT 4, AND IT IS LOAD-BEARING. At 4, "METAL IN" @2x measures
  -- 73 against the cage's 72-subpixel canvas and the copy would have to change; at 3 it
  -- is 71. (A space narrower than a letter is ordinary typography anyway.) It must also
  -- EXIST: glyphW returns 0 for a missing glyph, so before this, drawText advanced a
  -- single subpixel for a space and words ran together.
  [" "] = { "...", "...", "...", "...", "...", "..." },
}

local function glyphW(font, ch)
  local g = font[ch]
  return g and #g[1] or 0
end

-- The owner's hand-drawn $ glyphs — TWO SIZES, NOT two scales. `scale` doubles pixels; SIGN_LG is
-- separately drawn with detail a scaled SIGN_SM could never have. Keep both; scale is orthogonal.
--   SIGN_SM 5x10 (mockup(3).json) — pairs with 1x digits.
--   SIGN_LG 7x14 (mockup(4).json) — thicker, stem overshooting. Pairs with BIG @2x (12 tall):
--     14 vs 12 overshoots a subpixel above and below, which is how a $ sits against figures.
M.SIGN_SM = {
  ["$"] = { "..#..", ".###.", "#.#.#", "#.#..", ".##..", "..##.", "..#.#", "#.#.#", ".###.", "..#.." },
}
M.SIGN_LG = {
  ["$"] = { "...#...", "...#...", "..###..", ".#####.", "##.#.#.", "##.#...", ".####..",
            "..####.", "...#.##", "##.#.##", ".#####.", "..###..", "...#...", "...#..." },
}

-- total pixel width of a string in `font`: glyphs scaled by `scale`, `gap` blank subpixels between
-- (gap is NOT scaled — it is raw subpixels). scale defaults to 1, gap to 1.
function M.textWidth(font, str, gap, scale)
  gap, scale = gap or 1, scale or 1
  local w = 0
  for i = 1, #str do w = w + glyphW(font, str:sub(i, i)) * scale + gap end
  return w - gap
end

-- at scale s, each glyph pixel becomes an s x s block (nearest-neighbour, no smoothing)
function M.drawGlyph(cv, font, ch, x, y, color, scale)
  scale = scale or 1
  local g = font[ch]
  if not g then return end
  for r = 1, #g do
    local row = g[r]
    for c = 1, #row do
      if row:sub(c, c) == "#" then
        for dy = 0, scale - 1 do
          for dx = 0, scale - 1 do
            cv:setPixel(x + (c - 1) * scale + dx, y + (r - 1) * scale + dy, color)
          end
        end
      end
    end
  end
end

function M.drawText(cv, font, str, x, y, color, gap, scale)
  gap, scale = gap or 1, scale or 1
  local cx = x
  for i = 1, #str do
    local ch = str:sub(i, i)
    M.drawGlyph(cv, font, ch, cx, y, color, scale)
    cx = cx + glyphW(font, ch) * scale + gap
  end
end

-- draw horizontally centered across the whole canvas width (cv.w)
function M.drawCentered(cv, font, str, y, color, gap, scale)
  gap, scale = gap or 1, scale or 1
  local w = M.textWidth(font, str, gap, scale)
  M.drawText(cv, font, str, math.floor((cv.w - w) / 2) + 1, y, color, gap, scale)
end

return M
