local M = {}
function M.new(cols, rows)
  local t = { calls = {}, _cols = cols, _rows = rows }
  function t.getSize() return t._cols, t._rows end
  function t.setCursorPos(x, y) t._x, t._y = x, y end
  function t.blit(text, fg, bg) t.calls[#t.calls + 1] = { y = t._y, text = text, fg = fg, bg = bg } end
  function t.setBackgroundColor() end
  function t.setTextColor() end
  function t.setTextScale() end
  function t.clear() end
  function t.setVisible() end

  -- Additive for the advert harness: adverts write native text and set palette slots.
  t.writes   = {}
  t.palette  = {}
  function t.write(s) t.writes[#t.writes + 1] = { x = t._x, y = t._y, text = s } end
  function t.setPaletteColour(slot, r, g, b) t.palette[slot] = { r, g, b } end
  t.setPaletteColor = t.setPaletteColour
  return t
end
return M
