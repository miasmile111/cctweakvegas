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

t.done()
