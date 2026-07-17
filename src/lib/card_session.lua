-- card_session.lua — ONE card on ONE drive.
--
-- sp_econ and cage_econ each grew their own copy of this: read the card, ask the hub for the truth,
-- fall back to the card's mirror when the hub is quiet, re-read on disk events, write the mirror
-- back. Two instances is a coincidence; mp_econ made it three, so it lives here now.
--
-- The framing that makes multiplayer cheap: a session is one card on one DRIVE. Bind it to nil and
-- it is the single-card behaviour slot and the cage have always had. Bind N of them to N named
-- drives and you have N seats. That is the whole trick -- mp_econ is N of these plus arithmetic.
local card   = require("card")
local wallet = require("wallet")

local M = {}

-- cfg.drive = a drive's peripheral name, or nil = the first drive holding a disk.
-- cfg.flush = false to skip the entry outbox flush.
--   A multi-seat station must flush ONCE, not once per seat: N seats would be N rednet round-trips
--   at boot, and with the hub down that is N serialised LOOKUP_BACKOFF windows (wallet.lua) in the
--   boot path. mp_econ flushes for its seats and passes flush=false.
function M.new(cfg)
  cfg = cfg or {}
  local self = {
    drive   = cfg.drive,
    player  = nil,    -- id string, or nil (anonymous)
    balance = nil,    -- last known hub balance for player
    offline = false,  -- hub unreachable. NOT the same as broke, and the difference is the point:
                      -- telling a player holding $500 they are INSUFFICIENT is a lie about money.
  }

  if cfg.flush ~= false then wallet.flush() end

  -- record the outcome of a hub call the CALLER made. The gateways above (tryBet, tryDebit) make
  -- hub calls this session never sees, and they must render the result honestly -- so they hand the
  -- reason back here instead of each keeping a second, drifting copy of `offline`.
  function self.noteHub(reason)
    self.offline = (reason == "timeout")
  end

  -- read the card and reconcile with the hub. The hub is truth; the card's score is a mirror we
  -- fall back to only when the hub does not answer.
  function self.refresh()
    local c = card.read(self.drive)
    if c then
      self.player = c.id
      local b, reason = wallet.query(c.id)
      self.noteHub(reason)
      self.balance = b or c.score
      if b then card.writeMirror(b, self.drive) end
    else
      self.player, self.balance = nil, nil
      self.offline = false   -- no card is anonymous free play, not a hub error
    end
  end
  self.refresh()

  -- re-exported so a gateway can react to a card change without requiring `card` itself.
  -- sp_econ and cage_econ both need "was that a card event?" to clear their own denied/msg state.
  function self.isCardEvent(ev) return card.isCardEvent(ev) end

  -- fold a raw os event into state. Call for EVERY event in the play loop.
  function self.onEvent(ev)
    if not card.isCardEvent(ev) then return end
    -- ev[2] is the drive that changed. A bound seat ignores the others: without this, one insert at
    -- a 4-seat station fires FOUR wallet.query round-trips, three of them re-reading a card that
    -- did not change. An unbound session has no drive of its own, so any card event may be its own.
    if self.drive and ev[2] ~= self.drive then return end
    self.refresh()
  end

  -- keep the displayed balance and the card mirror in step after a hub write the CALLER made.
  function self.setBalance(b)
    self.balance = b
    card.writeMirror(b, self.drive)
  end

  function self.status()
    return { player = self.player, balance = self.balance, offline = self.offline }
  end

  return self
end

return M
