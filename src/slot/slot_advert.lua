-- slot_advert.lua — the slot machine's static idle advertisement (COME PLAY / GET MONEY).
-- Drawn ONCE by idle_runner while the zone is empty. Default palette colours only; no animation.
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
  center("COME PLAY", math.floor(h / 2), colors.yellow)
  center("GET MONEY", math.floor(h / 2) + 1, colors.white)
end

return M
