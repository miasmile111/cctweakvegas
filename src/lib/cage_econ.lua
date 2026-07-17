-- cage_econ.lua — the cage's economy gateway: a card session plus hub debit/credit, driven from
-- the station's play() loop. Sibling of sp_econ, on the same card_session+wallet core.
--
-- Why not sp_econ? That gateway is bet/settle-shaped (a wager round with a paytable). The cage has
-- no round, no result and no house evaluation — it debits and it credits. Both need the same card
-- SESSION, so they share that (lib/card_session), not each other.
--
-- Reuses the modem idle_runner already opened; never opens rednet itself.
local card_session = require("card_session")
local wallet       = require("wallet")

local M = {}

-- cfg.drive = which drive holds the card (nil = the first one).
-- cfg.zone is accepted for symmetry with the station's zone (unused today).
function M.new(cfg)
  cfg = cfg or {}
  local sess = card_session.new{ drive = cfg.drive }   -- flushes the outbox on entry

  local self = {
    session = sess,
    denied  = false,
    msg     = nil,   -- status line for the UI
    debitedId = nil, -- id the last successful tryDebit charged; refund() credits THIS, not the
                     -- live card. The player can eject mid-shower — the money owed goes back to
                     -- whoever paid it. (sp_econ's stakedId lesson, kb/economy.md.)
  }

  -- fold a raw os event into state. Call for EVERY event in the play loop.
  function self.onEvent(ev)
    if sess.isCardEvent(ev) then self.denied, self.msg = false, nil end
    sess.onEvent(ev)
  end

  -- Take `amount` off the card. Fail-closed: anything but "ok" means NO items may move.
  -- The caller must have already confirmed vault stock — ordering invariant is
  -- stock check -> debit -> move.
  function self.tryDebit(amount)
    self.denied, self.msg = false, nil
    if not sess.player then self.msg = "INSERT CARD"; return "nocard" end
    local ok, bal, reason = wallet.debit(sess.player, amount)
    if ok then
      sess.noteHub(nil)
      self.debitedId = sess.player     -- capture at commit: refund() must not follow the live card
      sess.setBalance(bal)
      return "ok"
    end
    if bal ~= nil then sess.balance = bal end   -- deny reply carries current balance
    sess.noteHub(reason)
    self.denied = true
    -- Three states, not two. A deleted ledger id is not a broke player, and saying "NEED $100" to
    -- someone holding a dead card is the same lie about money that `offline` exists to prevent.
    if sess.offline then
      self.msg = "HUB OFFLINE"
    elseif reason == "unknown" then
      self.msg = "BAD CARD"
    else
      self.msg = "NEED $" .. amount
    end
    return "deny"
  end

  -- Put `amount` on the card. Guaranteed: if the hub is down the credit is outboxed and the
  -- balance is reflected locally, so a deposit is never lost (wallet.credit's contract).
  function self.deposit(amount)
    self.denied, self.msg = false, nil
    if not sess.player then self.msg = "INSERT CARD"; return nil end
    local ok, bal, reason = wallet.credit(sess.player, amount)
    if ok and bal then
      sess.noteHub(nil)
      sess.setBalance(bal)
    elseif reason == "unknown" then          -- credit_deny: this card's id is gone from the ledger
      self.denied, self.msg = true, "BAD CARD"
      return nil
    else
      sess.noteHub("timeout")
      sess.balance = (sess.balance or 0) + amount   -- queued to outbox; reflect locally
      self.msg = "HUB OFFLINE"
    end
    return sess.balance
  end

  -- Give money back after a move came up short. Credits the id that was DEBITED, not whoever is in
  -- the drive now: the player may have ejected mid-shower, and a refund must never follow the card.
  -- Only touches the displayed balance / mirror when the debited id is still the one on screen.
  function self.refund(amount)
    if amount <= 0 or not self.debitedId then return end
    local ok, bal = wallet.credit(self.debitedId, amount)
    local live = (self.debitedId == sess.player)
    if ok and bal then
      if live then sess.setBalance(bal) end
    elseif live then
      sess.balance = (sess.balance or 0) + amount   -- outboxed; reflect locally
    end
    self.msg = "REFUNDED $" .. amount
  end

  function self.status()
    return {
      player  = sess.player,
      balance = sess.balance,
      denied  = self.denied,
      offline = sess.offline,
      msg     = self.msg,
    }
  end

  return self
end

return M
