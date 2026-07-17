-- mp_econ.lua — the multiplayer economy gateway: N seats, N cards, ante -> pot -> payout.
--
-- Sibling of sp_econ (a wager round against a house paytable) and cage_econ (debit/credit at a
-- kiosk). This one is pot-shaped: every carded seat pays in, one seat takes the lot. All three sit
-- on the same card_session + wallet core, and none is built on another -- a pot is a different
-- shape, not a bigger bet.
--
-- A SEAT IS A DRIVE. That is the whole model: a drive is a physical place a player stands, and it
-- exists whether or not there is a card in it (an empty seat is an anonymous player). The card in
-- it is read by that seat's card_session and nobody else's.
--
-- The three money rules, in order of what they would cost to get wrong:
--   1. The ante is ALL-OR-NOTHING. A partial pot means somebody is about to win money that was
--      never all there. Any failure refunds every ante already taken (kb/economy.md lesson 6).
--   2. Pay the ANTED id, never the live card. Players eject mid-match and strangers insert cards;
--      the money must follow whoever paid (kb/economy.md lesson 2, generalised to N seats).
--   3. Refund and pay with wallet.credit, never creditNow -- on a hub timeout the money outboxes
--      and is flushed later. The player is owed it.
local card         = require("card")
local card_session = require("card_session")
local wallet       = require("wallet")

local M = {}

-- cfg.drives   = seat order (peripheral names). nil = discover, sorted. The per-station .cfg
--                overrides it: CC does NOT hand identically-built stations identical peripheral
--                names ([[station-hardware-discovery]]).
-- cfg.minSeats = the minimum number of CARDED seats that makes a pot (default 2).
-- cfg.maxSeats = cap on seats built from the drives (default 4).
-- cfg.ante     = $ per carded seat (default 10).
function M.new(cfg)
  cfg = cfg or {}
  local self = {
    ante     = cfg.ante or 10,
    minSeats = cfg.minSeats or 2,
    maxSeats = cfg.maxSeats or 4,
    phase    = "lobby",   -- "lobby" | "playing" | "done"
    pot      = 0,
    seats    = {},
  }

  -- ONCE for the station, not once per seat: N seats would be N rednet round-trips at boot, and
  -- with the hub down that is N serialised LOOKUP_BACKOFF windows in the boot path (wallet.lua).
  wallet.flush()

  local drives = cfg.drives or card.drives()
  for i = 1, math.min(#drives, self.maxSeats) do
    self.seats[i] = {
      drive   = drives[i],
      session = card_session.new{ drive = drives[i], flush = false },
      antedId = nil,   -- id DEBITED this match. nil = this seat did not pay (anon, or lobby).
      anted   = 0,     -- $ this seat put in
    }
  end

  -- fold a raw os event into state. Call for EVERY event in the play loop.
  -- Each session filters on its own drive, so one insert refreshes exactly one seat.
  function self.onEvent(ev)
    for _, s in ipairs(self.seats) do s.session.onEvent(ev) end
  end

  function self.cardedCount()
    local n = 0
    for _, s in ipairs(self.seats) do
      if s.session.player then n = n + 1 end
    end
    return n
  end

  -- For the UI only. There is deliberately no occupancy quorum: an anonymous player is INVISIBLE
  -- (a seat is a drive; a human standing at one with no card emits nothing a computer can read),
  -- so GO is always live and start() decides staked-vs-free from the only thing observable -- how
  -- many cards are in.
  function self.canStake()
    return self.cardedCount() >= self.minSeats
  end

  -- Give back every ante in `list` (seat indices), in full. Rule 3: credit, so a hub outage
  -- outboxes it rather than losing it.
  local function refundSeats(list)
    for _, i in ipairs(list) do
      local s = self.seats[i]
      if s.antedId then
        local ok, bal = wallet.credit(s.antedId, s.anted)
        if ok and bal and s.antedId == s.session.player then s.session.setBalance(bal) end
        s.antedId, s.anted = nil, 0
      end
    end
  end

  -- The GO edge. Returns "staked" | "free" | "deny", reason, seatIndex.
  function self.start()
    if self.phase == "playing" then return "deny", "already playing" end

    for _, s in ipairs(self.seats) do s.antedId, s.anted = nil, 0 end
    self.pot = 0

    local carded = {}
    for i, s in ipairs(self.seats) do
      if s.session.player then carded[#carded + 1] = i end
    end

    -- A pot needs at least two contributors. One carded seat would ante and win its own ante back,
    -- which is a debit, a credit and a disk write to achieve nothing -- so that is a free match.
    if #carded < self.minSeats then
      self.phase = "playing"
      return "free"
    end

    local paid = {}
    for _, i in ipairs(carded) do
      local s = self.seats[i]
      local ok, bal, reason = wallet.debit(s.session.player, self.ante)
      s.session.noteHub(reason)
      if ok then
        s.antedId, s.anted = s.session.player, self.ante   -- capture at commit (rule 2)
        s.session.setBalance(bal)
        paid[#paid + 1] = i
      else
        if bal ~= nil then s.session.balance = bal end      -- deny reply carries current balance
        refundSeats(paid)                                   -- rule 1: never leave a partial pot
        self.phase = "lobby"
        return "deny", (reason or "unknown"), i
      end
    end

    self.pot = self.ante * #paid
    self.phase = "playing"
    return "staked"
  end

  -- Resolve. `scores` = { [seatIndex] = number }; a missing seat scores 0.
  -- Returns { matchWinner, potWinner, potShare = {[seat]=amount}, pot }.
  function self.finish(scores)
    scores = scores or {}
    local res = { potShare = {}, pot = self.pot }

    -- The match winner is the best of ALL seats -- an anonymous player can take the glory.
    -- A tie takes the lowest seat index; this is a debug harness, not a tournament.
    local best, bestScore
    for i = 1, #self.seats do
      local sc = scores[i] or 0
      if bestScore == nil or sc > bestScore then best, bestScore = i, sc end
    end
    res.matchWinner = best

    -- The pot goes to the best-scoring seat that actually PAID IN. Built ascending, so a tie list
    -- is already in seat order.
    local top, topScore = {}, nil
    for i = 1, #self.seats do
      if self.seats[i].antedId then
        local sc = scores[i] or 0
        if topScore == nil or sc > topScore then top, topScore = { i }, sc
        elseif sc == topScore then top[#top + 1] = i end
      end
    end

    if #top > 0 and self.pot > 0 then
      -- Integer $ only: ("%d"):format(10.5) silently prints "10" in Lua 5.1, so a fractional
      -- share would leave the ledger and every screen disagreeing. Split the floor and hand the
      -- remainder to the lowest seat, so the shares sum to the pot EXACTLY -- no $ evaporates.
      local share = math.floor(self.pot / #top)
      local rem   = self.pot - share * #top
      for k, i in ipairs(top) do
        local amt = share + (k == 1 and rem or 0)
        if amt > 0 then
          local s = self.seats[i]
          local ok, bal = wallet.credit(s.antedId, amt)   -- rule 2: the ANTED id
          if ok and bal and s.antedId == s.session.player then s.session.setBalance(bal) end
          res.potShare[i] = amt
        end
      end
      res.potWinner = top[1]
    end

    self.phase = "done"
    self.pot = 0
    return res
  end

  function self.status()
    local seats = {}
    for i, s in ipairs(self.seats) do
      local st = s.session.status()
      seats[i] = {
        player  = st.player,
        balance = st.balance,
        offline = st.offline,
        anted   = s.anted,
        antedId = s.antedId,
      }
    end
    return { phase = self.phase, pot = self.pot, seats = seats }
  end

  return self
end

return M
