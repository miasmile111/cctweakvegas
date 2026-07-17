-- cage.lua — THE CAGE: the floor's cash desk, on ONE CC:Tweaked advanced monitor (2x2, 36x24 @0.5).
--   A member card's $ becomes real Minecraft metal, and metal becomes $. Bidirectional, flat rate,
--   hub-authoritative. Tap a qty (1x/5x/20x), tap a metal -> stock check, debit, the droppers spit
--   the ingots onto the floor and the big number counts DOWN. Fill the deposit chest and tap
--   DEPOSIT -> the metal is valued, swept to the vault, and the number counts UP.
--   Layout is the owner-approved tools/cage-preview.html, ported pixel for pixel.
--   Run:  cage                    -> play (idle_runner parks it asleep until a player walks up)
--   Run:  cage test               -> what's attached, every monitor's size, the RESOLVED config,
--                                    and what's in the vault. Start here when a cage won't boot.
--   Run:  cage test drop iron 4   -> shower real metal onto the floor, debiting NOBODY. The one
--                                    check only the server can answer: do the droppers actually fire?
--   Run:  cage debug              -> the same kiosk, plus timings on the COMPUTER's terminal: what
--                                    each tap cost, and any frame gap over 100ms. Start here when the
--                                    monitor STUTTERS — the cause is main-thread peripheral calls
--                                    (~50ms of frozen loop each), never the redstone.
--                                    See kb/main-thread-peripheral-calls-cost-a-tick.md.
--   Quit: Q on the computer's terminal.
--
-- HARDWARE IS DISCOVERED, NOT CONFIGURED. Network names are NOT stable across identically-built
-- cages (CC hands out `<type>_<n>` from the lowest free index, and any attach/detach burns a number
-- — this floor's droppers came up 1-4, not 0-3). So the cage finds its own kit by TYPE at boot:
--   * droppers -> every `minecraft:dropper` on the network. Any count; the shower round-robins.
--   * deposit  -> the LOWEST-NAMED non-dropper inventory. Attach the player-facing barrel FIRST.
--   * vault    -> the next one.
--   * monitor  -> the one that is 36x24 at scale 0.5. Picking by SIZE, not by "first monitor found",
--                 because a cage with two monitors attached would otherwise be a coin flip.
-- `cage.cfg` overrides any of it and always wins — that's for the odd station that numbered
-- differently, or a floor where the barrels were attached in the wrong order. A standard build
-- needs NO cage.cfg at all. `side` is the one thing that can't be discovered.
--
-- Wiring (all names/sides live in `cage.cfg` — rewire without re-importing; see below):
--   * Computer + ADVANCED MONITOR 2x2 @ text scale 0.5 (= 36x24 cells, exactly square).
--   * DISK DRIVE beside the computer — the member card goes in it. No card, no kiosk.
--   * WIRED MODEM on the RIGHT of the computer — carries rednet to the hub AND the peripheral
--     network below. Right, by convention: it stays reachable for players/admin to right-click.
--   * DEPOSIT CHEST on the wired network. Player-facing. Junk left in it is never touched.
--   * VAULT CHEST on the wired network. Deposits flow in, withdrawals flow out. Admin seeds it;
--     an empty vault denies withdrawals (diegetically correct for a cage).
--   * 2 OR MORE DROPPERS (any count — the shower round-robins across them; this build uses 8), each
--     with its OWN wired modem (pushItems only crosses the wired network) AND redstone dust from
--     ONE computer output side (`side`, default BACK). All droppers share that single line, so one
--     rising edge fires them all: ~1 item per non-empty dropper per 0.3s cycle. Aim them at the floor.
--   * THE REDSTONE LINE MUST NOT BE ON THE MODEM'S SIDE. `setOutput` would drive the modem block
--     instead of dust and no dropper would ever fire — which looks EXACTLY like a dead pulse.
--     Default `side=back` + modem on the right don't collide; keep them apart if you rewire.
--   * Every peripheral must be ATTACHED to the modem network (right-click each modem until it's red).
--     An unattached (grey) modem means the block does not exist to the computer. `cage test` lists
--     what it can actually see.
--
-- cage.cfg — OPTIONAL. A standard build needs none of it; each line just pins one thing discovery
-- would otherwise work out. It lives next to the program and is NOT part of the `cage` package, so
-- `update cage` never overwrites it — that is the whole point of it existing. Never put wiring in
-- this file's config block: the next `update` will delete it. Format is `key=value`, `#` comments,
-- droppers comma-separated:
--   deposit=sophisticatedstorage:barrel_0   # only if the barrels attached in the wrong order
--   vault=sophisticatedstorage:barrel_1
--   droppers=minecraft:dropper_1,minecraft:dropper_2   # only to use SOME of the droppers present
--   side=back                # redstone out for the shared line — NEVER the modem's side
--   monitor=monitor_0        # only if two monitors are both 36x24
--   pos=105,64,-238         # where this cage IS. Only needed until the GPS constellation exists —
--                           # with GPS a station finds this out itself. `hub test zones` shows what
--                           # the hub believes. Without either, the cage stays on the floor-wide
--                           # "all" zone (i.e. today's behaviour: the hub's range wakes everything).
--   range=10                # how close a player must get, in x/z. Default 10 (a 21x21 column — it is
--                           # a BOX, not a circle). Vertical reach is separate and fixed at 3.
--   dim=minecraft:overworld # only if this cage is NOT in the overworld
--   zone=all                # pin the zone; only to force the legacy floor-wide behaviour

local args = { ... }

-- `cage debug` — the kiosk, unchanged, plus timings on the COMPUTER's terminal (never the monitor,
-- so a player standing at it sees nothing different). Prints each withdraw's main-thread cost and
-- any tick longer than 100ms. Every `list`/`pushItems` is a main-thread task that parks this
-- coroutine until the next game tick, so "how many calls" and "how long was the loop frozen" are the
-- only two numbers that explain a stuttering monitor. Start here, not at the redstone.
local DEBUG = (args[1] == "debug")
local function dbg(fmt, ...)
  if DEBUG then print(("[dbg] " .. fmt):format(...)) end
end

local font  = require("pixelfont")
local rates = require("cage_rates")
local sym   = require("cage_symbols")

-- ---- config defaults (override any of these in cage.cfg) --------------------
-- Everything nil here is DISCOVERED at boot (see `discover()`), because network names are not stable
-- across identically-built cages. cage.cfg overrides any of it and always wins. `side` is the one
-- thing that can't be discovered — a redstone output has nothing to introspect.
local CFG = {
  deposit  = nil,        -- nil = lowest-named non-dropper inventory (the player-facing barrel)
  vault    = nil,        -- nil = the next one
  droppers = nil,        -- nil = every minecraft:dropper on the network
  side     = "back",     -- computer output side feeding the droppers' shared redstone line
  monitor  = nil,        -- nil = the monitor that is 36x24 at scale 0.5 (a 2x2 advanced)
  zone     = nil,        -- nil = AUTO: this computer's ID once the hub knows our position, else "all"
  pos      = nil,        -- "x,y,z" — only needed until the GPS constellation exists; gps.locate wins nothing
                         -- if this is set, because cfg ALWAYS wins over discovery
  dim      = nil,        -- nil = the hub's dimension (minecraft:overworld)
  range    = nil,        -- nil = proximity.DEFAULT_RANGE (4 blocks in x/z)
}
local CFG_FILE = "cage.cfg"

-- ---- palette: 16 slots, all spoken for --------------------------------------
-- The PALETTE, not screen space, is the scarce resource. The gradient rides 4 slots NOTHING else
-- draws in (so the ingots keep their real colours), and the bevel gets a real 3-step ramp for free.
local GRAD = { colors.blue, colors.purple, colors.magenta, colors.cyan }   -- repainted every tick
local GRAD_DEEP = { 0.00, 0.28, 0.10 }   -- deep casino-felt green
local GRAD_GOLD = { 0.62, 0.46, 0.06 }   -- money gold
-- content: white text + bevel light · orange copper · lightBlue diamond · yellow bulbs/qty-sel/
-- count-up · pink count-down · gray bulbs-off + bevel dark · lightGray iron + bevel face ·
-- green press-flash · red bars · black panels.      FREE: lime, brown.
local WHITE, YELLOW, PINK, GRAY, LIGHT_GRAY = colors.white, colors.yellow, colors.pink, colors.gray, colors.lightGray
local GREEN, RED, BLACK = colors.green, colors.red, colors.black

local TICK        = 0.05
local FLASH_TICKS = 8    -- ~0.4s press flash. monitor_touch has NO release event, so every "pressed"
local TOAST_TICKS = 40   -- 2s toast.          look here is a TIMED flash, never a mouse-up.

-- ---- layout — transcribed from the approved preview -------------------------
-- Cell row r -> top subpixel = (r-1)*3+1. The preview's JS buffer is 0-indexed and Lua's canvas is
-- 1-indexed: JS R(row)=(row-1)*3 <-> Lua Rl(row)=(row-1)*3+1, so any JS `R(n)+k` ports unchanged
-- but every RAW JS coordinate gains +1. (The classic port bug — kb/monitor-ui-workflow.md step 4.)
local function Rl(row) return (row - 1) * 3 + 1 end

local DENOM_COL, DENOM_WC = { 1, 10, 19, 28 }, 9    -- 4 metal buttons, 9 cells each = 36
local QTY_COL,   QTY_WC   = { 1, 13, 25 },     12   -- 3 qty buttons, 12 cells each = 36

local function topLayout()
  return {
    balY    = Rl(3) + 1,                                   -- big $ — rows 3-7
    topBarY = Rl(8),  topBarH = 6,                         -- red bar rows 8-9
    denomY  = Rl(10), denomH  = (Rl(17) + 2) - Rl(10) + 1, -- metals rows 10-17 (24 subpx)
    symY    = Rl(10) + 1,                                  -- sprite rows 10-12, clearing row 13
    qtyY    = Rl(18), qtyH = 6,                            -- qty rows 18-19
    botBarY = Rl(20), botBarH = 6,                         -- red bar rows 20-21
    depY    = Rl(22), depH = 9,                            -- DEPOSIT rows 22-24 (3 cells)
    sideTop = Rl(3) - 4, sideBot = Rl(7) + 2,              -- bulb lanes, one bulb up into the header
  }
end

-- the gradient's 4 bands are 18 subpx = exactly 6 cell rows each, so a cell never straddles two
local function bandAt(row) return GRAD[math.ceil(row / 6)] end

-- a bulb: on = bright yellow, off = dim grey (blinks by seed+tick parity)
local function bulb(cv, x, y, seed, bulbTick)
  cv:fillRect(x, y, 2, 2, ((seed + bulbTick) % 2 == 0) and YELLOW or GRAY)
end

-- A bevelled button: 1-subpixel light/dark edges around a face; `down` swaps them (pushed in).
-- Steel (white 240 / lightGray 153 / gray 76 = +87/-77) is the ONLY true 3-step ramp in CC's
-- stock 16 colours: the greens are 161/132/17 (no highlight) and red 114 / brown 106 are eight
-- points apart (no shadow). Costs no slots. The bottom-left and top-right CORNER cells see both
-- edge colours plus the face — 3 colours, so encodeCell squashes them. Two cells, accepted.
local function drawBevel(cv, x, y, w, h, face, light, dark, down)
  local tl, br = light, dark
  if down then tl, br = dark, light end
  cv:fillRect(x, y, w, h, face)
  cv:fillRect(x, y, w, 1, tl); cv:fillRect(x, y, 1, h, tl)
  cv:fillRect(x, y + h - 1, w, 1, br); cv:fillRect(x + w - 1, y, 1, h, br)
end

-- ---- the money -------------------------------------------------------------
local SIGN_W, SIGN_H, BIG_H = 7, 14, 12   -- SIGN_LG is 7x14; BIG @2x is 12 tall

-- centred as a UNIT. The $ is TALLER than the figures, so it starts a subpixel ABOVE them and
-- overshoots equally below — the negative offset is deliberate, not an off-by-one.
local function drawBalance(cv, y, digits, color)
  local total = SIGN_W + 1 + font.textWidth(font.BIG, digits, 1, 2)
  local x = math.floor((cv.w - total) / 2) + 1
  font.drawGlyph(cv, font.SIGN_LG, "$", x, y - math.floor((SIGN_H - BIG_H) / 2), color, 1)
  font.drawText(cv, font.BIG, digits, x + SIGN_W + 1, y, color, 1, 2)
end

-- The tint IS the feedback: you read "being paid" / "spending" before you read the digits.
-- PINK, not red: stock red is luminance 114 and the gradient's gold band is ~118, so a red
-- number vanishes on half the drift — and a cell holds 2 colours, so no outline can save it.
local function tintFor(disp, target)
  if disp < target then return YELLOW end   -- climbing: gold
  if disp > target then return PINK end     -- falling
  return WHITE                              -- at rest
end

-- dispBal eases toward the real balance: UP on a deposit, DOWN as the droppers empty.
-- Same ~24-frame ramp as the slot's win count-up, but signed.
local function easeToward(cur, target)
  if cur == target then return cur end
  local step = math.max(1, math.ceil(math.abs(target - cur) / 24))
  if cur < target then return math.min(target, cur + step) end
  return math.max(target, cur - step)
end

-- ---- hit testing -----------------------------------------------------------
-- map a monitor touch (cell col, row) to an action, or nil for a miss. Cell space, band first —
-- the slot's stakeAt pattern.
local function hitTest(tx, ty)   -- -> "deposit" | "qty", i | "denom", i | nil
  if ty >= 22 then return "deposit" end                        -- rows 22-24
  if ty >= 18 and ty <= 19 then                                -- qty rows 18-19
    for i = 1, #QTY_COL do
      if tx >= QTY_COL[i] and tx < QTY_COL[i] + QTY_WC then return "qty", i end
    end
    return nil
  end
  if ty >= 10 and ty <= 17 then                                -- metals rows 10-17
    for i = 1, #DENOM_COL do
      if tx >= DENOM_COL[i] and tx < DENOM_COL[i] + DENOM_WC then return "denom", i end
    end
    return nil
  end
  return nil
end

-- ---- the subpixel layer ----------------------------------------------------
-- Bar bulbs start a few cells in, never at the edge column: at the extreme edge a 2x2 dot shares a
-- cell with the side lane's bulb AND the bar, which is 3 colours, and encodeCell renders it as a
-- squashed sliver (kb/monitor-ui.md). x is ODD on purpose — a 2x2 at an odd x lives inside ONE cell
-- column (cols 7-8, 11-12, ...) instead of straddling two, so it survives encodeCell whole.
-- x = 7,11,..,67 is the preview's bar-bulb row ported exactly: its JS `for(x=6; x<CW-2; x+=4)` is
-- 0-indexed, and a RAW JS coordinate gains +1. (Not `x = 6` — that is slot.lua's literal on a
-- 30-wide canvas, and here it would straddle every bulb and jam a 17th against the right edge.)
local function drawBulbs(cv, L, tick)
  for x = 7, cv.w - 2, 4 do
    bulb(cv, x, L.topBarY + 2, math.floor(x / 4), tick)
    bulb(cv, x, L.botBarY + 2, math.floor(x / 4), tick)
  end
  for y = L.sideTop, L.sideBot, 4 do
    bulb(cv, 1, y, math.floor(y / 4), tick)
    bulb(cv, cv.w - 1, y, math.floor(y / 4), tick)
  end
end

-- st = { hasCard, tick, dispBal, balTarget, qtyIdx, pressIdx, pressUntil, depUntil, toastUntil, paying }
-- Draws everything EXCEPT the native cell-text overlays (those go on top, after render()).
local function drawCage(cv, st)
  local L = topLayout()
  -- gradient bands across the whole canvas (palette-driven; recoloured for free each tick)
  local bandH = math.ceil(cv.h / #GRAD)   -- 18 -> exactly 6 cell rows per band, no straddle
  for b = 1, #GRAD do cv:fillRect(1, 1 + (b - 1) * bandH, cv.w, bandH, GRAD[b]) end

  -- NO CARD -> this is not the kiosk. The controls don't exist yet: nothing here is spendable, so
  -- drawing them dead would lie about what's tappable. No big $ either — "$0" reads as "you're
  -- broke", not "no card". The rate table (native, overlaid) teaches the prices instead.
  if not st.hasCard then
    cv:fillRect(1, L.topBarY, cv.w, L.topBarH, RED)
    cv:fillRect(1, L.botBarY, cv.w, L.botBarH, RED)
    drawBulbs(cv, L, st.tick)
    cv:render()
    return
  end

  -- red frame bars — flash yellow while the droppers are spitting (the cash-machine moment)
  local barCol = (st.paying and st.tick % 2 == 0) and YELLOW or RED
  cv:fillRect(1, L.topBarY, cv.w, L.topBarH, barCol)
  cv:fillRect(1, L.botBarY, cv.w, L.botBarH, barCol)
  drawBulbs(cv, L, st.tick)

  -- metal buttons: black panel, ingot sprite centred; native label/price overlaid later. A tapped
  -- metal FLASHES green — DEPOSIT's green, so "money moved" is one colour across the whole kiosk.
  --
  -- EVERY gradient gap here is 2 subpixels — the outer two as much as the dividers. The panels used
  -- to run 2..17 and 56..71, leaving the canvas edge columns (x=1, x=72) just ONE subpixel of
  -- gradient, versus 2 for each divider. On a real monitor that lone subpixel does not survive the
  -- edge: the left column read as solid black between the red bars, while the money band above —
  -- whose edge cell is uniform gradient, not a half-and-half split — showed the animation fine. So
  -- the outer panels give a subpixel back (15 wide vs 16 for the middle pair). The sprites are
  -- positioned independently and do not move; nothing else notices.
  for i = 1, #DENOM_COL do
    local lit  = (st.pressIdx == i and st.tick < st.pressUntil)
    local x    = (DENOM_COL[i] - 1) * 2 + 2
    local w    = DENOM_WC * 2 - 2
    if i == 1          then x, w = x + 1, w - 1 end   -- leave x=1,2  to the gradient
    if i == #DENOM_COL then w = w - 1          end   -- leave x=71,72 to the gradient
    cv:fillRect(x, L.denomY, w, L.denomH, lit and GREEN or BLACK)
    cv:drawSprite((DENOM_COL[i] - 1) * 2 + 6, L.symY, sym.SPRITES[rates.DENOMS[i].key])
  end

  -- qty buttons: selected = yellow, others gray (the slot's stake idiom)
  for i = 1, #QTY_COL do
    cv:fillRect((QTY_COL[i] - 1) * 2 + 1, L.qtyY, QTY_WC * 2, L.qtyH, (i == st.qtyIdx) and YELLOW or GRAY)
  end

  -- DEPOSIT — a bevelled physical button across the full width. Pressed: light/dark swap, so it
  -- reads as pushed in. Native text is cell-locked and can't shift a subpixel; the swap carries it.
  drawBevel(cv, 1, L.depY, cv.w, L.depH, LIGHT_GRAY, WHITE, GRAY, st.tick < st.depUntil)

  -- the money — owner's $ at 1x + digits at 2x, riding the gradient, TINTED BY DIRECTION
  drawBalance(cv, L.balY, tostring(math.floor(st.dispBal)), tintFor(st.dispBal, st.balTarget))

  -- toast — a 2s panel over the metals when DEPOSIT was tapped with an empty box. It covers the
  -- buttons on purpose: the answer to "why did nothing happen" should be the only thing on screen.
  if st.tick < st.toastUntil then
    local h = (Rl(16) + 2) - Rl(12) + 1                   -- rows 12-16 = 15 subpx
    cv:fillRect(3, Rl(12), cv.w - 4, h, BLACK)            -- panel: x 3..70
    cv:fillRect(3, Rl(12), cv.w - 4, 1, WHITE)            -- top
    cv:fillRect(3, Rl(16) + 2, cv.w - 4, 1, WHITE)        -- bottom
    cv:fillRect(3, Rl(12), 1, h, WHITE)                   -- left
    cv:fillRect(cv.w - 2, Rl(12), 1, h, WHITE)            -- right (x 70 — the panel's last column)
  end

  cv:render()
end

-- ===== PLAY =================================================================
local subpixel   = require("subpixel")
local vault      = require("cage_vault")
local cage_hw    = require("cage_hw")
local cage_econ  = require("cage_econ")

-- read cage.cfg over the defaults. `key=value`, `#` comments, droppers comma-separated. Anything
-- unparseable is ignored — a typo'd line must not brick the station.
local function loadCfg()
  if not fs.exists(CFG_FILE) then return end
  local f = fs.open(CFG_FILE, "r")
  if not f then return end
  local scalars = { deposit = true, vault = true, side = true, monitor = true, zone = true,
                    pos = true, dim = true, range = true }
  for line in f.readLine do
    if not line:match("^%s*#") then
      local key, val = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
      if key == "droppers" and val then
        local list = {}
        for name in val:gmatch("[^,%s]+") do list[#list + 1] = name end
        if #list > 0 then CFG.droppers = list end
      elseif key and scalars[key] and val and val ~= "" then
        CFG[key] = val
      end
    end
  end
  f.close()
end
loadCfg()

-- ---- hardware discovery -----------------------------------------------------
-- Every cage on the floor is the same build (2 modems, 2 barrels, N droppers, 1 redstone line), but
-- the NETWORK NAMES are not stable between them: CC assigns `<type>_<n>` from the lowest free index
-- on that network, and any attach/detach burns a number — this build's droppers came up 1-4, not 0-3.
-- So names can't be hardcoded and can't be assumed identical across stations. Instead we discover by
-- TYPE, which is stable, and let cage.cfg override any of it for the odd station.

-- "barrel_10" must sort after "barrel_9": compare the prefix, then the trailing index NUMERICALLY.
local function nameLess(a, b)
  local ap, an = a:match("^(.-)_?(%d*)$")
  local bp, bn = b:match("^(.-)_?(%d*)$")
  if ap ~= bp then return a < b end
  if an == "" or bn == "" then return a < b end
  return tonumber(an) < tonumber(bn)
end

local function namesOfType(t)
  local out = {}
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.hasType(name, t) then out[#out + 1] = name end
  end
  table.sort(out, nameLess)
  return out
end

-- Every dropper on the network, in name order. Count never matters: cage_hw sizes itself from this
-- and cage_vault round-robins across whatever it's given.
local function findDroppers()
  return namesOfType("minecraft:dropper")
end

-- The two barrels/chests: an `inventory` that ISN'T a dropper. Sorted, so it's deterministic:
-- LOWEST-NAMED IS THE DEPOSIT (the player-facing one), next is the vault. Attach the deposit first
-- on a new build and this needs no config at all. Both are the same block to the computer — which is
-- the deposit is a fact only a human knows, so it's the one thing cage.cfg is really for.
local function findBarrels()
  local out = {}
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.hasType(name, "inventory") and not peripheral.hasType(name, "minecraft:dropper") then
      out[#out + 1] = name
    end
  end
  table.sort(out, nameLess)
  return out
end

-- The cage's monitor is the one that is EXACTLY 36x24 at scale 0.5 (a 2x2 advanced). Picking by size
-- instead of `peripheral.find("monitor")` matters: this build has two monitors attached, and find()
-- would return whichever came first — a coin flip that silently draws the kiosk on the wrong screen.
-- Probing costs a setTextScale, so restore the scale on every monitor we reject.
local MON_W, MON_H = 36, 24
-- Returns w, h, oldScale, wrapped. ALWAYS returns `wrapped`+`oldScale` when it has them, even on the
-- failure path — setTextScale(0.5) may already have landed before getSize() threw (peripheral yanked
-- mid-probe), and the caller can only put it back if we hand it back.
local function monSizeAt05(name)
  local m = peripheral.wrap(name)
  if not m then return nil end
  local okOld, old = pcall(m.getTextScale)
  if not okOld then old = nil end          -- can't read it => nothing to restore to; say so honestly
  local ok, w, h = pcall(function()
    m.setTextScale(0.5)
    return m.getSize()
  end)
  if not ok then return nil, nil, old, m end
  return w, h, old, m
end

local function findMonitorBySize()
  for _, name in ipairs(namesOfType("monitor")) do
    local w, h, old, m = monSizeAt05(name)
    if w == MON_W and h == MON_H then return name end
    if m and old then pcall(m.setTextScale, old) end   -- not ours: put it back how we found it
  end
  return nil
end

-- Fill in anything cage.cfg didn't pin. cfg always wins.
local DISCOVERED = { deposit = false, vault = false, droppers = false, monitor = false }
local EXTRA_INV                       -- set when discovery saw >2 candidate inventories
local function discover()
  if not CFG.droppers then
    local d = findDroppers()
    if #d > 0 then CFG.droppers, DISCOVERED.droppers = d, true end
  end
  if not CFG.deposit or not CFG.vault then
    local b = findBarrels()
    EXTRA_INV = (#b > 2) and b or nil   -- checked at boot; see the guard below
    -- Never hand the SAME barrel to both roles. cage.cfg may pin just one of them (e.g. only
    -- `vault=barrel_0`), and a naive b[1]/b[2] would then also pick barrel_0 as the deposit —
    -- the cage would sweep a barrel into itself.
    local function firstOther(taken)
      for i = 1, #b do if b[i] ~= taken then return b[i] end end
      return nil
    end
    if not CFG.deposit then
      local pick = firstOther(CFG.vault)
      if pick then CFG.deposit, DISCOVERED.deposit = pick, true end
    end
    if not CFG.vault then
      local pick = firstOther(CFG.deposit)
      if pick then CFG.vault, DISCOVERED.vault = pick, true end
    end
  end
  if not CFG.monitor then
    local m = findMonitorBySize()
    if m then CFG.monitor, DISCOVERED.monitor = m, true end
  end
end
discover()

local function findMon(name)
  if name then
    -- hasType, not `getType(name) == "monitor"`: getType returns MULTIPLE types since CC 1.99.
    local m = peripheral.wrap(name)
    if not m or not peripheral.hasType(name, "monitor") then
      error(("Monitor '%s' not found. Run `cage test`, then fix monitor= in cage.cfg."):format(name), 0)
    end
    -- Check the SIZE even when pinned by cage.cfg. The layout is transcribed pixel-for-pixel for
    -- 36x24; on anything else subpixel silently clips every out-of-range fillRect and the kiosk
    -- renders as garbage. Without this, `monitor=` would "accept" a wrong monitor — i.e. the exact
    -- fix the no-monitor error below tells you to apply would quietly not work.
    local w, h, old, probed = monSizeAt05(name)
    if w ~= MON_W or h ~= MON_H then
      -- put it back before bailing: this monitor isn't ours, and refusing to boot is no reason to
      -- leave someone else's screen rescaled.
      if probed and old then pcall(probed.setTextScale, old) end
      error(("Monitor '%s' is %sx%s at scale 0.5 — the cage needs %dx%d (a 2x2 ADVANCED monitor).\n"
             .. "Run `cage test` to see every monitor's size."):format(
             name, tostring(w), tostring(h), MON_W, MON_H), 0)
    end
    return m
  end
  -- discover() couldn't find a 36x24 @0.5 monitor. Don't silently grab the wrong screen.
  error(("No %dx%d monitor found (need a 2x2 ADVANCED monitor at scale 0.5).\n"
         .. "Run `cage test` to see every monitor's size."):format(MON_W, MON_H), 0)
end

-- ---- `cage test` — setup + wiring diagnostics -------------------------------
-- Runs BEFORE the hard-stops below on purpose: its whole job is to tell you WHY a cage won't boot,
-- so it must survive a config that makes cage_hw.new() refuse.
-- THREE states, not two. `DISCOVERED[k]` is only set when discovery SUCCEEDS, so "discovery came up
-- empty" and "pinned in cage.cfg" would otherwise collapse into the same label — and print
-- "(cage.cfg)" on a station that has no cage.cfg, precisely when the cage won't boot and the owner
-- is reading this to find out why.
local function src(k)
  if CFG[k] == nil then return "(NOT FOUND)" end
  return DISCOVERED[k] and "(auto)" or "(cage.cfg)"
end

local function testMode(cmd, a, b)
  if cmd == "drop" then
    -- Fire real metal onto the floor WITHOUT debiting anyone. This is the one thing only the server
    -- can answer: does a rising edge actually reach the droppers? Blocking sleeps are fine here —
    -- we're not in play(), there's no tick loop to starve, and the sleep IS the yield that lets CC
    -- flush the redstone output to the world (see [[redstone-pulse-needs-a-yield]]).
    local d = rates.byKey(a)
    if not d then
      print("unknown metal: " .. tostring(a))
      local keys = {}
      for i = 1, #rates.DENOMS do keys[#keys + 1] = rates.DENOMS[i].key end
      print("try: " .. table.concat(keys, " "))
      return
    end
    local qty = tonumber(b) or 1
    local hw, err = cage_hw.new(CFG)
    if not hw then print("HW FAIL: " .. err); return end
    local have = vault.countItem(hw.vaultList(), d.item)
    print(("vault holds %d %s"):format(have, d.label))
    if have < qty then print(("need %d — seed the vault first"):format(qty)); return end

    local per = {}
    for i = 1, hw.nDroppers do per[i] = 0 end
    vault.addLoad(per, qty, 1)
    local loadedPer, loaded = hw.loadDroppers(d.item, per)
    print(("loaded %d/%d across %d droppers"):format(loaded, qty, hw.nDroppers))
    if loaded == 0 then
      print("nothing loaded — check each dropper has its OWN wired modem (pushItems needs it)")
      return
    end

    -- FORCE THE LINE LOW FIRST — do not assume it is. CC persists redstone output after a program
    -- exits, and play()'s Q path can leave it HIGH mid-cycle. A dropper fires on the RISING edge, so
    -- starting high means the first pulseOn is no edge at all: with 4 items across 4 droppers this
    -- test is exactly ONE cycle, so nothing would drop and it would still report success — sending
    -- the owner off to rip out redstone that was working.
    hw.pulseOff(); sleep(0.1)

    local loads, cycles = loadedPer, 0
    while vault.anyLoaded(loads) do        -- same 2-high/4-low cadence play() uses
      hw.pulseOn();  sleep(0.1)
      hw.pulseOff(); loads = vault.pulseLoads(loads)   -- decrement on the FALLING edge
      sleep(0.2)
      cycles = cycles + 1
    end
    hw.pulseOff()
    print(("pulsed %d cycles on side '%s'. NO $ debited."):format(cycles, CFG.side))
    print("Ingots on the floor? -> the pulse works.")
    print("Nothing dropped? -> dust not reaching the droppers, wrong `side`, or fronts blocked.")
    return
  end

  print("=== cage test ===")
  print("Attached peripherals:")
  for _, n in ipairs(peripheral.getNames()) do
    print(("  %s  (%s)"):format(n, table.concat({ peripheral.getType(n) }, ", ")))
  end

  print("Monitors (size @0.5 — the cage needs " .. MON_W .. "x" .. MON_H .. "):")
  for _, n in ipairs(namesOfType("monitor")) do
    local w, h, old, m = monSizeAt05(n)
    local mine = (w == MON_W and h == MON_H)
    print(("  %-22s %sx%s %s"):format(n, tostring(w), tostring(h), mine and "<- the cage's" or ""))
    -- Probing costs a setTextScale, so put every OTHER monitor back. `right` is a peripheral_hub, so
    -- namesOfType("monitor") reaches every monitor on the whole floor network — without this,
    -- one `cage test` would silently rescale the SLOT machine's live screen mid-draw.
    if not mine and m and old then pcall(m.setTextScale, old) end
  end

  print("Resolved config:")
  print(("  deposit  %-24s %s"):format(tostring(CFG.deposit), src("deposit")))
  print(("  vault    %-24s %s"):format(tostring(CFG.vault),   src("vault")))
  print(("  monitor  %-24s %s"):format(tostring(CFG.monitor), src("monitor")))
  print(("  side     %-24s %s"):format(tostring(CFG.side),    "(redstone out)"))
  print(("  droppers %-24s %s"):format(CFG.droppers and (#CFG.droppers .. " found") or "NONE",
        src("droppers")))
  if CFG.droppers then
    for i = 1, #CFG.droppers do print("      " .. CFG.droppers[i]) end
  end

  if EXTRA_INV then
    print(("WARNING: %d non-dropper inventories on the network; the cage expects 2."):format(#EXTRA_INV))
    print("  lowest-named wins, which is a guess — pin deposit=/vault= in cage.cfg:")
    for i = 1, #EXTRA_INV do print("    " .. EXTRA_INV[i]) end
  end

  local hw, err = cage_hw.new(CFG)
  if not hw then
    print("HW: FAIL -> " .. err)
  else
    local okD, dl = pcall(hw.depositList)
    local okV, vl = pcall(hw.vaultList)
    local function count(t) local n = 0 for _ in pairs(t or {}) do n = n + 1 end return n end
    print(("HW: OK — deposit %s stacks, vault %s stacks, %d droppers"):format(
          okD and count(dl) or "?", okV and count(vl) or "?", hw.nDroppers))
    if okV then
      for i = 1, #rates.DENOMS do
        local d = rates.DENOMS[i]
        print(("  vault %-8s %4d  ($%d each)"):format(d.label, vault.countItem(vl, d.item), d.value))
      end
    end
  end
  print("Next: `cage test drop iron 4` — showers real metal, debits nobody.")
end

if args[1] == "test" then testMode(args[2], args[3], args[4]); return end

local mon = findMon(CFG.monitor)
mon.setTextScale(0.5)
local mw, mh = mon.getSize()
local win = window.create(mon, 1, 1, mw, mh, true)   -- offscreen buffer -> no flicker
local cv  = subpixel.new(win)

-- the hands: chests, droppers, the shared redstone line. A misconfigured cage must fail LOUDLY at
-- startup, not pretend to be a kiosk and eat someone's card balance.
if CFG.deposit and CFG.deposit == CFG.vault then
  error(("deposit and vault are the same inventory (%s).\nThe cage would sweep a barrel into itself."
         .. " Fix deposit=/vault= in cage.cfg; `cage test` shows what it found."):format(CFG.deposit), 0)
end
-- The build is TWO non-dropper inventories. More than that and "lowest-named wins" is a guess, not a
-- rule — and the modem is a peripheral_hub, so discovery sees the whole floor: a hopper built over a
-- dropper would sort ahead of the barrels and quietly become the deposit box. Refuse rather than
-- silently pick, and name the candidates so the fix is obvious.
if EXTRA_INV then
  error(("found %d non-dropper inventories; the cage expects 2 (deposit + vault):\n  %s\n"
         .. "Pin deposit= and vault= in cage.cfg."):format(#EXTRA_INV, table.concat(EXTRA_INV, "\n  ")), 0)
end
local hw, hwErr = cage_hw.new(CFG)
if not hw then error(hwErr .. "\nRun `cage test` to see what's attached, then fix cage.cfg.", 0) end

-- capture the gradient slots' original palette so we can restore it on exit
local gradOrig = {}
for i = 1, #GRAD do gradOrig[i] = { mon.getPaletteColour(GRAD[i]) } end

local function updateGradient(phase)
  for i = 1, #GRAD do
    local a = 0.5 + 0.5 * math.sin(phase + i * 0.9)
    local r = GRAD_DEEP[1] + (GRAD_GOLD[1] - GRAD_DEEP[1]) * a
    local g = GRAD_DEEP[2] + (GRAD_GOLD[2] - GRAD_DEEP[2]) * a
    local b = GRAD_DEEP[3] + (GRAD_GOLD[3] - GRAD_DEEP[3]) * a
    mon.setPaletteColour(GRAD[i], r, g, b)
    win.setPaletteColour(GRAD[i], r, g, b)
  end
end

local function restorePalette()
  for i = 1, #GRAD do
    local o = gradOrig[i]
    mon.setPaletteColour(GRAD[i], o[1], o[2], o[3])
  end
end

-- ---- native cell-text overlays ---------------------------------------------
-- Native text is CELL-LOCKED and NOT subject to encodeCell, so set each string's background to the
-- fill beneath it or it will box. Written to the window so it flushes with the canvas.
local function writeAt(text, row, col, fg, bg)
  win.setTextColor(fg); win.setBackgroundColor(bg)
  win.setCursorPos(col, row); win.write(text)
end

-- centre `text` within a cell-column span — the slot's stake-label idiom
local function writeIn(text, row, colStart, widthCells, fg, bg)
  writeAt(text, row, colStart + math.floor((widthCells - #text) / 2), fg, bg)
end

local function writeCentered(text, row, fg, bg)
  writeAt(text, row, math.floor((mw - #text) / 2) + 1, fg, bg)
end

-- one full frame: the subpixel layer, then the native overlays on top of it
local function drawFrame(st, econ)
  win.setVisible(false)
  drawCage(cv, st)

  if not st.hasCard then
    writeCentered("INSERT YOUR CARD", 5, WHITE, bandAt(5))      -- in the money band — where the money will be
    writeCentered("METAL IN - CASH OUT", 12, WHITE, bandAt(12))
    for i = 1, #rates.DENOMS do                                  -- the wait teaches the rates
      local d = rates.DENOMS[i]
      writeAt(("%-9s%5s"):format(d.label, "$" .. d.value), 13 + i, 12, WHITE, bandAt(13 + i))
    end
    win.setVisible(true)
    return
  end

  -- header row 2: the player, and the status. No station name — the player is standing at it.
  -- Both clear the bulb lanes (col 3 on the left; the status ends at col 35 on the right).
  -- player/balance now live on cage_econ's card_session, not on self -- read them via status().
  writeAt(econ.status().player, 2, 3, WHITE, bandAt(2))
  local status = econ.msg or (st.paying and ("PAYING " .. st.owed) or nil)
  if status then
    writeAt(status, 2, mw - #status, econ.denied and PINK or WHITE, bandAt(2))
  end

  -- The toast panel (drawn in the subpixel layer by drawCage) sits over rows 12-16, but these button
  -- labels are NATIVE text laid on top AFTER cv:render(), so they punch straight through the panel
  -- unless we skip them. Gate the whole button-label block on the toast: when it's up, the panel is
  -- the only thing in this region, which is the point ("why did nothing happen").
  local toast = st.tick < st.toastUntil
  -- each button reads as a sentence: "Withdraw / COPPER". Lowercase verb, SHOUTED noun — the metal
  -- is what you're picking, so the metal carries the weight. "Withdraw" is 8 chars in a 9-cell
  -- button: EXACTLY one cell of slack, and +1 uses it. At +2 the label spills onto the next button
  -- and DIAMOND's runs off a 36-column screen.
  if not toast then
    for i = 1, #DENOM_COL do
      local lit = (st.pressIdx == i and st.tick < st.pressUntil)
      local bg  = lit and GREEN or BLACK
      local ink = lit and BLACK or WHITE
      writeIn("Withdraw", 13, DENOM_COL[i] + 1, DENOM_WC, ink, bg)
      writeIn(rates.DENOMS[i].label, 14, DENOM_COL[i] + 1, DENOM_WC, ink, bg)
      -- iron/gold prices nudged a cell right: centring a 4-char price in 9 cells lands it a cell left
      -- of the 3- and 5-char ones, so the column read ragged.
      local nudge = (i == 2 or i == 3) and 1 or 0
      writeIn("$" .. rates.DENOMS[i].value, 16, DENOM_COL[i] + nudge, DENOM_WC, ink, bg)
    end
  end

  -- qty labels in the TOP cell of the button (row 18)
  for i = 1, #QTY_COL do
    local sel = (i == st.qtyIdx)
    writeIn(rates.QTYS[i] .. "x", 18, QTY_COL[i], QTY_WC, sel and BLACK or WHITE, sel and YELLOW or GRAY)
  end

  -- DEPOSIT label — middle row of the 3-cell button, on the steel face
  writeCentered("DEPOSIT", 23, BLACK, LIGHT_GRAY)

  -- toast text, over everything
  if st.tick < st.toastUntil then
    writeCentered("PLACE YOUR DEPOSIT", 13, WHITE, BLACK)
    writeCentered("IN THE DEPOSIT BOX", 15, WHITE, BLACK)
  end

  win.setVisible(true)
end

-- ACTIVE session: the 0.05s timer loop, run by idle_runner while a player is in the zone. Returns
-- "sleep" when the zone empties (and nothing is still owed to the floor), or "quit" on the
-- operator's Q. NOTHING here may block — see [[event-pump-reentrancy]].
local function play(_, pres)
  local econ = cage_econ.new{ zone = CFG.zone }
  local tick = 0
  local qtyIdx = 1                          -- a play()-local, so qty resets to 1x on every wake
  local pressIdx, pressUntil = 0, 0
  local depUntil, toastUntil = 0, 0
  local dispBal = 0
  local lastPlayer = econ.status().player

  -- loads[i] = items dropper i still owes the floor; nextDropper = where the next tap's round-robin
  -- starts, so consecutive taps keep the rotation even instead of always reloading dropper 1.
  local loads = {}
  for i = 1, hw.nDroppers do loads[i] = 0 end
  local nextDropper = 1
  local pulsed = false        -- is the line currently HIGH because WE raised it this cycle?

  -- Never inherit a line left HIGH. CC persists redstone output when a program exits, and Ctrl+T, an
  -- uncaught error and a chunk unload all skip the Q path's pulseOff (Ctrl+T doesn't reboot, so the
  -- output survives). Starting high means the first pulseOn is no rising edge: the first cycle would
  -- be debited and eject nothing. The tick loop's own os.pullEvent is the yield that flushes this.
  hw.pulseOff()

  local function owed()
    local n = 0
    for i = 1, #loads do n = n + loads[i] end
    return n
  end

  local function state()
    local est = econ.status()   -- player/balance live on the session now, not on econ itself
    return {
      hasCard    = est.player ~= nil,
      tick       = tick,
      dispBal    = dispBal,
      balTarget  = est.balance or 0,
      qtyIdx     = qtyIdx,
      pressIdx   = pressIdx,
      pressUntil = pressUntil,
      depUntil   = depUntil,
      toastUntil = toastUntil,
      paying     = vault.anyLoaded(loads),
      owed       = owed(),
    }
  end

  local function render() drawFrame(state(), econ) end

  -- A material tap. THE ORDERING INVARIANT, and it is not negotiable:
  --   stock check -> debit -> move -> refund the shortfall.
  -- Never move metal before debiting; never debit before confirming the vault has the metal.
  local function withdraw(i)
    local denom = rates.DENOMS[i]
    local qty   = rates.QTYS[qtyIdx]

    -- ONE vault listing for the whole tap: the stock check's, handed straight to loadDroppers below.
    -- `list()` is a main-thread task ≈ a whole game tick with the play loop frozen, so a second one
    -- is 50ms of dead monitor bought for nothing. Nothing else writes this vault, and pushItems
    -- reports what really moved, so the shortfall path stays honest even if it goes stale.
    local tList = os.epoch("utc")
    local listing = hw.vaultList()
    local have = vault.countItem(listing, denom.item)                 -- 1. stock check
    local tStock = os.epoch("utc")
    if have < qty then
      -- a vault deny is a deny: `denied` is what tints the status pink, so all four refusals
      -- (NEED $x / HUB OFFLINE / BAD CARD / VAULT: n) read the same way.
      econ.denied, econ.msg = true, "VAULT: " .. have .. " " .. denom.label
      return
    end

    local cost = denom.value * qty
    if econ.tryDebit(cost) ~= "ok" then return end                    -- 2. debit (fail closed)
    local tDebit = os.epoch("utc")
    -- money moved -> the button lights green. A DENIED withdraw never gets here, and never flashes.
    pressIdx, pressUntil = i, tick + FLASH_TICKS
    -- DRAW IT NOW, before the droppers. The caller renders only after withdraw() RETURNS, so this
    -- flash used to be decided at ~45ms and not appear until ~226ms — the whole tap read as an
    -- unresponsive monitor that eventually lit up. Everything above this line is cheap (one list +
    -- the hub round-trip); everything below is ~50ms per dropper of frozen loop. Painting here costs
    -- nothing (terminal writes are computer-thread) and puts the feedback before the stall instead of
    -- after it. It is also HONEST: the debit has already succeeded, so green means what it always
    -- meant — money moved. Do NOT hoist it above the debit to shave the last 45ms: a denied tap would
    -- then flash "paid" at a player who wasn't.
    render()

    local perDropper = {}
    for d = 1, hw.nDroppers do perDropper[d] = 0 end
    local _, nxt = vault.addLoad(perDropper, qty, nextDropper)        -- plan the spread
    nextDropper = nxt                                                 -- advance the rotation

    local loadedPer, loaded = hw.loadDroppers(denom.item, perDropper, listing)  -- 3. move
    -- The whole tap is ONE frozen stretch of monitor: every number below is time the play loop spent
    -- parked on a main-thread task or a hub round-trip, drawing nothing. Expect `load` ≈ 50ms per
    -- dropper this tap fills, times the number of vault SLOTS it draws from — a fragmented vault
    -- costs a tick per extra slot boundary, and a shortfall buys one more listing to retry on.
    local tLoad = os.epoch("utc")
    dbg("withdraw %s x%d: stock=%dms debit=%dms load=%dms (loaded %d/%d) TOTAL=%dms",
        denom.key, qty, tStock - tList, tDebit - tStock, tLoad - tDebit, loaded, qty, tLoad - tList)
    -- Shower what LANDED, never `qty`: pulsing for items that were never loaded would drain the
    -- counter against empty droppers and desync the count-down from the metal on the floor.
    for d = 1, #loadedPer do loads[d] = loads[d] + loadedPer[d] end
    if loaded < qty then econ.refund((qty - loaded) * denom.value) end -- 4. refund the shortfall
  end

  -- The DEPOSIT tap. Junk is never in `moves`, so it stays exactly where the player left it.
  local function deposit()
    depUntil = tick + FLASH_TICKS
    local total, moves = vault.valueListing(hw.depositList(), rates)
    if total == 0 then                       -- an empty box is the ONE case that needs TEACHING,
      toastUntil = tick + TOAST_TICKS        -- not an error. Say where the items go.
      -- Clear BOTH, cage_econ's idiom: a stale `denied` from an earlier deny would tint the next
      -- non-deny status ("PAYING n") pink.
      econ.denied, econ.msg = false, nil
      return
    end
    hw.sweepToVault(moves)
    local bal = econ.deposit(total)          -- credit is guaranteed (outboxed if the hub is down)
    if bal and not econ.msg then econ.msg = "DEPOSITED $" .. total end
  end

  updateGradient(0)
  render()
  local timer = os.startTimer(TICK)
  -- `cage debug` only: the gap between rendered frames. The tick is 0.05s, so anything much over
  -- ~100ms is the loop parked somewhere instead of drawing — which is exactly what a stuttering
  -- monitor IS. Reporting `owed` alongside says whether the stall lands on the tap or on the shower:
  -- the shower itself makes no main-thread calls, so a gap with owed>0 and no withdraw line next to
  -- it means the cause is NOT the droppers.
  local lastFrame = os.epoch("utc")

  while true do
    local ev = { os.pullEvent() }
    if ev[1] == "timer" and ev[2] == timer then
      tick = tick + 1
      updateGradient(tick * 0.05)

      -- THE SHOWER — and the two reasons it is shaped exactly like this. Do not "simplify" it.
      --
      -- 1. A pulse NEEDS A YIELD between on and off. `redstone.setOutput` only writes CC's
      --    *internal* state + a dirty flag; the world is synced afterwards, on the computer tick,
      --    by diffing external-vs-internal per side. `setOutput(true); setOutput(false)` in one
      --    tick therefore leaves internal exactly as it was = no diff = NO block update = the
      --    droppers never fire. That is why on/off are split across ticks of this loop: the yield
      --    at `os.pullEvent` is the flush boundary. It shipped as a same-tick toggle once and made
      --    a money shredder — every withdrawal debited the card and dropped nothing.
      -- 2. A dropper ejects on the RISING EDGE only and then has a 4-game-tick (0.2s) cooldown;
      --    the `triggered` blockstate blocks re-trigger until the line falls. So: 6 ticks per item
      --    (2 high, 4 low = 0.3s) — a 50% margin over the cooldown so server lag can't swallow an
      --    edge. Pulsing every tick would run 4x the droppers' physical rate and strand most of
      --    the paid-for metal inside them forever.
      --
      -- `loads` decrements on the FALLING edge: one completed cycle = one item actually ejected,
      -- so the count-down tracks the metal on the floor. Taps ADD to `loads` mid-shower, so bursts
      -- overlap and spamming compounds. NO `sleep()` / nested `os.pullEvent` here — that would
      -- swallow the tick timer and touch events, the [[event-pump-reentrancy]] freeze.
      -- `pulsed` is the whole point: NEVER decrement without having actually raised the line. A tap
      -- fills `loads` at an arbitrary tick, so the very next tick can be phase 2 — and an unguarded
      -- `elseif phase == 2` would then pulseOff+decrement having never pulsed ON. No rising edge, no
      -- ingot, but the counter moves: the player pays, nothing drops, and the item stays stuck in the
      -- dropper to fall out during someone ELSE's withdrawal (desyncing the count-down from the
      -- floor). That was ~1 tap in 3. Waiting for the next phase 0 costs at most 5 ticks (0.25s).
      if vault.anyLoaded(loads) then
        local phase = tick % 6
        if phase == 0 then
          hw.pulseOn(); pulsed = true
        elseif phase == 2 and pulsed then
          hw.pulseOff(); pulsed = false
          loads = vault.pulseLoads(loads)     -- decrement ONLY after a real rising edge
        end
      end

      local est = econ.status()              -- player/balance live on the session, not on econ
      if est.player ~= lastPlayer then       -- a fresh card starts its count-up from zero
        lastPlayer, dispBal = est.player, 0
      end
      dispBal = easeToward(dispBal, est.balance or 0)

      render()
      if DEBUG then
        local now = os.epoch("utc")
        if now - lastFrame > 100 then
          dbg("TICK GAP %dms  owed=%d", now - lastFrame, owed())
        end
        lastFrame = now
      end
      -- Don't sleep mid-shower: the droppers are holding metal the player already paid for, and
      -- deep sleep would strand it (loads resets to 0 on the next wake).
      if pres.gone() and not vault.anyLoaded(loads) then restorePalette(); return "sleep" end

      timer = os.startTimer(TICK)
    elseif ev[1] == "rednet_message" then
      pres.fromEvent(ev); econ.onEvent(ev)
    elseif ev[1] == "disk" or ev[1] == "disk_eject" then
      econ.onEvent(ev)                       -- card in/out: re-read + a hub round-trip, so re-arm
      os.cancelTimer(timer); timer = os.startTimer(TICK)
    elseif ev[1] == "monitor_touch" then
      -- No card => the controls aren't on screen, so there is nothing to tap.
      if econ.status().player then
        local kind, i = hitTest(ev[3], ev[4])
        if kind == "qty" then qtyIdx = i
        elseif kind == "denom" then withdraw(i)
        elseif kind == "deposit" then deposit() end
        if kind then
          render()
          -- This handler just ran chest.list() / pushItems / wallet.debit — server-thread calls and
          -- rednet round-trips. The docs don't say whether those pump the event queue while they
          -- wait, and if they do they can swallow the pending tick timer and stall the loop
          -- forever. Don't gamble on it: re-arm. One timer per tap buys a whole failure class.
          os.cancelTimer(timer); timer = os.startTimer(TICK)
        end
      end
    elseif ev[1] == "key" and ev[2] == keys.q then
      -- Drop the line before leaving. Quitting between phase 0 and 2 would otherwise leave it HIGH,
      -- and CC persists redstone output after the program exits — so the next rising edge never
      -- happens and the droppers sit dead until something else toggles it.
      hw.pulseOff()
      restorePalette(); return "quit"
    end
  end
end

require("idle_runner").run{
  name = "cage", monitor = mon, zone = CFG.zone, play = play,
  pos = CFG.pos, dim = CFG.dim, range = tonumber(CFG.range),
}
