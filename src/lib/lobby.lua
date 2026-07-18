-- lobby.lua — the lobby screen for a multiplayer match: seats, per-seat READY, and a gated GO.
--
-- Drawn by match.lua; it owns no state. Hand it a plain view table and it paints; hand it a touch
-- and hitTest tells you what was hit. That split is what lets the whole screen be tested with a
-- stub window and no monitor.
--
-- DEBUG-GRADE NATIVE TEXT, ON PURPOSE. The art pass for all three screens is a separate effort
-- against the spec's UI contract (kb/monitor-ui-workflow.md). Do not decorate this yet.
--
-- Canvas: 3x2 blocks @ setTextScale(0.5) = 57x24 cells (kb/monitor-resolution.md).
local M = {}

-- ---- layout (cells, 1-indexed) ---------------------------------------------
-- FROM THE APPROVED DESIGN (tools/pong-preview.html), generated from the same constants that page
-- draws with. Rendering below is debug-grade native text, but these RECTS ARE FINAL: hit-testing is
-- built once and verified in-world once, and the art pass changes only how things are drawn.
-- Everything mirrors about the net: col c <-> col 58-c.
M.W, M.H = 57, 24

M.NET_X = 29                          -- the net is this column and NO other
M.GUARD_X0, M.GUARD_X1 = 28, 30       -- enforced no-native-text band (net + its two gutters)
M.GUARD_Y0, M.GUARD_Y1 = 5, 17        -- union across the lobby (8-17) and results (5-16) nets

M.TITLE_Y = 2
M.MSG_Y   = 23
M.BAND_Y, M.BAND_H = 8, 10            -- the lobby's seat band: rows 8-17

M.READY = {
  { x = 13, w = 15, y = 12, h = 6 },  -- LEFT  : cols 13-27, rows 12-17
  { x = 31, w = 15, y = 12, h = 6 },  -- RIGHT : cols 31-45, rows 12-17
}

-- ONE rect, shared by the lobby and the results screen ON PURPOSE: the rematch button must be the
-- same button in the same place, so muscle memory carries between the two screens.
M.GO = { x = 21, w = 17, y = 18, h = 5 }   -- cols 21-37, rows 18-22

-- The outer info columns. RIGHT is right-aligned, so its text ENDS at col 56.
M.INFO = {
  { x = 2,  w = 11, align = "left"  },   -- cols 2-12
  { x = 46, w = 11, align = "right" },   -- cols 46-56
}
M.ID_MAX = 11   -- exact: the info column's usable width. READY starts at col 13, so 12 is the last.

local function inRect(r, x, y)
  return x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h
end
M.inRect = inRect

-- monitor_touch has NO release event, so nothing here is a press-and-hold; a tap is the whole
-- interaction and every "pressed" look in this project is a timed flash.
-- Returns "ready", seatIndex | "go", nil | nil.
-- The results screen calls this with nSeats = 0 to test GO alone.
function M.hitTest(x, y, nSeats)
  for i = 1, math.min(nSeats or 0, #M.READY) do
    if inRect(M.READY[i], x, y) then return "ready", i end
  end
  if inRect(M.GO, x, y) then return "go", nil end
  return nil
end

-- ---- drawing ---------------------------------------------------------------
local function writeAt(win, x, y, text, fg, bg)
  win.setCursorPos(x, y)
  win.setTextColor(fg)
  win.setBackgroundColor(bg)
  win.write(text)
end

-- Write into an info column, honouring its alignment and the id cap. Native `write` sets the whole
-- cell's background, so a string that crossed col 29 would ERASE a cell of net per row -- these
-- columns are the outer ones precisely so that can never happen.
local function infoWrite(win, i, y, text, fg)
  local col = M.INFO[i]
  if not col or not text or text == "" then return end
  text = text:sub(1, col.w)
  local x = (col.align == "right") and (M.W - #text) or col.x
  writeAt(win, x, y, text, fg, colors.black)
end
M.infoWrite = infoWrite

-- Fill a rect with a background colour: the fill IS the button, not a coloured word.
local function fillRect(win, r, bg)
  win.setBackgroundColor(bg)
  local line = string.rep(" ", r.w)
  for dy = 0, r.h - 1 do
    win.setCursorPos(r.x, r.y + dy)
    win.write(line)
  end
end
M.fillRect = fillRect

-- A label centred inside a rect, drawn over its fill.
local function centerIn(win, r, text, fg, bg)
  text = text:sub(1, r.w)
  writeAt(win, r.x + math.floor((r.w - #text) / 2), r.y + math.floor((r.h - 1) / 2), text, fg, bg)
end
M.centerIn = centerIn

-- The dashed centre spine. Cell column 29 only -- it is the machine's identity and the mirror line.
local function drawNet(win, y0, y1)
  win.setBackgroundColor(colors.white)
  for y = y0, y1, 2 do
    win.setCursorPos(M.NET_X, y)
    win.write(" ")
  end
  win.setBackgroundColor(colors.black)
end
M.drawNet = drawNet

-- view = {
--   title, ante, goEnabled, message,
--   seats = { { label, id, balance, status, ready }, ... },
-- }
function M.draw(win, view)
  win.setVisible(false)                       -- buffer the whole frame: no flicker
  win.setBackgroundColor(colors.black)
  win.setTextColor(colors.white)
  win.clear()

  writeAt(win, 2, M.TITLE_Y, view.title, colors.white, colors.black)
  local ante = ("ANTE $%d"):format(view.ante or 0)
  writeAt(win, M.W - #ante, M.TITLE_Y, ante, colors.yellow, colors.black)

  drawNet(win, M.BAND_Y, M.BAND_Y + M.BAND_H - 1)

  for i, s in ipairs(view.seats) do
    local r = M.READY[i]
    if r then
      infoWrite(win, i, M.BAND_Y,     s.label, colors.lightGray)
      infoWrite(win, i, M.BAND_Y + 1, (s.id or "anon"):sub(1, M.ID_MAX),
                s.id and colors.white or colors.gray)

      -- A status word REPLACES the balance. There is no number worth showing when the hub did not
      -- answer, and a stale one reads as truth.
      local money = s.status or (s.balance and ("$" .. s.balance)) or ""
      infoWrite(win, i, M.BAND_Y + 2, money, s.status and colors.pink or colors.white)

      -- READY latched = lime; not ready = steel. Colour AND (in the art pass) depth.
      fillRect(win, r, s.ready and colors.lime or colors.gray)
      centerIn(win, r, "READY", s.ready and colors.black or colors.lightGray,
               s.ready and colors.lime or colors.gray)
    end
  end

  if view.message then
    writeAt(win, 2, M.MSG_Y, view.message:sub(1, M.W - 2), colors.pink, colors.black)
  end

  -- THE GATE. This button spends real money, so inert and live differ in fill, text colour AND the
  -- word itself -- a player must never tap a GO that looks live and be told no.
  fillRect(win, M.GO, view.goEnabled and colors.yellow or colors.gray)
  centerIn(win, M.GO, view.goEnabled and "GO" or "WAITING",
           view.goEnabled and colors.black or colors.lightGray,
           view.goEnabled and colors.yellow or colors.gray)

  win.setVisible(true)
end

return M
