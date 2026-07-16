---
title: Discover a station's hardware by TYPE — network names are not stable across identical builds
area: deploy
verified: in-game 2026-07-17 (first real cage: droppers came up 1-4, not 0-3; discovery resolved it with no cage.cfg)
tags: [peripheral, getNames, hasType, getType, network name, wired modem, attach, cage.cfg, config, discovery, monitor, setTextScale, getSize, update overwrite]
---

**Claim.** Build two stations with **identical hardware** and they will **not** have identical
peripheral names. Hardcoding names — or asking the owner to write them all into a config — is a
losing move. Discover by **type** instead, and keep config for the one or two facts a computer
genuinely cannot infer.

**Evidence.** CC assigns a wired-network peripheral `<type>_<n>` using the lowest free index **on that
network**, and any attach/detach **burns a number**. The first real cage was built to spec and its
droppers came up `minecraft:dropper_1 … _4` — no `_0`, because one had been attached and removed
during the build. Same blocks, same order, different names. Meanwhile the modded barrels were
`sophisticatedstorage:barrel_0/_1`, so a name written for one floor is wrong on the next.

**Fix — infer what is inferable:**

| thing | how | why it's inferable |
| --- | --- | --- |
| droppers | every peripheral with `hasType(n, "minecraft:dropper")` | type is stable; count never matters if the logic round-robins |
| the monitor | the one that is **36×24 at scale 0.5** | the layout is transcribed for exactly that size |
| deposit / vault | lowest-named non-dropper `inventory` = deposit, next = vault | *only* by convention — see below |

```lua
local function namesOfType(t)
  local out = {}
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.hasType(name, t) then out[#out + 1] = name end   -- hasType: getType returns MULTIPLE
  end
  table.sort(out, nameLess)      -- natural sort: barrel_2 BEFORE barrel_10
  return out
end
```

**Pick the monitor by SIZE, not `peripheral.find("monitor")`.** `find` returns whichever comes first.
A station with two monitors attached (a decoy on `top`, the real 2×2 on the network) is then a **coin
flip on every boot**. Probe each at `setTextScale(0.5)` + `getSize()` — and **restore the text scale on
every monitor you reject**: a wired modem is a `peripheral_hub`, so `getNames()` reaches the *whole
floor*, and a careless probe silently rescales another station's live screen mid-draw.

**What is NOT inferable.** Two barrels are the same block to the computer; which one is the
player-facing deposit is a fact only a human knows. Same for a redstone output side — a signal has
nothing to introspect. So: convention + an override. Refuse to boot when the guess is unsafe (>2
candidate inventories: a hopper built over a dropper sorts ahead of the barrels and would silently
become the deposit box) and name the candidates in the error.

**The config file exists because `update` overwrites the program.** The deploy loop pulls fresh and
overwrites, so peripheral names typed into `cage.lua`'s config block are **deleted on the next push**
— the owner did exactly this, reasonably, because nothing said otherwise. `cage.cfg` is not in the
package file list, so it survives; it is the **only** place per-station wiring belongs, and cfg must
always win over discovery. Say this in the program's header, loudly. With discovery doing the rest, a
standard build needs **no config at all**.

**Give the station a `test` subcommand.** `cage test` lists what's attached, every monitor's size, the
**resolved** config *and where each value came from* (`(auto)` / `(cage.cfg)` / `(NOT FOUND)`), and the
vault's contents. Run it **before** the boot hard-stops, so it can explain a station that won't start
rather than dying with it — and make sure the diagnostic path itself survives nil config (ours crashed
on a grey modem: the tool built to diagnose a grey modem). Three-state provenance matters: collapsing
"not found" into "(cage.cfg)" makes the diagnostic **lie precisely when the machine is broken**.

**So what.** Every station after the first is cheaper: wire it to the standard build, run `update`,
run `<station> test`, done. See `[[deploy-and-identity]]` for the delivery half and
`[[open-every-modem]]` for the other thing a real floor's topology breaks.
