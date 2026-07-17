-- sp_econ.lua — single-player economy gateway. Composes a card_session + wallet into the bet-gate,
-- settle/credit and card lifecycle a game drives from its play() loop. Owns economy STATE; the game
-- renders it (status()). Reuses the modem idle_runner already opened; never opens rednet itself.
--
-- The card session (read/query/mirror/refresh-on-disk-event) used to live here in full. It is now
-- lib/card_session, shared with cage_econ and mp_econ. What stays here is the SHAPE that is
-- single-player-specific: a wager round with a house paytable. mp_econ sits beside this on the same
-- session+wallet core, not on top of it -- a pot is a different shape, not a bigger bet.
local card_session = require("card_session")
local wallet       = require("wallet")

local M = {}

-- cfg.pay = { STAKE = <int>, eval = function(result, stake) -> payout:int }
-- cfg.drive = which drive holds the card (nil = the first one; single-card stations want nil).
-- cfg.zone is accepted for symmetry with the station's zone (unused today).
function M.new(cfg)
  local sess = card_session.new{ drive = cfg.drive }   -- flushes the outbox on entry

  local self = {
    pay      = cfg.pay,
    session  = sess,
    lastWin  = 0,
    denied   = false,
    round    = nil,   -- "staked" | "free" | nil : current round's bet outcome
    stakedId = nil,   -- id that was debited this round; settle credits THIS, not the live card
    stakedStake = nil,   -- stake debited this round; settle evals payout against THIS
  }

  -- fold a raw os event into state. Call for EVERY event in the play loop.
  -- `denied` clears on a CARD event only -- that is exactly what the old refreshCard did. Clearing
  -- it on every event instead would wipe the INSUFFICIENT header one frame after it appeared.
  -- sess.isCardEvent is the session's re-export (Task 2), so this file needs no `card` dependency.
  function self.onEvent(ev)
    if sess.isCardEvent(ev) then self.denied = false end
    sess.onEvent(ev)
  end

  -- called on the arm edge. "staked" = stake debited, run the round for real;
  -- "free" = anonymous, run the round but it pays nothing; "deny" = insufficient/offline, do NOT run.
  function self.tryBet(stake)
    self.denied = false
    if not sess.player then self.round = "free"; return "free" end
    local st = stake or self.pay.STAKE
    local ok, bal, reason = wallet.bet(sess.player, st)
    if ok then
      sess.noteHub(nil)
      sess.setBalance(bal)
      self.round = "staked"; self.stakedId = sess.player; self.stakedStake = st
      return "staked"
    end
    if bal ~= nil then sess.balance = bal end   -- deny reply carries current balance
    -- A hub timeout and a real insufficient-funds deny BOTH fail closed -- that does not change.
    -- But they are not the same thing, and telling a player with $500 that they are INSUFFICIENT is
    -- a lie the machine tells about money. Keep them apart for the header.
    sess.noteHub(reason)
    self.denied = not sess.offline
    self.round = nil
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
          -- credit the STAKED id, but only move the display if that id is still the card on screen
          if self.stakedId == sess.player then sess.setBalance(bal) else sess.balance = bal end
        else
          sess.balance = (sess.balance or 0) + payout   -- queued to outbox; reflect locally
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
      player  = sess.player,
      balance = sess.balance,
      stake   = self.pay.STAKE,
      lastWin = self.lastWin,
      denied  = self.denied,
      offline = sess.offline,
    }
  end

  return self
end

-- default plain-text header for games that don't render their own.
function M.drawHeader(mon, s)
  mon.setCursorPos(1, 1)
  if s.offline then
    -- offline first: a hub timeout fails a bet closed the same way insufficient funds does
    -- (tryBet returns "deny" either way), but offline/denied are mutually exclusive flags --
    -- telling a player with money in the bank that they're INSUFFICIENT is the exact lie
    -- this module exists to avoid, so offline must win the branch order.
    mon.write("HUB OFFLINE")
  elseif s.denied then
    mon.write("INSUFFICIENT")
  elseif s.player then
    mon.write(("%s  $%d  stake %d"):format(s.player, s.balance or 0, s.stake))
  else
    mon.write("FREE PLAY - insert card to bet")
  end
end

return M
