-- slot_pay.lua — the slot's payout script (pure; unit-tested). The single tiny per-game
-- piece the economy gateway needs: a fixed STAKE and eval(result) -> payout.
-- result = { r1, r2, r3 } symbol indices: 1=seven 2=cherry 3=bell 4=bar.
local STAKE = 10
local MULT  = { [1] = 25, [2] = 3, [3] = 5, [4] = 8 }   -- seven(jackpot) cherry bell bar

return {
  STAKE = STAKE,
  eval = function(result)
    local a, b, c = result[1], result[2], result[3]
    if not (a == b and b == c) then return 0 end
    return STAKE * (MULT[a] or 0)
  end,
}
