-- issue.lua — admin: mint a membership card. Run on the hub box (advanced computer: a second
-- multishell tab) or any computer with a disk drive + modem wired to the hub network.
--   issue <name> [balance]     (balance defaults to 100)
-- Asks the hub to mint the id, then writes { id, score } onto a blank floppy in the drive.
-- Standalone (not under idle_runner), so it opens its own modem.
local card   = require("card")
local wallet = require("wallet")

local args    = { ... }
local name    = args[1]
local balance = tonumber(args[2]) or 100
if not name then
  print("usage: issue <name> [balance]")
  return
end

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

local id, err = wallet.mint(name, balance)
if not id then
  print("MINT FAILED: " .. tostring(err))
  if err == "exists" then print(("The ledger already has a '%s'."):format(name)) end
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
