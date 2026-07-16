package.path = "src/lib/?.lua;src/cage/?.lua;test/?.lua;" .. package.path
local t = require("runner")
local V = require("cage_vault")
local R = require("cage_rates")

-- ---- valueListing --------------------------------------------------------
local list = {
  [1] = { name = "minecraft:iron_ingot",   count = 5 },   -- 500
  [3] = { name = "minecraft:cobblestone",  count = 64 },  -- junk, ignored
  [4] = { name = "minecraft:diamond",      count = 2 },   -- 2000
  [7] = { name = "minecraft:copper_ingot", count = 4 },   -- 100
}
local total, moves, ignored = V.valueListing(list, R)
t.eq(total, 2600, "5 iron + 2 diamond + 4 copper = $2600")
t.eq(ignored, 1, "one junk stack ignored")
t.eq(#moves, 3, "three stacks to move")
t.eq(moves[1].slot, 1, "moves sorted by slot: first is slot 1")
t.eq(moves[1].count, 5, "moves carry the count")
t.eq(moves[2].slot, 4, "second is slot 4 (junk slot 3 skipped)")
t.eq(moves[3].slot, 7, "third is slot 7")

local zt, zm, zi = V.valueListing({}, R)
t.eq(zt, 0, "empty chest = $0")
t.eq(#zm, 0, "empty chest = no moves")
t.eq(zi, 0, "empty chest = nothing ignored")

local jt, jm, ji = V.valueListing({ [2] = { name = "minecraft:stick", count = 1 } }, R)
t.eq(jt, 0, "junk only = $0")
t.eq(#jm, 0, "junk only = no moves (never eats tools)")
t.eq(ji, 1, "junk only = 1 ignored")

-- ---- countItem -----------------------------------------------------------
local stock = {
  [1] = { name = "minecraft:iron_ingot", count = 64 },
  [2] = { name = "minecraft:diamond",    count = 3 },
  [5] = { name = "minecraft:iron_ingot", count = 12 },
}
t.eq(V.countItem(stock, "minecraft:iron_ingot"), 76, "iron summed across slots")
t.eq(V.countItem(stock, "minecraft:diamond"), 3, "diamond counted")
t.eq(V.countItem(stock, "minecraft:gold_ingot"), 0, "absent item = 0")
t.eq(V.countItem({}, "minecraft:iron_ingot"), 0, "empty vault = 0")

-- ---- addLoad (round-robin across droppers) -------------------------------
local loads, nxt = V.addLoad({ 0, 0, 0 }, 7, 1)
t.eq(loads[1], 3, "7 across 3 droppers: d1 gets 3")
t.eq(loads[2], 2, "d2 gets 2")
t.eq(loads[3], 2, "d3 gets 2")
t.eq(nxt, 2, "next start index wraps to 2")

-- a second tap CONTINUES the rotation and ADDS to existing loads (spam-tap overlap)
local loads2, nxt2 = V.addLoad(loads, 2, nxt)
t.eq(loads2[2], 3, "second tap adds to d2")
t.eq(loads2[3], 3, "second tap adds to d3")
t.eq(loads2[1], 3, "d1 untouched by the 2-item tap")
t.eq(nxt2, 1, "index wrapped back to 1")

t.eq(V.addLoad({ 0, 0, 0 }, 0, 1)[1], 0, "zero items loads nothing")
local one, oneNxt = V.addLoad({ 0, 0, 0 }, 1, 3)
t.eq(one[3], 1, "start index respected")
t.eq(oneNxt, 1, "wrap from 3 -> 1")

-- ---- pulseLoads ----------------------------------------------------------
local p, ejected = V.pulseLoads({ 3, 1, 0 })
t.eq(ejected, 2, "one pulse: only the 2 non-empty droppers eject")
t.eq(p[1], 2, "d1 3->2")
t.eq(p[2], 0, "d2 1->0")
t.eq(p[3], 0, "d3 stays 0 (never negative)")

local _, none = V.pulseLoads({ 0, 0, 0 })
t.eq(none, 0, "pulsing empty droppers ejects nothing")

-- ---- anyLoaded -----------------------------------------------------------
t.ok(V.anyLoaded({ 0, 1, 0 }), "still owed items")
t.ok(not V.anyLoaded({ 0, 0, 0 }), "shower done")

t.done()
