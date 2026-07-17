-- packages.lua — package -> file manifest. Fetched fresh from the repo by `update`.
--
-- A package groups the files a station needs, and whether installing it makes this
-- computer a named station (station = true -> needs a disk drive, registers with the hub
-- for a unique label like slot2, and boots into its game).
-- `autorun = "<prog>"` is the boot-into part on its own, for infra that is NOT a station:
-- the hub has no drive and no instance number, but must still come back after a restart.
-- Each file: { name = <in-world filename>, path = <repo path under src/, default name..".lua"> }.

return {
  slot = {
    station = true,
    files = {
      { name = "subpixel",     path = "lib/subpixel.lua" },
      { name = "pixelfont",    path = "lib/pixelfont.lua" },
      { name = "slot_style",   path = "slot/slot_style.lua" },
      { name = "idle_logic",   path = "lib/idle_logic.lua" },
      { name = "proximity",    path = "lib/proximity.lua" },
      { name = "idle_runner",  path = "lib/idle_runner.lua" },
      { name = "slot_logic",   path = "slot/slot_logic.lua" },
      { name = "slot_symbols", path = "slot/slot_symbols.lua" },
      { name = "slot_advert",  path = "slot/slot_advert.lua" },
      { name = "card",     path = "lib/card.lua" },
      { name = "wallet",   path = "lib/wallet.lua" },
      { name = "sp_econ",  path = "lib/sp_econ.lua" },
      { name = "slot_pay", path = "slot/slot_pay.lua" },
      { name = "slot",         path = "slot/slot.lua" },
    },
  },

  cage = {
    station = true,
    files = {
      { name = "subpixel",     path = "lib/subpixel.lua" },
      { name = "pixelfont",    path = "lib/pixelfont.lua" },
      { name = "idle_logic",   path = "lib/idle_logic.lua" },
      { name = "proximity",    path = "lib/proximity.lua" },
      { name = "idle_runner",  path = "lib/idle_runner.lua" },
      { name = "card",         path = "lib/card.lua" },
      { name = "wallet",       path = "lib/wallet.lua" },
      { name = "cage_econ",    path = "lib/cage_econ.lua" },
      { name = "cage_rates",   path = "cage/cage_rates.lua" },
      { name = "cage_vault",   path = "cage/cage_vault.lua" },
      { name = "cage_hw",      path = "cage/cage_hw.lua" },
      { name = "cage_symbols", path = "cage/cage_symbols.lua" },
      { name = "cage_advert",  path = "cage/cage_advert.lua" },
      { name = "cage",         path = "cage/cage.lua" },
    },
  },

  pong = {
    station = true,
    files = {
      { name = "idle_logic",   path = "lib/idle_logic.lua" },
      { name = "proximity",    path = "lib/proximity.lua" },
      { name = "idle_runner",  path = "lib/idle_runner.lua" },
      { name = "pong_advert", path = "pong/pong_advert.lua" },
      { name = "pong",        path = "pong/pong.lua" },
    },
  },

  -- Infrastructure, not a player station (no drive, no instance label) — but it must
  -- reboot into itself: a server restart that leaves the hub dead takes the floor with it.
  hub = {
    station = false,
    autorun = "hub",
    files = {
      { name = "idle_logic", path = "lib/idle_logic.lua" },
      { name = "proximity",  path = "lib/proximity.lua" },
      { name = "ledger",     path = "lib/ledger.lua" },
      { name = "hub",        path = "hub/hub.lua" },
    },
  },

  -- Admin tool, not a player station.
  issue = {
    station = false,
    files = {
      { name = "card",   path = "lib/card.lua" },
      { name = "wallet", path = "lib/wallet.lua" },
      { name = "issue",  path = "issue.lua" },
    },
  },
}
