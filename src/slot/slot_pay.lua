-- slot_pay.lua — the slot's payout script (pure; unit-tested). The tiny per-game piece the
-- economy gateway needs: a stake ladder and eval(result, stake) -> payout.
-- result = { r1, r2, r3 } symbol indices: 1=seven 2=cherry 3=bell 4=bar.
local STAKE  = 10                                    -- default/back-compat stake
local STAKES = { 10, 25, 100 }                       -- selectable ladder (slot v3)
local MULT   = { [1] = 25, [2] = 3, [3] = 5, [4] = 8 }   -- seven(jackpot) cherry bell bar

return {
  STAKE  = STAKE,
  STAKES = STAKES,
  MULT   = MULT,
  eval = function(result, stake)
    stake = stake or STAKE
    local a, b, c = result[1], result[2], result[3]
    if not (a == b and b == c) then return 0 end
    return stake * (MULT[a] or 0)
  end,
}
