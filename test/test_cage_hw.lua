-- test_cage_hw.lua — cage_hw.loadDroppers against a FAKE wired network.
--
-- Why this file exists: every `list()` / `pushItems()` is a CC:Tweaked MAIN-THREAD task
-- (`@LuaFunction(mainThread = true)`), and a sequential coroutine can only have ONE in flight — it
-- yields until `task_complete`, which lands on the NEXT game tick. So each call costs ~50ms of a
-- FROZEN play loop: no tick, no render, no monitor. The call COUNT is therefore a correctness
-- property of this module, not a micro-optimisation, and it is asserted below.
--
-- cage_hw touches CC globals (`peripheral`, `redstone`), so they're stubbed here. Everything else
-- about the module is pure enough to test under luajit.
package.path = "src/lib/?.lua;src/cage/?.lua;test/?.lua;" .. package.path
local t = require("runner")

local NET = {}
_G.peripheral = { wrap = function(name) return NET[name] end }
_G.redstone   = { setOutput = function() end }

local IRON, GOLD = "minecraft:iron_ingot", "minecraft:gold_ingot"

-- Build a fake network. `vaultSlots` = { [slot] = {name=, count=} }, mutated in place by pushes.
-- `cap` = how many items each dropper accepts before it's full.
-- Returns cfg, a live call counter, and the droppers' held counts.
local function newNet(vaultSlots, nDroppers, cap)
  local calls   = { list = 0, push = 0 }
  local held    = {}
  local names   = {}
  NET = {}

  for i = 1, nDroppers do
    names[i] = "minecraft:dropper_" .. i
    held[names[i]] = 0
    NET[names[i]] = {}
  end

  NET["barrel_vault"] = {
    list = function()
      calls.list = calls.list + 1
      local out = {}                                   -- a real list() omits empty slots
      for slot, it in pairs(vaultSlots) do
        if it.count > 0 then out[slot] = { name = it.name, count = it.count } end
      end
      return out
    end,
    pushItems = function(target, slot, count)
      calls.push = calls.push + 1
      local it = vaultSlots[slot]
      if not it or it.count <= 0 then return 0 end
      local moved = math.min(count, it.count, cap - held[target])
      if moved <= 0 then return 0 end
      it.count      = it.count - moved
      held[target]  = held[target] + moved
      return moved
    end,
  }
  NET["barrel_deposit"] = { list = function() return {} end, pushItems = function() return 0 end }

  return { deposit = "barrel_deposit", vault = "barrel_vault", droppers = names, side = "back" },
         calls, held, names
end

local function sum(t_)
  local n = 0
  for i = 1, #t_ do n = n + t_[i] end
  return n
end

local cage_hw = require("cage_hw")

-- ---- the call-count contract ----------------------------------------------
-- THE regression this file is really for. The original loadDroppers called `vault.list()` inside the
-- per-dropper loop, so a 4-dropper withdraw burned 4 list + 4 push = 8 main-thread calls ≈ 400ms of
-- frozen monitor. One listing serves the whole call; pushItems' return keeps the local mirror honest.
do
  local cfg, calls = newNet({ [1] = { name = IRON, count = 64 } }, 4, 64)
  local hw = cage_hw.new(cfg)
  local per, total = hw.loadDroppers(IRON, { 5, 5, 5, 5 })
  t.eq(total, 20, "qty20 across 4 droppers: all 20 loaded")
  t.eq(sum(per), 20, "per-dropper counts sum to the total")
  t.eq(per[1], 5, "dropper 1 got its 5")
  t.eq(per[4], 5, "dropper 4 got its 5")
  t.eq(calls.push, 4, "ONE pushItems per dropper")
  t.eq(calls.list, 1, "ONE list() for the whole call, not one per dropper")
end

