-- issue.lua — admin: mint a membership card, or top up one that already exists. Run on the hub box
-- (advanced computer: a second multishell tab) or any computer with a disk drive + modem wired to
-- the hub network.
--   issue <name> [balance]     mint a NEW id onto a blank floppy (balance defaults to 100)
--   issue add <amount>         move the balance of the id ALREADY on the inserted floppy
--
-- `add` is a RESERVED WORD: a player literally named "add" can't be minted. Accepted wart.
-- `amount` is a delta and may be negative — the SIGN picks the primitive, and that is not cosmetic:
-- `ledger.apply` does NOT clamp at zero (it will happily write -30) while `ledger.debit` refuses when
-- the balance is short. So negatives go through `debit` and a too-big claw-back REFUSES instead of
-- driving the card negative — which the cage could not even render (pixelfont has no minus glyph).
-- Deltas also mean NO new hub message kind, so no `update hub` + reboot (kb/economy.md lesson 7).
-- Standalone (not under idle_runner), so it opens its own modem.
local card   = require("card")
local wallet = require("wallet")

local args = { ... }

local function usage()
  print("usage: issue <name> [balance]   mint a new card (balance defaults to 100)")
  print("       issue add <amount>       top up the card in the drive (may be negative)")
end

if not args[1] then usage(); return end   -- before the modem sweep: printing usage needs no rednet

-- The only door between a human's typing and a permanent hub write. Lives in wallet (with the other
-- pure `_` helpers) because that is the layer that can't be bypassed and where it is unit-tested —
-- `issue add inf` would otherwise poison a card's balance forever. See wallet._wholeAmount.
local wholeAmount = wallet._wholeAmount

-- Open EVERY modem, never guess one: "prefer wired" goes deaf to a hub that is only reachable by
-- ENDER modem, and reports it as "hub offline". rednet transmits on all open modems and de-duplicates
-- by message ID, so opening them all is both safe and the only way to find a hub wherever it lives.
local nModems = 0
for _, pname in ipairs(peripheral.getNames()) do   -- `pname`, not `name`: `name` is the card holder
  if peripheral.hasType(pname, "modem") then
    if not rednet.isOpen(pname) then rednet.open(pname) end
    nModems = nModems + 1
  end
end
if nModems == 0 then
  print("issue needs a MODEM that can reach the hub (wired on the hub's cable, or an ender modem).")
  return
end

-- ---- issue add <amount> — top up the card already in the drive ---------------

-- "$500 added" / "$50 taken" — `add` runs in BOTH directions, so every message has to read right for
-- a claw-back too. "$-50 credited" is how you get an admin to do the wrong thing in a hurry.
local function moved(amount)
  if amount > 0 then return ("$%d added"):format(amount) end
  return ("$%d taken"):format(-amount)
end

