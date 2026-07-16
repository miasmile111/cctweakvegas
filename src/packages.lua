-- packages.lua — package -> file manifest. Fetched fresh from the repo by `update`.
--
-- A package groups the files a station needs, and whether installing it makes this
-- computer a named station (station = true -> gets a unique label like slot2).
-- Each file: { name = <in-world filename>, path = <repo path under src/, default name..".lua"> }.

return {
  slot = {
    station = true,
    files = {
      { name = "subpixel", path = "lib/subpixel.lua" },
      { name = "slot_logic" },
      { name = "slot_symbols" },
      { name = "slot" },
    },
  },

  pong = {
    station = true,
    files = {
      { name = "pong" },
    },
  },

  -- Infrastructure, not a player station (no instance label).
  hub = {
    station = false,
    files = {
      { name = "idle_logic" },
      { name = "hub" },
    },
  },
}
