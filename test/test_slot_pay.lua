package.path = "src/lib/?.lua;src/slot/?.lua;src/pong/?.lua;test/?.lua;" .. package.path
local t = require("runner")
local P = require("slot_pay")

t.eq(P.STAKE, 10, "stake is 10")

t.eq(P.eval({ 2, 3, 4 }), 0, "no triple -> 0")
t.eq(P.eval({ 1, 1, 2 }), 0, "two of a kind -> 0")

t.eq(P.eval({ 2, 2, 2 }), 30, "triple cherry -> stake*3")
t.eq(P.eval({ 3, 3, 3 }), 50, "triple bell -> stake*5")
t.eq(P.eval({ 4, 4, 4 }), 80, "triple bar -> stake*8")
t.eq(P.eval({ 1, 1, 1 }), 250, "triple seven -> jackpot stake*25")

-- variable stake
t.eq(P.eval({ 2, 2, 2 }, 25), 75, "triple cherry @25 -> 25*3")
t.eq(P.eval({ 1, 1, 1 }, 100), 2500, "triple seven @100 -> 100*25 jackpot")
t.eq(P.eval({ 4, 4, 4 }, 25), 200, "triple bar @25 -> 25*8")
t.eq(P.eval({ 2, 3, 4 }, 100), 0, "no triple @100 -> 0")
-- back-compat: omitted stake uses default STAKE (10)
t.eq(P.eval({ 3, 3, 3 }), 50, "triple bell, default stake -> 10*5")
-- ladder exported
t.eq(P.STAKES[1], 10, "STAKES[1] = 10")
t.eq(P.STAKES[2], 25, "STAKES[2] = 25")
t.eq(P.STAKES[3], 100, "STAKES[3] = 100")

t.done()
