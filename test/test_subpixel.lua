package.path = "src/lib/?.lua;test/?.lua;" .. package.path
local t = require("runner")
local sub = require("subpixel")

local WHITE, BLACK = 1, 32768   -- 2^0, 2^15

-- uniform cell -> solid char 128, fg == bg
do
  local ch, fg, bg = sub.encodeCell({ WHITE, WHITE, WHITE, WHITE, WHITE, WHITE })
  t.eq(ch, string.char(128), "uniform -> char 128")
  t.eq(fg, bg, "uniform -> fg == bg")
  t.eq(bg, "0", "uniform white -> blit '0'")
end

-- only top-left differs -> char 129, fg = differing color
do
  local ch, fg, bg = sub.encodeCell({ BLACK, WHITE, WHITE, WHITE, WHITE, WHITE })
  t.eq(ch, string.char(129), "top-left -> char 129")
  t.eq(fg, "f", "top-left fg = black 'f'")
  t.eq(bg, "0", "top-left bg = white '0'")
end

-- only bottom-right differs -> inversion path -> char 159, colors swapped
do
  local ch, fg, bg = sub.encodeCell({ WHITE, WHITE, WHITE, WHITE, WHITE, BLACK })
  t.eq(ch, string.char(159), "bottom-right -> char 159 (inverted)")
  t.eq(fg, "0", "inverted fg = white '0'")
  t.eq(bg, "f", "inverted bg = black 'f'")
end

t.done()
