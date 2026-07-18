-- test_counter.lua — the eased delta-tinted counter (extracted from cage.lua).
-- The tint IS the feedback: a player reads "being paid" / "spending" before reading the digits.
package.path = "src/lib/?.lua;test/?.lua;" .. package.path
local t = require("runner")
local counter = require("counter")

-- ---- easeToward: the raw ramp ----
do
  t.eq(counter.easeToward(10, 10), 10, "at rest, easeToward is a fixed point")
  t.ok(counter.easeToward(0, 100) > 0, "climbs toward a higher target")
  t.ok(counter.easeToward(100, 0) < 100, "falls toward a lower target")
  t.eq(counter.easeToward(0, 1), 1, "a 1-unit gap closes in one step, never overshoots")
  t.eq(counter.easeToward(1, 0), 0, "a 1-unit fall closes in one step")
end

-- ---- convergence: it must ALWAYS arrive, and never pass the target ----
do
  local c = counter.new{ value = 100 }
  c.setTarget(90)
  local n = 0
  while not c.atRest() and n < 500 do c.step(); n = n + 1 end
  t.eq(c.value(), 90, "a falling counter converges exactly on the target")
  t.ok(n < 500, "convergence terminates (it did not spin)")
end

do
  local c = counter.new{ value = 90 }
  c.setTarget(110)
  local n = 0
  while not c.atRest() and n < 500 do c.step(); n = n + 1 end
  t.eq(c.value(), 110, "a climbing counter converges exactly on the target")
end

-- Overshoot is the failure that matters: a counter that sails past the target and eases back
-- shows the player a balance they never had.
do
  local c = counter.new{ value = 0 }
  c.setTarget(1000)
  for _ = 1, 500 do
    c.step()
    t.ok(c.value() <= 1000, "climbing never exceeds the target")
    if c.atRest() then break end
  end
end

-- ---- tint ----
do
  local c = counter.new{ value = 100 }
  t.eq(c.tint(), "rest", "equal value and target reads at rest (white)")
  c.setTarget(110)
  t.eq(c.tint(), "up", "climbing tints up (gold)")
  c.setTarget(90)
  t.eq(c.tint(), "down", "falling tints down (pink, not red)")
  c.setTarget(100)
  t.eq(c.tint(), "rest", "returning to the current value reads at rest again")
end

-- ---- a fresh counter starts at rest on its own value ----
do
  local c = counter.new{ value = 42 }
  t.eq(c.value(), 42, "value() is the seeded value")
  t.eq(c.target(), 42, "target defaults to the seeded value")
  t.ok(c.atRest(), "a fresh counter is at rest")
  c.step()
  t.eq(c.value(), 42, "stepping an at-rest counter changes nothing")
end

-- ---- defaults ----
do
  local c = counter.new()
  t.eq(c.value(), 0, "no cfg defaults to 0")
end

t.done()
