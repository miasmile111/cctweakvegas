package.path = "src/lib/?.lua;src/slot/?.lua;src/pong/?.lua;test/?.lua;" .. package.path
local t = require("runner")
local L = require("slot_logic")

-- win check
t.ok(L.isWin(3, 3, 3), "three equal -> win")
t.ok(not L.isWin(3, 3, 2), "one different -> lose")

-- reel scrolls, then decelerates past stopTick to a full stop with pos snapped to 0
do
  local reel = L.newReel(2, 5)   -- final symbol 2, begins decelerating at tick 5
  t.eq(reel.pos, 0, "new reel: pos 0")
  t.ok(not reel.stopped, "new reel: spinning")
  local stopped = L.stepReel(reel, 3, 11)   -- before stopTick
  t.ok(not stopped, "before stopTick: still spinning")
  t.ok(reel.pos > 0, "before stopTick: pos advanced")
  -- keep stepping past stopTick until it eases to a stop (guard against a runaway loop)
  local guard = 0
  while not reel.stopped and guard < 100 do L.stepReel(reel, 10, 11); guard = guard + 1 end
  t.ok(reel.stopped, "decelerates to a stop after stopTick")
  t.ok(guard > 0 and guard < 100, "stop takes a few easing ticks, not instant or infinite")
  t.eq(reel.pos, 0, "on stop: pos snapped to 0")
end

-- pickFinals maps rng [0,1) into 1..NUM_SYMBOLS
do
  local seq = { 0.0, 0.999, 0.5 }
  local i = 0
  local rng = function() i = i + 1; return seq[i] end
  local a, b, c = L.pickFinals(rng)
  t.eq(a, 1, "rng 0.0 -> symbol 1")
  t.eq(b, L.NUM_SYMBOLS, "rng ~1 -> last symbol")
  t.ok(c >= 1 and c <= L.NUM_SYMBOLS, "rng mid -> in range")
end

-- symbols are well-formed sprites, one per logic symbol
do
  local S = require("slot_symbols")
  t.eq(#S, L.NUM_SYMBOLS, "one sprite per symbol")
  for i = 1, #S do
    t.ok(S[i].w > 0 and S[i].h > 0, "sprite " .. i .. " has size")
    t.eq(#S[i].px, S[i].w * S[i].h, "sprite " .. i .. " px count == w*h")
  end
end

t.done()
