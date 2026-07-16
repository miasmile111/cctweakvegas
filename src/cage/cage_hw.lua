-- cage_hw.lua — every peripheral the cage touches, and nothing else. Chests, droppers, one
-- redstone line. All the math lives in cage_vault (pure, tested); this file is the hands.
--
-- Wiring: deposit chest, vault chest and EVERY dropper need a wired modem (pushItems only works
-- across the wired network). All droppers additionally share ONE redstone line from `cfg.side` —
-- a single pulse fires all of them, so a pulse ejects one item per non-empty dropper.
local M = {}

function M.new(cfg)
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
  function self.loadDroppers(item, perDropper)
    local loadedPer, total = {}, 0
    for i = 1, #perDropper do
      loadedPer[i] = 0
      local want = perDropper[i]
      while want > 0 do
        local moved, found = 0, false
        for slot, it in pairs(vault.list()) do
          if it.name == item then
            found = true
            moved = vault.pushItems(cfg.droppers[i], slot, want)
            if moved > 0 then break end
          end
        end
        if not found or moved == 0 then want = 0        -- vault dry (or dropper full): give up
        else
          want         = want - moved
          loadedPer[i] = loadedPer[i] + moved
          total        = total + moved
        end
      end
    end
    return loadedPer, total
  end

  -- one pulse on the shared line: every non-empty dropper spits one item onto the floor.
  function self.pulse()
    redstone.setOutput(cfg.side, true)
    redstone.setOutput(cfg.side, false)
  end

  return self
end

return M
