package.path = "src/lib/?.lua;test/?.lua;" .. package.path
local t = require("runner")
local P = require("proximity")

local OVER, NETHER = "minecraft:overworld", "minecraft:the_nether"
local function st(x, y, z, extra)
  local s = { pos = { x = x, y = y, z = z } }
  for k, v in pairs(extra or {}) do s[k] = v end
  return s
end
local function pp(x, y, z, dim) return { x = x, y = y, z = z, dimension = dim or OVER } end

-- parsePos: the cfg escape hatch. Strings in, table out.
t.eq(P.parsePos("10,64,-20").x, 10, "parsePos x")
t.eq(P.parsePos("10,64,-20").y, 64, "parsePos y")
t.eq(P.parsePos("10,64,-20").z, -20, "parsePos z")
t.eq(P.parsePos(" 10 , 64 , -20 ").z, -20, "parsePos tolerates spaces")
t.eq(P.parsePos("10.5,64,-20.25").x, 10.5, "parsePos accepts decimals")
t.eq(P.parsePos("10,64"), nil, "parsePos rejects 2 components")   -- NOT .z -- indexing nil would error, not fail
t.eq(P.parsePos("a,b,c"), nil, "parsePos rejects non-numbers")
t.eq(P.parsePos(""), nil, "parsePos rejects empty")
t.eq(P.parsePos(nil), nil, "parsePos rejects nil")
t.eq(P.parsePos({ x = 1, y = 2, z = 3 }).y, 2, "parsePos passes a valid table through")
t.eq(P.parsePos({ x = 1, y = 2 }), nil, "parsePos rejects an incomplete table")

-- near: an axis-aligned box. Default range 4 in x/z, 3 in y. Boundaries are INCLUSIVE.
t.ok(P.near(st(0, 64, 0), pp(0, 64, 0), OVER), "player on the station -> near")
t.ok(P.near(st(0, 64, 0), pp(10, 64, 10), OVER), "at the x/z boundary (10) -> near")
t.ok(not P.near(st(0, 64, 0), pp(11, 64, 0), OVER), "one past x boundary -> not near")
t.ok(not P.near(st(0, 64, 0), pp(0, 64, 11), OVER), "one past z boundary -> not near")
t.ok(P.near(st(0, 64, 0), pp(0, 67, 0), OVER), "at the y boundary (3) -> near")
t.ok(not P.near(st(0, 64, 0), pp(0, 68, 0), OVER), "one past y boundary -> not near (floor above)")
-- y is NOT widened along with range: a player 10 blocks away and 4 up is on another floor, not here.
t.ok(not P.near(st(0, 64, 0), pp(10, 68, 10), OVER), "far corner but one floor up -> not near")
t.ok(P.near(st(0, 64, 0), pp(-4, 61, -4), OVER), "negative corner -> near")
-- NB: the override values must differ from DEFAULT_RANGE, or these assert nothing.
t.ok(P.near(st(0, 64, 0, { range = 20 }), pp(15, 64, 0), OVER), "range override widens x/z beyond the default")
t.ok(not P.near(st(0, 64, 0, { range = 1 }), pp(2, 64, 0), OVER), "range override narrows x/z")
t.ok(P.near(st(0, 64, 0, { yRange = 20 }), pp(0, 80, 0), OVER), "yRange override widens y")

-- dimension: the ONE filter getPlayerPos does not do for us (spec fact 4).
t.ok(not P.near(st(0, 64, 0), pp(0, 64, 0, NETHER), OVER),
  "same x/z in the NETHER -> NOT near (the whole point of fact 4)")
t.ok(P.near(st(0, 64, 0, { dim = NETHER }), pp(0, 64, 0, NETHER), OVER),
  "a station that declares itself in the Nether matches a Nether player")
t.ok(not P.near(st(0, 64, 0, { dim = NETHER }), pp(0, 64, 0, OVER), OVER),
  "...and stops matching overworld players")
