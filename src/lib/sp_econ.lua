-- sp_econ.lua — single-player economy gateway. Composes card + wallet into the bet-gate,
-- settle/credit, and card lifecycle a game drives from its play() loop. Owns economy STATE;
-- the game renders it (status()). Reuses the modem idle_runner already opened; never opens
-- rednet itself. A future mp_econ.lua sits beside this on the same card/wallet core.
local card   = require("card")
local wallet = require("wallet")

local M = {}

-- cfg.pay = { STAKE = <int>, eval = function(result) -> payout:int }
-- cfg.zone is accepted for symmetry with the station's zone (unused today; MP will use it).
function M.new(cfg)
  local self = {
    pay     = cfg.pay,
    player  = nil,   -- id string, or nil (anonymous)
    balance = nil,   -- last known hub balance for player
    lastWin = 0,
    denied  = false,
    round   = nil,   -- "staked" | "free" | nil : current round's bet outcome
    stakedId = nil,   -- id that was debited this round; settle credits THIS, not the live card
    stakedStake = nil,   -- stake debited this round; settle evals payout against THIS
  }

  wallet.flush()     -- bank any wins queued while the hub was down, on entry

  local function refreshCard()
    self.denied = false
    local c = card.read()
    if c then
      self.player = c.id
      local b = wallet.query(c.id)      -- hub is truth; fall back to the card mirror if offline
      self.balance = b or c.score
      if b then card.writeMirror(b) end
    else
      self.player, self.balance = nil, nil
    end
  end
  refreshCard()

  -- fold a raw os event into state. Call for EVERY event in the play loop.
  function self.onEvent(ev)
    if card.isCardEvent(ev) then refreshCard() end
  end

  -- called on the arm edge. "staked" = stake debited, run the round for real;
  -- "free" = anonymous, run the round but it pays nothing; "deny" = insufficient/offline, do NOT run.
  function self.tryBet(stake)
    self.denied = false
    if not self.player then self.round = "free"; return "free" end
    local st = stake or self.pay.STAKE
    local ok, bal = wallet.bet(self.player, st)
    if ok then
      self.balance = bal; card.writeMirror(bal)
      self.round = "staked"; self.stakedId = self.player; self.stakedStake = st
      return "staked"
    end
    if bal ~= nil then self.balance = bal end   -- deny reply carries current balance
    self.denied = true; self.round = nil
    return "deny"
  end

  -- called at round resolution. Credits a win for a staked round; returns the payout paid (0 else).
  function self.settle(result)
    local won = 0
    if self.round == "staked" then
      local payout = self.pay.eval(result, self.stakedStake)
      if payout > 0 then
        local ok, bal = wallet.credit(self.stakedId, payout)
        if ok and bal then
          self.balance = bal; card.writeMirror(bal)
        else
          self.balance = (self.balance or 0) + payout   -- queued to outbox; reflect locally
        end
        won = payout
      end
    end
    self.lastWin = won
    self.round = nil
    return won
  end

  function self.status()
    return {
      player  = self.player,
      balance = self.balance,
      stake   = self.pay.STAKE,
      lastWin = self.lastWin,
      denied  = self.denied,
    }
  end

  return self
end

-- default plain-text header for games that don't render their own.
function M.drawHeader(mon, s)
  mon.setCursorPos(1, 1)
  if s.denied then
    mon.write("INSUFFICIENT")
  elseif s.player then
    mon.write(("%s  %d MB  stake %d"):format(s.player, s.balance or 0, s.stake))
  else
    mon.write("FREE PLAY - insert card to bet")
  end
end

return M
