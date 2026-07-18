-- test_lobby.lua — the lobby screen: hit testing and drawing onto a stub window.
--
-- The assertion that matters most is the GO gate: that button moves real money, so "inert" and
-- "live" must be different pixels, not just different behaviour.
package.path = "src/lib/?.lua;test/?.lua;" .. package.path
local t = require("runner")

-- CC's `colors` global does not exist under luajit. lobby.lua is a DRAWING module, so unlike the
-- pure modules it legitimately references it; the shim gives each colour a distinct number so the
-- tests can assert that two states render differently.
colors = {
  black = 1, white = 2, gray = 3, lightGray = 4,
  green = 5, yellow = 6, pink = 7, red = 8,
  lime = 9, lightBlue = 10, orange = 11,
}

local lobby = require("lobby")

-- A window stub that records what was written and in what colours.
local function stubWin()
  local w = { _writes = {}, _bg = 0, _fg = 0, _visible = true }
  function w.getSize() return 57, 24 end
  function w.setVisible(v) w._visible = v end
  function w.setBackgroundColor(c) w._bg = c end
  function w.setTextColor(c) w._fg = c end
  function w.clear() w._writes = {} end
  function w.setCursorPos(x, y) w._x, w._y = x, y end
  function w.write(s)
    w._writes[#w._writes + 1] = { x = w._x, y = w._y, text = s, bg = w._bg, fg = w._fg }
    w._x = (w._x or 1) + #s
  end
  function w.find(pattern)
    for _, e in ipairs(w._writes) do
      if tostring(e.text):find(pattern, 1, true) then return e end
    end
    return nil
  end
  function w.at(x, y)
    for _, e in ipairs(w._writes) do
      if e.x == x and e.y == y then return e end
    end
    return nil
  end
  return w
end

-- ---- the geometry is the DESIGN's, not a convenience ----
-- These numbers come from tools/pong-preview.html. Rendering stays debug-grade this session but the
-- touch rects are final, so hit-testing is built once and verified in-world once.
do
  t.eq(lobby.READY[1].x, 13, "seat 1 READY starts at col 13")
  t.eq(lobby.READY[1].w, 15, "and is 15 cells wide")
  t.eq(lobby.READY[1].y, 12, "on row 12")
  t.eq(lobby.READY[1].h, 6,  "and 6 rows tall -- a 1-row button cannot bevel and is a poor target")
  t.eq(lobby.READY[2].x, 31, "seat 2 READY starts at col 31")
  t.eq(lobby.GO.x, 21, "GO starts at col 21")
  t.eq(lobby.GO.w, 17, "and is 17 cells wide")
  t.eq(lobby.GO.y, 18, "on row 18")
  t.eq(lobby.GO.h, 5,  "and 5 rows tall")
  t.eq(lobby.ID_MAX, 11, "an id truncates to the info column's exact width")
end

-- Everything mirrors about the net: col c <-> col 58-c. If this ever fails, one seat has drifted.
do
  t.eq(lobby.READY[1].x + lobby.READY[1].w - 1, 58 - lobby.READY[2].x,
       "the READY buttons are exact mirrors about the net")
  t.eq(lobby.GO.x + lobby.GO.w - 1, 58 - lobby.GO.x, "GO mirrors onto itself")
  -- cols 2-12 mirrors to cols 46-56: the OUTER edge of one maps to the OUTER edge of the other.
  t.eq(58 - lobby.INFO[1].x, lobby.INFO[2].x + lobby.INFO[2].w - 1,
       "LEFT's outer edge (col 2) mirrors to RIGHT's outer edge (col 56)")
  t.eq(58 - (lobby.INFO[1].x + lobby.INFO[1].w - 1), lobby.INFO[2].x,
       "LEFT's inner edge (col 12) mirrors to RIGHT's inner edge (col 46)")
  t.eq(lobby.INFO[1].w, lobby.INFO[2].w, "both info columns are the same width")
end

-- ---- hit testing ----
do
  local kind, i = lobby.hitTest(13, 12, 2)
  t.eq(kind, "ready", "the top-left cell of seat 1's button is a ready toggle")
  t.eq(i, 1, "for seat 1")

  kind, i = lobby.hitTest(27, 17, 2)
  t.eq(kind, "ready", "the bottom-right cell of seat 1's button still hits")
  t.eq(i, 1, "still seat 1")

  kind, i = lobby.hitTest(45, 17, 2)
  t.eq(kind, "ready", "seat 2's far corner hits")
  t.eq(i, 2, "for seat 2")

  t.eq(lobby.hitTest(28, 14, 2), nil, "the gutter between seat 1's button and the net is a miss")
  t.eq(lobby.hitTest(12, 14, 2), nil, "one cell left of seat 1's button is a miss")
  t.eq(lobby.hitTest(13, 11, 2), nil, "the row above the button is a miss")
  t.eq(lobby.hitTest(13, 18, 2), nil, "row 18 below seat 1's button is a miss -- GO starts at col 21")
  t.eq(lobby.hitTest(13, 12, 1), "ready", "seat 1 still hits at a 1-seat station")
  t.eq(lobby.hitTest(31, 12, 1), nil, "but seat 2's rect is dead there -- nSeats gates it")
end

do
  t.eq(lobby.hitTest(21, 18, 2), "go", "GO's top-left hits")
  t.eq(lobby.hitTest(37, 22, 2), "go", "GO's bottom-right hits")
  t.eq(lobby.hitTest(20, 20, 2), nil, "just left of GO is a miss")
  t.eq(lobby.hitTest(38, 20, 2), nil, "just right of GO is a miss")
  t.eq(lobby.hitTest(29, 23, 2), nil, "below GO is a miss")
  t.eq(lobby.hitTest(1, 1, 2), nil, "the title area is not a button")

  -- GO is checked with nSeats = 0 by the results screen, which has no READY buttons.
  t.eq(lobby.hitTest(29, 20, 0), "go", "GO still hits when there are no seat buttons")
  t.eq(lobby.hitTest(13, 14, 0), nil, "and READY does not")
end

-- ---- drawing ----
local function view(over)
  local v = {
    title = "PONG", ante = 10, goEnabled = false, message = nil,
    seats = {
      { label = "LEFT",  id = "alice", balance = 120, ready = false },
      { label = "RIGHT", id = nil,     balance = nil, ready = false },
    },
  }
  for k, x in pairs(over or {}) do v[k] = x end
  return v
end

do
  local w = stubWin()
  lobby.draw(w, view())
  t.ok(w.find("PONG"), "the title is drawn")
  t.ok(w.find("ANTE $10"), "the ante is drawn, with a $")
  t.ok(w.find("LEFT"), "seat 1's label is drawn")
  t.ok(w.find("RIGHT"), "seat 2's label is drawn")
  t.ok(w.find("alice"), "a carded seat shows its id")
  t.ok(w.find("120"), "and its balance")
  t.ok(w.find("anon"), "a cardless seat reads as anon, never as an empty gap")
  t.ok(w.find("READY"), "the ready buttons are drawn")
  -- The default view has goEnabled = false, so the button legitimately says WAITING, not GO --
  -- same reasoning as the dedicated GO GATE block below.
  t.ok(w.find("WAITING"), "the GO button is drawn, inert by default")
end

do
  -- A hub-unreachable seat must say so rather than showing a stale or absent number.
  local v = view()
  v.seats[1].status = "OFFLINE"
  v.seats[1].balance = nil
  local w = stubWin()
  lobby.draw(w, v)
  t.ok(w.find("OFFLINE"), "a status word replaces the balance when there is no number to trust")
end

do
  local w = stubWin()
  lobby.draw(w, view{ message = "HUB OFFLINE - nobody charged" })
  t.ok(w.find("HUB OFFLINE"), "the deny message is drawn when present")
end

-- THE GO GATE. This button spends real money, so inert and live must be unmistakably different --
-- different fill AND different words. Compare the fill BY POSITION, not by searching for the text:
-- the inert button deliberately says WAITING, so a text search for "GO" finds nothing and indexing
-- the nil result crashes. (That is exactly what the first draft of this test did.)
do
  local inert, live = stubWin(), stubWin()
  lobby.draw(inert, view{ goEnabled = false })
  lobby.draw(live,  view{ goEnabled = true })

  local a = inert.at(lobby.GO.x, lobby.GO.y)
  local b = live.at(lobby.GO.x, lobby.GO.y)
  t.ok(a ~= nil and b ~= nil, "the GO button's fill is drawn in both states")
  t.ok(a.bg ~= b.bg, "an inert GO and a live GO have DIFFERENT fills -- this button spends real money")
  t.ok(inert.find("WAITING") ~= nil, "the inert button says WAITING")
  t.eq(inert.find("GO"), nil, "and an inert lobby never shows the word GO at all")
  t.ok(live.find("GO") ~= nil, "the live button says GO")
end

do
  -- A ready seat must be distinguishable from a not-ready one.
  local off, on = stubWin(), stubWin()
  local v = view(); v.seats[1].ready = true
  lobby.draw(off, view())
  lobby.draw(on, v)
  local a, b = off.find("READY"), on.find("READY")
  t.ok(a.bg ~= b.bg or a.fg ~= b.fg, "a READY seat renders differently from a not-ready one")
end

-- ---- flicker discipline: draw must buffer ----
do
  local w = stubWin()
  local seq = {}
  w.setVisible = function(v) seq[#seq + 1] = v end
  lobby.draw(w, view())
  t.eq(seq[1], false, "draw hides the window before painting (no flicker)")
  t.eq(seq[#seq], true, "and shows it once at the end")
end

-- ---- an over-long card id is CAPPED ----
-- ID_MAX is the info column's exact width (cols 2-12). The READY button starts at col 13, one cell
-- past it, so an uncapped id would run straight into the button. Nothing asserted the drawn result
-- before this: every other test used a 5-character id.
do
  local v = view()
  v.seats[1].id = "bartholomew-the-longwinded"
  local w = stubWin()
  lobby.draw(w, v)
  local e = w.at(lobby.INFO[1].x, lobby.BAND_Y + 1)
  t.ok(e ~= nil, "the id is drawn at the left info column's origin")
  t.ok(e ~= nil and #e.text <= lobby.ID_MAX,
       "an over-long id is capped to ID_MAX -- an uncapped one would spill into the READY button")
end

t.done()
