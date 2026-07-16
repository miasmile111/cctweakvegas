package.path = "src/?.lua;test/?.lua;" .. package.path
local t = require("runner")
local I = require("idle_logic")

-- presenceFor: matches my zone, "all", ignores others / non-presence
t.eq(I.presenceFor({ kind = "presence", zone = "all", present = true }, "slot1"), true,
  "zone 'all' present=true -> true")
t.eq(I.presenceFor({ kind = "presence", zone = "all", present = false }, "slot1"), false,
  "zone 'all' present=false -> false")
t.eq(I.presenceFor({ kind = "presence", zone = "slot1", present = true }, "slot1"), true,
  "my zone -> true")
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

t.done()
