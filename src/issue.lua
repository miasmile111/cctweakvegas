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

local m = peripheral.find("modem", function(_, mm) return not mm.isWireless() end)
         or peripheral.find("modem")
if not m then
  print("issue needs a MODEM wired to the hub network.")
  return
end
rednet.open(peripheral.getName(m))

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
