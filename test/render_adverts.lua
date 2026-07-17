-- render_adverts.lua — offline PNG verify ([[monitor-ui-workflow]] step 5). Draws the REAL advert
-- code against a stub monitor and dumps what the real monitor would show, with NO game and no
-- deploy. Run: luajit test/render_adverts.lua   then: python tools/render_adverts.py
--
-- Dumps through encodeCell, NOT the raw cv.buf: a cell holds at most 2 colours, and the raw buffer
-- hides every straddle/squash bug because it has not been collapsed yet. That is how a stray bulb
-- once survived a PNG check.
package.path = "src/lib/?.lua;src/slot/?.lua;src/cage/?.lua;test/?.lua;" .. package.path

-- Minimal CC globals the advert code touches. pixelfont/slot_style are pure, but cage_advert uses
-- `colors` and subpixel's render() calls blit on the target.
_G.colors = { black = 32768, red = 16384, white = 1, lightGray = 256, yellow = 16, gray = 128 }

local stub     = require("stub_target")
local subpixel = require("subpixel")

-- Capture the canvas that draw() builds. subpixel.new reads target.getSize(), so a stub of the right
-- CELL size yields a canvas of the right SUBPIXEL size -- the sizes are the thing under test.
local realNew = subpixel.new
local captured
subpixel.new = function(target) captured = realNew(target); return captured end

local function dump(name, cols, rows, mod)
  captured = nil
  local target = stub.new(cols, rows)
  require(mod).draw(target)
  assert(captured, mod .. " never built a subpixel canvas")
  local cv = captured

  -- Collapse to monitor truth: per cell, encodeCell gives the char + the 2 colours it can actually
  -- show. We re-expand to per-subpixel colours so the PNG shows exactly what the monitor shows.
  local out = io.open(name .. ".txt", "w")
  out:write(("%d %d\n"):format(cv.w, cv.h))
  local truth = {}
  for y = 1, cv.h do truth[y] = {} end
  local BITS = { 1, 2, 4, 8, 16 }
  local function unhex(h) return 2 ^ (("0123456789abcdef"):find(h, 1, true) - 1) end
  for cy = 0, rows - 1 do
    for cx = 0, cols - 1 do
      local c = {}
      for i = 0, 5 do
        local dy, dx = math.floor(i / 2), i % 2
        c[i + 1] = cv.buf[cy * 3 + dy + 1][cx * 2 + dx + 1]
      end
      local ch, fg, bg = subpixel.encodeCell(c)
      local F, B = unhex(fg), unhex(bg)   -- encodeCell returns blit hex, not colour numbers

      -- DECODE FROM THE CHAR'S BITMASK, NOT BY COMPARING COLOURS. encodeCell has an INVERT branch
      -- (when subpixel 6 is the foreground it flips the mask and swaps F/B), and on that branch a
      -- cell holding a THIRD colour displays bg where a naive `c[i] == F` test says fg. A 3-colour
      -- cell is exactly the squashed-bulb case this render exists to catch, so a decode that is
      -- wrong there is blind to its own reason for existing. The char is the ground truth:
      -- bit i set -> subpixel i shows F; subpixel 6 ALWAYS shows B (true on both branches).
      local code = string.byte(ch) - 128
      for i = 1, 5 do
        local dy, dx = math.floor((i - 1) / 2), (i - 1) % 2
        local set = (math.floor(code / BITS[i]) % 2) == 1
        truth[cy * 3 + dy + 1][cx * 2 + dx + 1] = set and F or B
      end
      truth[cy * 3 + 3][cx * 2 + 2] = B
    end
  end
  for y = 1, cv.h do
    local row = {}
    for x = 1, cv.w do row[x] = tostring(truth[y][x]) end
    out:write(table.concat(row, ",") .. "\n")
  end
  out:close()
  print(("wrote %s.txt  (%dx%d subpixels, %d native writes)"):format(name, cv.w, cv.h, #target.writes))
end

dump("slot-advert", 15, 24, "slot_advert")
dump("cage-advert", 36, 24, "cage_advert")