local function topUp(amount)
  if not amount or amount == 0 then
    print("issue add needs a whole, non-zero amount, e.g. `issue add 500` or `issue add -50`.")
    return
  end

  local c = card.read()
  if not c then
    print("No card in the drive — `issue add` tops up a card that already has an id on it.")
    print("To make a NEW one: issue <name> [balance]")
    return
  end

  -- THE SIGN PICKS THE PRIMITIVE. Neither outboxes, so nothing is ever left queued behind us.
  --   +n -> creditNow  (credit's admin sibling: no outbox; see wallet.creditNow for why)
  --   -n -> debit      (already fails closed on insufficient, so it can't drive a card negative)
  -- Note what this does NOT buy: a DENY means nothing moved, but a TIMEOUT means nothing is known.
  -- See the timeout branch below — that distinction is the difference between a safe re-run and
  -- doubling someone's balance.
  local ok, bal, reason
  if amount > 0 then ok, bal, reason = wallet.creditNow(c.id, amount)
  else               ok, bal, reason = wallet.debit(c.id, -amount) end

  if not ok then
    -- Never collapse these (kb/economy.md lesson 7): "denied", "hub unreachable", and "hub too old to
    -- know this message" are different problems with different fixes.
    if reason == "insufficient" then
      print(("'%s' has only $%s — cannot take $%d."):format(c.id, tostring(bal), -amount))
    elseif reason == "unknown" then
      print(("The ledger has no '%s'. This card is stale — its id was never minted, or was removed.")
            :format(c.id))
      print("Mint a fresh one with: issue <name> [balance]")
    else
      -- A TIMEOUT IS AMBIGUOUS, NOT A "NO", and this is the one thing here that can lose real money.
      -- `request` gives up after TIMEOUT, but the hub may well have received the message, applied it
      -- and persisted ledger.tbl, with only the REPLY lost or merely late — a server hitch stalls a CC
      -- computer for seconds, and the window is 1.5s. `credit`/`debit` carry no request id and are NOT
      -- idempotent, so "just run it again" is exactly how you double someone's balance. This code
      -- cannot know which happened — so it must not claim to. ASK the hub instead, and show the two
      -- numbers a human needs to decide. (Nothing was QUEUED, though: that part creditNow does
      -- guarantee, and it's why re-running is safe *once you know it didn't land*.)
      print(("NO REPLY from the hub within %ss. Nothing was queued on this computer."):format(
            tostring(wallet.TIMEOUT)))
      local now = wallet.query(c.id)
      if now then
        print(("  the hub says '%s' now reads:  $%d"):format(c.id, now))
        print(("  this card's last-known copy:  $%s"):format(tostring(c.score)))
        print("The hub IS answering now, so the first number is the truth. It may ALREADY have applied")
        print("this change — compare, and re-run ONLY if it did not land.")
      else
        print("The hub is not answering at all, so the change most likely did NOT land — but that is")
        print("a guess, not a promise. Check the balance once it's back, before re-running.")
      end
    end
    return
  end

  local before = bal - amount        -- no extra `query` round-trip: the hub just told us the new one
  print(("%s: $%d -> $%d  (%s%d)"):format(c.id, before, bal, amount > 0 and "+" or "", amount))

  -- Refresh the score mirror while the disk is right here. BEST EFFORT: the ledger is authoritative
  -- and the card self-heals on its next insert (kb/economy.md lesson 5), so a mirror write failing is
  -- not a failed top-up — say so, don't cry wolf.
  local wok, werr = card.write(c.id, bal)
  if not wok then
    print(("(the %s landed; only the card's display copy didn't: %s — it self-heals on next use)")
          :format(moved(amount), tostring(werr)))
  end
end

-- ---- issue <name> [balance] — mint a new card --------------------------------
local function mint(name, balance)
  local id, err = wallet.mint(name, balance)
  if not id then
    print("MINT FAILED: " .. tostring(err))
    if err == "exists" then
      print(("The ledger already has a '%s'. To add money to it, put their card in the drive and run:")
            :format(name))
      print("  issue add <amount>")
    end
    return
  end

  local ok, werr = card.write(id, balance)
  if not ok then
    print(("Ledger minted '%s' = %d, but writing the CARD failed: %s"):format(id, balance, tostring(werr)))
    print("Put a blank floppy in the drive; the ledger entry already exists, so re-mint is not needed —")
    print("write it manually or issue under a new name.")
    return
  end
  print(("Issued card '%s' with balance %d."):format(id, balance))
end

if args[1] == "add" then
  topUp(wholeAmount(args[2]))
else
  -- A fractional STARTING balance is the same money-that-disagrees-with-itself bug as a fractional
  -- top-up, so it gets the same door. `issue alice` (no balance) still defaults to 100.
  -- NOT `args[2] and wholeAmount(args[2]) or 100`: when wholeAmount returns nil the `or` fires and
  -- `issue alice abc` would silently mint at 100 instead of refusing. Middle term nil breaks and/or.
  local balance = 100
  if args[2] then
    balance = wholeAmount(args[2])
    if not balance then
      print(("'%s' is not a whole starting balance."):format(tostring(args[2])))
      return
    end
    -- ...and never MINT below zero either. `issue add -n` goes through debit precisely so a balance
    -- can't go negative; minting one there would walk straight around that guard, and the cage cannot
    -- render a minus sign. (Pre-existing: the old code took tonumber() at face value.)
    if balance < 0 then
      print(("A starting balance can't be negative (got %d)."):format(balance))
      return
    end
  end
  mint(args[1], balance)
end