t.ok(P.near(st(0, 64, 0), { x = 0, y = 64, z = 0 }, OVER),
  "no dimension field -> PERMISSIVE (a false wake is cosmetic; a bricked floor is not)")

-- garbage in
t.ok(not P.near(st(0, 64, 0), nil, OVER), "nil playerPos -> not near")
t.ok(not P.near(st(0, 64, 0), { x = 0, z = 0 }, OVER), "playerPos missing y -> not near")
t.ok(not P.near({ pos = nil }, pp(0, 64, 0), OVER), "station with no pos -> not near")
t.ok(not P.near(nil, pp(0, 64, 0), OVER), "nil station -> not near")

-- evaluate: every station judged against every player. Keys are computer IDs.
do
  local stations = { [5] = st(0, 64, 0), [7] = st(100, 64, 100), [9] = st(1000, 64, -800) }
  local now = P.evaluate(stations, { alice = pp(1, 64, 1) }, OVER)
  t.eq(now[5], true, "station 5 sees alice")
  t.eq(now[7], false, "station 7 does not")
  t.eq(now[9], false, "the 1000-blocks-out station does not")

  local two = P.evaluate(stations, { alice = pp(1, 64, 1), bob = pp(1000, 64, -800) }, OVER)
  t.eq(two[5], true, "station 5 still sees alice")
  t.eq(two[9], true, "station 9 sees bob at 1000 blocks -- distance is irrelevant to the math")

  t.eq(P.evaluate(stations, {}, OVER)[5], false, "nobody online -> everything empty")
  t.eq(P.evaluate({}, { alice = pp(0, 64, 0) }, OVER)[5], nil, "no stations -> empty result")

  -- two stations at one position both wake. Correct, not a bug.
  local twin = P.evaluate({ [5] = st(0, 64, 0), [6] = st(0, 64, 0) }, { alice = pp(0, 64, 0) }, OVER)
  t.ok(twin[5] and twin[6], "two stations at one position both wake")

  -- a player the hub could not locate (getPlayerPos returned nil -> never entered `positions`)
  t.eq(P.evaluate(stations, { alice = pp(1, 64, 1), bob = false }, OVER)[5], true,
    "a junk entry cannot crash the sweep or mask a real player")
end

-- edges: ONLY changes. This is what keeps rednet quiet while nobody moves.
do
  local e = P.edges({}, { [5] = false, [7] = false })
  t.eq(#e, 0, "first poll, nobody present -> NO messages (false == absent default)")

  e = P.edges({ [5] = false }, { [5] = true })
  t.eq(#e, 1, "arrival -> one edge")
  t.eq(e[1].id, 5, "edge carries the computer ID")
  t.eq(e[1].present, true, "edge carries present=true")

  e = P.edges({ [5] = true }, { [5] = true })
  t.eq(#e, 0, "standing still -> NO messages")

  e = P.edges({ [5] = true }, { [5] = false })
  t.eq(#e, 1, "departure -> one edge")
  t.eq(e[1].present, false, "departure edge is present=false")

  e = P.edges({ [5] = true, [7] = true }, { [5] = false, [7] = true })
  t.eq(#e, 1, "only the station that changed emits")
  t.eq(e[1].id, 5, "and it is the right one")

  -- a station that was present then deregistered must still be told to sleep
  e = P.edges({ [5] = true }, {})
  t.eq(#e, 1, "deregistered while present -> tell it to sleep")
  t.eq(e[1].present, false, "...with present=false")
  t.eq(#P.edges({ [5] = false }, {}), 0, "deregistered while absent -> nothing to say")

  -- deterministic ordering, so this test and the hub's log are stable
  e = P.edges({}, { [9] = true, [5] = true, [7] = true })
  t.eq(e[1].id, 5, "edges sorted by id (1)")
  t.eq(e[2].id, 7, "edges sorted by id (2)")
  t.eq(e[3].id, 9, "edges sorted by id (3)")
end

t.done()
