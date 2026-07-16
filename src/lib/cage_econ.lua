-- cage_econ.lua — the cage's economy gateway: a card session plus hub debit/credit, driven from
-- the station's play() loop. Sibling of sp_econ, on the same card+wallet core.
--
-- Why not sp_econ? That gateway is bet/settle-shaped (a wager round with a paytable). The cage has
-- no round, no result and no house evaluation — it debits and it credits. Both gateways need the
-- same card-session machinery (re-read on disk events, mirror writes, outbox flush, capture the id
-- at commit), so they share the core, not each other. When mp_econ becomes the third instance,
-- THAT is when lib/card_session.lua gets extracted — three callers prove the shape, two guess it.
--
-- Reuses the modem idle_runner already opened; never opens rednet itself.
local card   = require("card")
local wallet = require("wallet")

local M = {}

-- cfg.zone is accepted for symmetry with the station's zone (unused today; MP will use it).
function M.new(cfg)
  cfg = cfg or {}
  local self = {
    player  = nil,   -- id string, or nil (anonymous — buttons inert, never a gate)
    balance = nil,   -- last known hub balance for player
    denied  = false,
    msg     = nil,   -- status line for the UI
    debitedId = nil, -- id the last successful tryDebit charged; refund() credits THIS, not the
                     -- live card. The player can eject mid-shower — the money owed goes back to
                     -- whoever paid it. (sp_econ's stakedId lesson, kb/economy.md.)
  }

  wallet.flush()     -- bank any deposits queued while the hub was down, on entry

  local function refreshCard()
    self.denied, self.msg = false, nil
    local c = card.read()
    if c then
      self.player = c.id
      local b = wallet.query(c.id)     -- hub is truth; fall back to the card mirror if offline
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

  -- Take `amount` off the card. Fail-closed: anything but "ok" means NO items may move.
  -- The caller must have already confirmed vault stock — ordering invariant is
  -- stock check -> debit -> move.
  function self.tryDebit(amount)
    self.denied, self.msg = false, nil
    if not self.player then self.msg = "INSERT CARD"; return "nocard" end
    local ok, bal, reason = wallet.debit(self.player, amount)
    if ok then
      self.balance = bal
      self.debitedId = self.player     -- capture at commit: refund() must not follow the live card
      card.writeMirror(bal)
      return "ok"
    end
    if bal ~= nil then self.balance = bal end   -- deny reply carries current balance
    self.denied = true
    self.msg = (reason == "timeout") and "HUB OFFLINE" or ("NEED $" .. amount)
    return "deny"
  end

  -- Put `amount` on the card. Guaranteed: if the hub is down the credit is outboxed and the
  -- balance is reflected locally, so a deposit is never lost (wallet.credit's contract).
  function self.deposit(amount)
    self.denied, self.msg = false, nil
    if not self.player then self.msg = "INSERT CARD"; return nil end
    local ok, bal, reason = wallet.credit(self.player, amount)
    if ok and bal then
      self.balance = bal
      card.writeMirror(bal)
    elseif reason == "unknown" then          -- credit_deny: this card's id is gone from the ledger
      self.denied, self.msg = true, "BAD CARD"
      return nil
    else
      self.balance = (self.balance or 0) + amount   -- queued to outbox; reflect locally
      self.msg = "HUB OFFLINE"
    end
    return self.balance
  end

  -- Give money back after a move came up short. Credits the id that was DEBITED, not whoever is in
  -- the drive now: the player may have ejected mid-shower, and a refund must never follow the card.
  -- Only touches the displayed balance / mirror when the debited id is still the one on screen.
  function self.refund(amount)
    if amount <= 0 or not self.debitedId then return end
    local ok, bal = wallet.credit(self.debitedId, amount)
    local live = (self.debitedId == self.player)
    if ok and bal then
      if live then self.balance = bal; card.writeMirror(bal) end
    elseif live then
      self.balance = (self.balance or 0) + amount   -- outboxed; reflect locally
    end
    self.msg = "REFUNDED $" .. amount
  end

  function self.status()
    return {
      player  = self.player,
      balance = self.balance,
      denied  = self.denied,
      msg     = self.msg,
    }
  end

  return self
end

return M
