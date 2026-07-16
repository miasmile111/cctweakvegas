-- pong_advert.lua — pong's static idle advertisement. Drawn ONCE by idle_runner while empty.
-- Default palette colours only; no animation.
local M = {}

function M.draw(mon)
  local w, h = mon.getSize()
  mon.setBackgroundColor(colors.black)
  mon.clear()
  local function center(text, y, fg)
    mon.setTextColor(fg)
    mon.setCursorPos(math.floor((w - #text) / 2) + 1, y)
    mon.write(text)
  end
  center("P O N G", math.floor(h / 2) - 1, colors.white)
  center("STEP ON A PLATE", math.floor(h / 2) + 1, colors.yellow)
end

return M
