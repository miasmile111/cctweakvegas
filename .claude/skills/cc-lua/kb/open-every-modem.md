---
title: Open EVERY modem for rednet — "prefer wired" goes deaf to an ender-linked hub
area: peripheral
verified: in-game 2026-07-17 (cage registered + the economy came alive the moment all modems were opened)
tags: [rednet, modem, ender modem, wireless, wired, peripheral_hub, rednet.open, rednet.lookup, isWireless, hub offline, registration failed, dedup, nMessageID, network topology]
---

**Symptom.** A station reports the **hub is offline while the hub is running fine**. `update` prints
`!!! REGISTRATION FAILED — HUB OFFLINE !!!` (all files install, `0 file errors`), or the kiosk's status
line says `HUB OFFLINE` on every withdraw. `rednet.lookup(PROTO, "hub")` simply returns nothing. The
hub is up, chunk-loaded, and answering other stations.

**Cause.** Code that picks **one** modem and guesses which:

```lua
-- WRONG. Shipped here, and it cost a debugging session.
local function findModem()
  local wired = peripheral.find("modem", function(_, m) return not m.isWireless() end)
  return wired or peripheral.find("modem")   -- wireless ONLY if no wired modem exists
end
rednet.open(peripheral.getName(findModem()))
```

**The floor is not one network.** A station's *peripherals* (chests, droppers, monitor) live on a
**wired** cable network; its link to a distant *hub* may be an **ender modem**. Those are different
networks. "Prefer wired" opens the cable — where the hub isn't — and the ender modem, the one thing
that could reach it, is never opened. Rednet then works perfectly and reaches nobody.

It hides well because everything *else* keeps working: the cable network still serves `chest.list`,
`pushItems` and the monitor, so the station looks healthy. Only hub traffic vanishes. `peripherals`
even lists the ender modem, so it *looks* attached.

The giveaway in the old code was its own comment — *"accept wireless for testing"*. It assumed one
floor-wide cable with the hub cabled onto it. The first station wired any other way walks straight
into the assumption.

**Fix — open all of them. Never guess.**

```lua
local function openAllModems()
  local n = 0
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.hasType(name, "modem") then          -- hasType: getType returns MULTIPLE types
      if not rednet.isOpen(name) then rednet.open(name) end
      n = n + 1
    end
  end
  return n                                             -- 0 = the real "no modem" preflight failure
end
```

**This is safe, and it is how rednet is built to work** (checked against `rom/apis/rednet.lua`, not
assumed — it matters, because on a money path a duplicated message is a double debit):

- `rednet.send`/`broadcast` **already loop over every open modem** — multi-modem is intended, not a hack.
- The `rednet.run` daemon keeps a `received_messages` table keyed by `nMessageID` and **drops repeats**
  (~9.5 s window, pruned every 10 s). So a hub reachable via *both* a cable **and** an ender modem
  receives each message **exactly once**. No double-credit, no double-debit.

**The half everyone forgets: the HUB has the same bug.** It is the one machine every station must
reach, and if it has a wired modem for cabled stations plus an ender modem for distant ones, "prefer
wired" makes it **listen on the cable alone and go deaf to every wireless station** — which they all
report as "hub offline" while it sits there running. Fixing only the station changes nothing: both
ends must be open. Have the hub print what it opened (`Rednet open on N modem(s): ...`) so a deaf ear
is visible at a glance.

**Sibling trap, identical symptom:** the redstone output sharing a side with the wired modem
(`[[redstone-pulse-needs-a-yield]]`), and a hub running **older code that doesn't know the message
kind** you're sending — the hub's handler chain has no `else`, so an unknown `kind` gets **no reply**,
and from the station "no reply" is indistinguishable from "no hub". All three present as HUB OFFLINE.
Distinguish them: does `query` work (balance shows) but `debit` not? → old hub. Does *nothing* reach
it? → modem/topology.

**So what.** `rednet.open` on exactly one modem is a bug in any base whose machines aren't all on one
cable. Open them all, at **every** entry point that talks rednet — the station runtime, the installer/
registrar, the hub, and any admin tool. Here that was `lib/idle_runner`, `update.lua`, `hub/hub.lua`
and `issue.lua`; three of the four would have looked fine in isolation.