-- a caller that already listed the vault (withdraw()'s stock check) pays for NO list at all
do
  local slots = { [1] = { name = IRON, count = 64 } }
  local cfg, calls = newNet(slots, 4, 64)
  local hw = cage_hw.new(cfg)
  local listing = hw.vaultList()
  t.eq(calls.list, 1, "the caller's own stock check is the 1 list")
  local _, total = hw.loadDroppers(IRON, { 5, 5, 5, 5 }, listing)
  t.eq(total, 20, "handed a listing, it still loads everything")
  t.eq(calls.list, 1, "handed a listing, loadDroppers lists ZERO times")
  t.eq(calls.push, 4, "still one push per dropper")
end

-- a dropper wanting nothing costs nothing (qty1 must not touch all 4)
do
  local cfg, calls = newNet({ [1] = { name = IRON, count = 64 } }, 4, 64)
  local hw = cage_hw.new(cfg)
  local per, total = hw.loadDroppers(IRON, { 1, 0, 0, 0 })
  t.eq(total, 1, "qty1 loads 1")
  t.eq(per[1], 1, "into dropper 1")
  t.eq(calls.push, 1, "qty1 = exactly ONE push, not four")
end

-- ---- correctness: the vault runs dry ---------------------------------------
-- The caller refunds `qty - loaded`, so under-reporting here is a player losing money and
-- over-reporting is the cage giving metal away. Both are the same bug class.
do
  local cfg = newNet({ [1] = { name = IRON, count = 3 } }, 4, 64)
  local hw = cage_hw.new(cfg)
  local per, total = hw.loadDroppers(IRON, { 5, 5, 5, 5 })
  t.eq(total, 3, "vault holds 3: exactly 3 loaded, no phantom items")
  t.eq(sum(per), 3, "per-dropper counts agree with the total")
  t.eq(per[1], 3, "the first dropper takes what there is")
  t.eq(per[2], 0, "nothing left for dropper 2")
end

-- an EMPTY vault loads nothing and reports it (never a nil, never a crash)
do
  local cfg = newNet({}, 4, 64)
  local hw = cage_hw.new(cfg)
  local per, total = hw.loadDroppers(IRON, { 5, 5, 5, 5 })
  t.eq(total, 0, "empty vault loads nothing")
  t.eq(sum(per), 0, "and says so per-dropper")
  t.eq(#per, 4, "still returns one entry per dropper")
end

-- ---- correctness: stock spread across several slots -------------------------
do
  local cfg, calls = newNet({
    [1] = { name = IRON, count = 2 },
    [2] = { name = GOLD, count = 64 },   -- must never be touched
    [5] = { name = IRON, count = 2 },
    [9] = { name = IRON, count = 64 },
  }, 2, 64)
  local hw = cage_hw.new(cfg)
  local per, total = hw.loadDroppers(IRON, { 3, 3 })
  t.eq(total, 6, "6 iron pulled across three iron slots")
  t.eq(per[1], 3, "dropper 1 filled from slots 1+5")
  t.eq(per[2], 3, "dropper 2 filled from the remainder")
  t.ok(calls.push <= 5, "slot-spanning costs a push per slot, not per retry (got " .. calls.push .. ")")
end

-- the wrong metal is never moved, however much of it is sitting there
do
  local cfg = newNet({ [1] = { name = GOLD, count = 64 } }, 2, 64)
  local hw = cage_hw.new(cfg)
  local _, total = hw.loadDroppers(IRON, { 5, 5 })
  t.eq(total, 0, "a vault full of gold loads ZERO iron")
end

-- ---- correctness: a dropper is full ----------------------------------------
-- A dropper that refuses items must not swallow the loop or strand the rest of the order.
do
  local cfg = newNet({ [1] = { name = IRON, count = 64 } }, 2, 2)
  local hw = cage_hw.new(cfg)
  local per, total = hw.loadDroppers(IRON, { 5, 5 })
  t.eq(per[1], 2, "dropper 1 takes only what fits")
  t.eq(per[2], 2, "a full dropper 1 does not stop dropper 2")
  t.eq(total, 4, "total = what actually landed, so the caller refunds the rest")
end

-- ---- a STALE listing must not strand the order ------------------------------
-- withdraw() takes its listing BEFORE econ.tryDebit(), which is a blocking rednet round-trip to the
-- hub — so anything else touching the vault (a hopper, a Create contraption, a player) can drain a
-- slot in that window. The mirror then points at a slot that is really empty. That must NOT be read
-- as "this dropper is full": the old code re-listed every time and would simply find the iron in the
-- next slot, and losing that resilience to save a call would be a bad trade.
do
  local slots = { [1] = { name = IRON, count = 64 }, [9] = { name = IRON, count = 64 } }
  local cfg = newNet(slots, 4, 64)
  local hw = cage_hw.new(cfg)
  local listing = hw.vaultList()          -- the stock check sees 128 iron
  slots[1].count = 2                      -- ...and slot 1 is drained under us during the debit
  local per, total = hw.loadDroppers(IRON, { 5, 5, 5, 5 }, listing)
  t.eq(total, 20, "a stale slot does not strand the order: the other slot still has 66 iron")
  t.eq(sum(per), 20, "per-dropper counts agree")
  t.eq(per[4], 5, "the LAST dropper still gets filled")
end

-- the same staleness, but the vault really has gone dry: report honestly, never invent items
do
  local slots = { [1] = { name = IRON, count = 64 } }
  local cfg = newNet(slots, 4, 64)
  local hw = cage_hw.new(cfg)
  local listing = hw.vaultList()
  slots[1].count = 3                      -- someone emptied it during the debit
  local per, total = hw.loadDroppers(IRON, { 5, 5, 5, 5 }, listing)
  t.eq(total, 3, "only the 3 that are really there")
  t.eq(sum(per), 3, "and the caller refunds the other 17")
end

-- a genuinely FULL dropper must not be retried forever, and must not eat the others' stock
do
  local cfg, calls = newNet({ [1] = { name = IRON, count = 64 } }, 4, 2)
  local hw = cage_hw.new(cfg)
  local per, total = hw.loadDroppers(IRON, { 5, 5, 5, 5 })
  t.eq(total, 8, "each of the 4 droppers takes the 2 that fit")
  t.eq(per[1], 2, "dropper 1 capped at 2")
  t.eq(per[4], 2, "dropper 4 still got its share")
  t.ok(calls.push <= 12, "a full dropper costs a bounded number of pushes (got " .. calls.push .. ")")
end

-- ---- nil-checks still fail loudly, never raise ------------------------------
do
  local hw, err = cage_hw.new({ vault = "barrel_vault", droppers = { "minecraft:dropper_1" } })
  t.eq(hw, nil, "no deposit = no hw")
  t.ok(err and err:find("deposit"), "and the error names the deposit")

  local hw2, err2 = cage_hw.new({ deposit = "barrel_deposit", vault = "barrel_vault", droppers = {} })
  t.eq(hw2, nil, "zero droppers = no hw")
  t.ok(err2 and err2:find("dropper"), "and the error names the droppers")
end

t.done()
