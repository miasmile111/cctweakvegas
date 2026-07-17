-- cage_hw.lua — every peripheral the cage touches, and nothing else. Chests, droppers, one
-- redstone line. All the math lives in cage_vault (pure, tested); this file is the hands.
--
-- Wiring: deposit chest, vault chest and EVERY dropper need a wired modem (pushItems only works
-- across the wired network). All droppers additionally share ONE redstone line from `cfg.side` —
-- one rising edge on that line fires all of them, ejecting one item per non-empty dropper.
-- `cfg.side` must NEVER be the modem's side (setOutput would drive the modem block, not dust).
local M = {}

function M.new(cfg)
  -- NIL-CHECK BEFORE ANYTHING TOUCHES cfg. The caller discovers these at boot, so a grey (unattached)
  -- modem means they arrive nil — and `#nil` / `peripheral.wrap(nil)` both THROW, which would blow
  -- past this function's fail-loud contract and take `cage test` (the tool that exists to diagnose
  -- exactly this) down with it. Return the message; never raise.
  if not cfg.deposit then
    return nil, "no deposit inventory found — is the player-facing barrel's modem attached (red)?"
  end
  if not cfg.vault then
    return nil, "no vault inventory found — the cage needs TWO non-dropper inventories on the network"
  end
  if not cfg.droppers or #cfg.droppers == 0 then
    return nil, "no droppers found — is each dropper's own modem attached (red)?"
  end

  local self = { nDroppers = #cfg.droppers }

  local deposit = peripheral.wrap(cfg.deposit)
  if not deposit then return nil, "no deposit chest: " .. tostring(cfg.deposit) end
  local vault = peripheral.wrap(cfg.vault)
  if not vault then return nil, "no vault chest: " .. tostring(cfg.vault) end

  local droppers = {}
  for i = 1, #cfg.droppers do
    local d = peripheral.wrap(cfg.droppers[i])
    if not d then return nil, "no dropper: " .. tostring(cfg.droppers[i]) end
    droppers[i] = d
  end

  function self.depositList() return deposit.list() end
  function self.vaultList()   return vault.list()   end

  -- move valued stacks from the deposit chest into the vault. Junk slots are simply not in `moves`,
  -- so they are never touched.
  function self.sweepToVault(moves)
    local moved = 0
    for i = 1, #moves do
      moved = moved + deposit.pushItems(cfg.vault, moves[i].slot, moves[i].count)
    end
    return moved
  end

  -- push `perDropper[i]` of `item` from the vault into dropper i. Walks the vault's slots because
  -- pushItems is slot-addressed; stops early when the vault runs dry or a dropper fills. Reports
  -- the PER-DROPPER counts it managed (not just a total) so the caller can drive the shower from
  -- what actually landed, and refund the shortfall.
  --
  -- COUNT EVERY PERIPHERAL CALL IN HERE. `list` and `pushItems` are CC:Tweaked MAIN-THREAD tasks
  -- (`@LuaFunction(mainThread = true)` on AbstractInventoryMethods), and a task parks the coroutine
  -- on `task_complete` until the *next* game tick — a sequential caller can only ever have ONE in
  -- flight, so every call is ~50ms with the play loop FROZEN: no tick, no render, dead monitor. This
  -- once re-listed the vault inside the per-dropper loop: a 4-dropper withdraw cost 4 list + 4 push
  -- = 8 calls ≈ 400ms of visible stutter, for a listing that only *we* were changing. So: ONE
  -- listing for the whole call, a local mirror of each slot's remaining count, and pushItems' return
  -- value as the authority. Cost is now one push per dropper PER VAULT SLOT it draws from — so a
  -- tidy vault (one fat stack per metal) is one push per dropper, and a fragmented one costs a tick
  -- per extra slot boundary. See [[main-thread-peripheral-calls-cost-a-tick]].
  --
  -- `listing` is optional: hand it the vault.list() you already took (withdraw()'s stock check) and
  -- the common path makes ZERO list calls.
  function self.loadDroppers(item, perDropper, listing)
    local loadedPer, want, total = {}, {}, 0
    for i = 1, #perDropper do loadedPer[i], want[i] = 0, perDropper[i] end

    -- One sweep over a single listing: build a local mirror of every slot holding `item` and spend it
    -- down, trusting pushItems' return. Returns what actually moved.
    local function sweep(list)
      local slots = {}
      for slot, it in pairs(list) do
        if it.name == item then slots[#slots + 1] = { slot = slot, left = it.count } end
      end
      table.sort(slots, function(a, b) return a.slot < b.slot end)  -- deterministic: tests depend on it

      local si, moved = 1, 0            -- slot cursor carries ACROSS droppers: a slot this sweep has
      for i = 1, #want do               -- already drained is never re-tried by the next dropper
        while want[i] > 0 and si <= #slots do
          local s = slots[si]
          if s.left <= 0 then si = si + 1
          else
            local n = vault.pushItems(cfg.droppers[i], s.slot, math.min(want[i], s.left))
            -- 0 is AMBIGUOUS: this dropper is full, OR the mirror is stale and the slot is really
            -- empty. We can't tell without another list(), so give up on this dropper and let the
            -- retry below sort it out — never guess, because guessing "slot is dead" would skip
            -- stock the next dropper needs, and guessing "dropper is full" would spin.
            if n == 0 then break end
            s.left       = s.left - n
            want[i]      = want[i] - n
            loadedPer[i] = loadedPer[i] + n
            moved        = moved + n
          end
        end
      end
      return moved
    end

    total = sweep(listing or vault.list())

    -- SHORT? Then either a dropper was full or the listing went stale — and stale is real: the caller
    -- takes it BEFORE a blocking hub round-trip (withdraw()'s debit), so a hopper/contraption/player
    -- can drain a slot in that window. A stale mirror leaves a dead slot the sweep keeps hitting, and
    -- without this retry the whole order strands on it: a 20x tap against a vault holding 66 iron
    -- delivered 2. (The old code re-listed per dropper and so never had the problem — losing that
    -- resilience to save a call would be a bad trade.) ONE fresh listing, one retry: costs a tick
    -- only when something was already wrong, and nothing on the happy path.
    local short = false
    for i = 1, #want do
      if want[i] > 0 then short = true; break end
    end
    if short then total = total + sweep(vault.list()) end

    return loadedPer, total
  end

  -- The shared line, as TWO half-calls — and they MUST land on different computer ticks.
  -- NEVER fold these back into one `pulse()` that sets true then false: `setOutput` only writes
  -- CC's *internal* redstone state + a dirty flag; the world is synced later, in `updateOutput()`
  -- on the computer tick, which diffs external-vs-internal per side. Toggle both ways inside one
  -- tick and internal ends where it started — nothing differs, no block update ever leaves the
  -- computer, and every dropper stays silent. `getOutput` reads the internal value, so Lua cannot
  -- see the bug: it reports the pulse it never sent. (This shipped once; see
  -- [[redstone-pulse-needs-a-yield]].) The caller drives these off its 0.05s tick loop, whose
  -- yield IS the flush boundary.
  function self.pulseOn()  redstone.setOutput(cfg.side, true)  end
  function self.pulseOff() redstone.setOutput(cfg.side, false) end

  return self
end

return M
