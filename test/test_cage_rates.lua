package.path = "src/lib/?.lua;src/cage/?.lua;test/?.lua;" .. package.path
local t = require("runner")
local R = require("cage_rates")

t.eq(#R.DENOMS, 4, "four denominations")

-- ordered cheapest -> dearest (the UI renders them left to right in this order)
t.eq(R.DENOMS[1].key, "copper",  "1st = copper")
t.eq(R.DENOMS[2].key, "iron",    "2nd = iron")
t.eq(R.DENOMS[3].key, "gold",    "3rd = gold")
t.eq(R.DENOMS[4].key, "diamond", "4th = diamond")

t.eq(R.DENOMS[1].value, 25,   "copper = $25")
t.eq(R.DENOMS[2].value, 100,  "iron = $100")
t.eq(R.DENOMS[3].value, 250,  "gold = $250")
t.eq(R.DENOMS[4].value, 1000, "diamond = $1000")

t.eq(R.DENOMS[2].item, "minecraft:iron_ingot", "iron item id")
t.eq(R.DENOMS[4].item, "minecraft:diamond",    "diamond item id")

t.eq(R.byItem("minecraft:gold_ingot").value, 250, "byItem finds gold")
t.eq(R.byItem("minecraft:cobblestone"), nil, "byItem: junk is unknown")
t.eq(R.byKey("diamond").item, "minecraft:diamond", "byKey finds diamond")
t.eq(R.byKey("nope"), nil, "byKey: unknown key")

t.eq(R.QTYS[1], 1,  "qty ladder 1x")
t.eq(R.QTYS[2], 5,  "qty ladder 5x")
t.eq(R.QTYS[3], 20, "qty ladder 20x")

t.done()
