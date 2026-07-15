-- subpixel.lua — reusable CC:Tweaked teletext canvas.
-- Each character cell (chars 128-159) encodes a 2x3 subpixel block: the char's
-- FOREGROUND color fills the "on" subpixels, BACKGROUND the "off" ones. Any 2x3
-- block is thus 2 colors. Pure at load (no CC globals) so it tests under luajit;
-- render() binds to a passed-in monitor/term target.
local M = {}

local BLIT = "0123456789abcdef"
-- Precomputed reverse map: colour number (power of two, 2^0..2^15) -> blit hex digit.
-- O(1) lookup with no loop, so this never trips CC's "too long without yielding" watchdog
-- the way the old per-cell while-loop did when render() called it hundreds of times a frame.
local COLOR_HEX = {}
do
  local p = 1
  for i = 0, 15 do COLOR_HEX[p] = BLIT:sub(i + 1, i + 1); p = p * 2 end
end
local function toBlit(color)
  return COLOR_HEX[color] or "0"   -- fallback keeps table.concat safe on an unexpected value
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

local Canvas = {}
Canvas.__index = Canvas

function M.new(target)
  local cols, rows = target.getSize()
  local self = setmetatable({}, Canvas)
  self.target = target
  self.cols, self.rows = cols, rows
  self.w, self.h = cols * 2, rows * 3
  self.buf = {}
  self:clear(32768)   -- black
  return self
end

function Canvas:clear(color)
  -- reuse existing row tables instead of allocating fresh ones every frame (less GC churn)
  for y = 1, self.h do
    local row = self.buf[y]
    if not row then row = {}; self.buf[y] = row end
    for x = 1, self.w do row[x] = color end
  end
end

function Canvas:getPixel(x, y)
  local row = self.buf[y]
  return row and row[x] or nil
end

function Canvas:setPixel(x, y, color)
  x, y = math.floor(x), math.floor(y)   -- tolerate fractional coords (e.g. eased scroll positions)
  if x < 1 or y < 1 or x > self.w or y > self.h then return end
  self.buf[y][x] = color
end

function Canvas:fillRect(x, y, w, h, color)
  for dy = 0, h - 1 do
    for dx = 0, w - 1 do self:setPixel(x + dx, y + dy, color) end
  end
end

-- sprite = { w=, h=, px = { row-major color numbers, 0 = transparent } }
function Canvas:drawSprite(x, y, sprite)
  for dy = 0, sprite.h - 1 do
    for dx = 0, sprite.w - 1 do
      local col = sprite.px[dy * sprite.w + dx + 1]
      if col and col ~= 0 then self:setPixel(x + dx, y + dy, col) end
    end
  end
end

function Canvas:render()
  local tgt = self.target
  for cy = 1, self.rows do
    local py = (cy - 1) * 3            -- top subpixel row of this cell
    local text, fg, bg = {}, {}, {}
    for cx = 1, self.cols do
      local px = (cx - 1) * 2
      local cell = {
        self.buf[py + 1][px + 1], self.buf[py + 1][px + 2],
        self.buf[py + 2][px + 1], self.buf[py + 2][px + 2],
        self.buf[py + 3][px + 1], self.buf[py + 3][px + 2],
      }
      local ch, f, b = M.encodeCell(cell)
      text[cx], fg[cx], bg[cx] = ch, f, b
    end
    tgt.setCursorPos(1, cy)
    tgt.blit(table.concat(text), table.concat(fg), table.concat(bg))
  end
end

return M
