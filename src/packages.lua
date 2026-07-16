-- packages.lua — package -> file manifest. Fetched fresh from the repo by `update`.
--
-- A package groups the files a station needs, and whether installing it makes this
-- computer a named station (station = true -> gets a unique label like slot2).
-- Each file: { name = <in-world filename>, path = <repo path under src/, default name..".lua"> }.

return {
  slot = {
    station = true,
    files = {
      { name = "subpixel",     path = "lib/subpixel.lua" },
      { name = "idle_logic",   path = "lib/idle_logic.lua" },
      { name = "idle_runner",  path = "lib/idle_runner.lua" },
      { name = "slot_logic",   path = "slot/slot_logic.lua" },
      { name = "slot_symbols", path = "slot/slot_symbols.lua" },
      { name = "slot_advert",  path = "slot/slot_advert.lua" },
      { name = "slot",         path = "slot/slot.lua" },
    },
  },

  pong = {
    station = true,
    files = {
      { name = "pong", path = "pong/pong.lua" },
    },
  },

  -- Infrastructure, not a player station (no instance label).
  hub = {
    station = false,
    files = {
      { name = "idle_logic", path = "lib/idle_logic.lua" },
      { name = "hub",        path = "hub/hub.lua" },
    },
  },
}
