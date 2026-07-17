package.path = "src/lib/?.lua;src/slot/?.lua;src/pong/?.lua;test/?.lua;" .. package.path
local t = require("runner")
local I = require("idle_logic")

-- presenceFor: a zone name means what it says. "all" is NOT a wildcard -- it is the literal zone an
-- unregistered station answers to, which is why the floor-wide broadcast still reaches those and
-- ONLY those.
t.eq(I.presenceFor({ kind = "presence", zone = "all", present = true }, "all"), true,
  "unregistered station (zone 'all') wakes on the floor-wide broadcast")
t.eq(I.presenceFor({ kind = "presence", zone = "all", present = false }, "all"), false,
  "...and sleeps on it")
t.eq(I.presenceFor({ kind = "presence", zone = "all", present = true }, 5), nil,
  "REGISTERED station (zone 5) IGNORES the floor-wide broadcast -- a player at the hub must NOT wake it")
t.eq(I.presenceFor({ kind = "presence", zone = 5, present = true }, 5), true,
  "registered station wakes on its OWN zone")
t.eq(I.presenceFor({ kind = "presence", zone = 5, present = false }, 5), false,
  "...and sleeps on its own zone")
t.eq(I.presenceFor({ kind = "presence", zone = 7, present = true }, 5), nil,
  "another station's zone -> nil (ignore)")
t.eq(I.presenceFor({ kind = "presence", zone = "slot1", present = true }, "slot1"), true,
  "a pinned string zone still works")
t.eq(I.presenceFor({ kind = "presence", zone = "slot2", present = true }, "slot1"), nil,
  "other zone -> nil (ignore)")
t.eq(I.presenceFor({ kind = "register" }, "slot1"), nil, "non-presence msg -> nil")
t.eq(I.presenceFor("hello", "slot1"), nil, "non-table msg -> nil")

-- occupancyChanged: edge detection with bool coercion
t.ok(I.occupancyChanged(false, true), "empty->occupied changed")
t.ok(I.occupancyChanged(true, false), "occupied->empty changed")
t.ok(not I.occupancyChanged(false, false), "empty->empty no change")
t.ok(not I.occupancyChanged(true, true), "occupied->occupied no change")
t.ok(not I.occupancyChanged(nil, false), "nil treated as false -> no change")

-- shouldSleep: only from attract, only when absent
t.ok(I.shouldSleep(false, "attract"), "absent + attract -> sleep")
t.ok(not I.shouldSleep(true, "attract"), "present + attract -> stay")
t.ok(not I.shouldSleep(false, "spinning"), "absent mid-spin -> do NOT sleep (finish round)")
t.ok(not I.shouldSleep(false, "result"), "absent on result -> do NOT sleep yet")

-- leverRose: rising edge across the threshold only
t.ok(I.leverRose(0, 13, 13), "0 -> 13 (thr 13) rose")
t.ok(not I.leverRose(13, 15, 13), "already high -> no new edge")
t.ok(not I.leverRose(0, 12, 13), "below threshold -> no edge")
t.ok(not I.leverRose(15, 0, 13), "falling -> no edge")

-- isPresenceQuery: identifies a station's presence request (vs a presence broadcast)
t.ok(I.isPresenceQuery({ kind = "presence?" }), "presence? query recognized")
t.ok(not I.isPresenceQuery({ kind = "presence", present = true }), "presence broadcast is not a query")
t.ok(not I.isPresenceQuery("nope"), "non-table is not a query")

-- newPresence: a handle that tracks presence from incoming rednet events
do
  local pr = I.newPresence("slot1")
  t.ok(pr.present, "newPresence starts present")
  t.ok(not pr.gone(), "not gone initially")
  pr.fromEvent({ "rednet_message", 5, { kind = "presence", zone = "slot1", present = false }, "ccvegas" })
  t.ok(not pr.present, "present=false msg on MY zone -> not present")
  t.ok(pr.gone(), "gone() true after leave")
  pr.fromEvent({ "rednet_message", 5, { kind = "presence", zone = "slot1", present = true }, "ccvegas" })
  t.ok(pr.present, "present=true msg on MY zone -> present again")
  pr.fromEvent({ "rednet_message", 5, { kind = "presence", zone = "slot2", present = false }, "ccvegas" })
  t.ok(pr.present, "other-zone msg ignored")
  pr.fromEvent({ "rednet_message", 5, { kind = "presence", zone = "all", present = false }, "ccvegas" })
  t.ok(pr.present, "floor-wide 'all' broadcast is NOT a wildcard -- a pinned-zone station ignores it")
  pr.fromEvent({ "timer", 1 })
  t.ok(pr.present, "non-presence event ignored")
end

t.done()
