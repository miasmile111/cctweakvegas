-- cage.lua — THE CAGE: the floor's cash desk, on ONE CC:Tweaked advanced monitor (2x2, 36x24 @0.5).
--   A member card's $ becomes real Minecraft metal, and metal becomes $. Bidirectional, flat rate,
--   hub-authoritative. Tap a qty (1x/5x/20x), tap a metal -> stock check, debit, the droppers spit
--   the ingots onto the floor and the big number counts DOWN. Fill the deposit chest and tap
--   DEPOSIT -> the metal is valued, swept to the vault, and the number counts UP.
--   Layout is the owner-approved tools/cage-preview.html, ported pixel for pixel.
--   Run:  cage        -> play (idle_runner parks it asleep until a player walks up)
--   Quit: Q on the computer's terminal.
--
-- Wiring (all names/sides live in `cage.cfg` — rewire without re-importing; see below):
--   * Computer + ADVANCED MONITOR 2x2 @ text scale 0.5 (= 36x24 cells, exactly square).
--   * DISK DRIVE beside the computer — the member card goes in it. No card, no kiosk.
--   * WIRED MODEM on the computer — carries rednet to the hub AND the peripheral network below.
--   * DEPOSIT CHEST on the wired network. Player-facing. Junk left in it is never touched.
--   * VAULT CHEST on the wired network. Deposits flow in, withdrawals flow out. Admin seeds it;
--     an empty vault denies withdrawals (diegetically correct for a cage).
--   * 2-3 DROPPERS, each with its OWN wired modem (pushItems only crosses the wired network) AND
--     redstone dust from ONE computer output side (`side`). All droppers share that single line, so
--     one pulse fires them all: ~1 item per non-empty dropper per pulse. Aim them at the floor.
--   * Every peripheral must be ATTACHED to the modem network (right-click each modem until it's red).
--     Run `peripherals` on the computer to list the network names, then fill in cage.cfg.
--
-- cage.cfg (optional, sits next to this program; `key=value`, `#` comments, droppers comma-separated):
--   deposit=minecraft:chest_0
--   vault=minecraft:chest_1
--   droppers=minecraft:dropper_0,minecraft:dropper_1,minecraft:dropper_2
--   side=back
--   monitor=monitor_0        # omit to auto-find the first attached monitor
--   zone=all

local font  = require("pixelfont")
local rates = require("cage_rates")
local sym   = require("cage_symbols")

-- ---- config defaults (override any of these in cage.cfg) --------------------
local CFG = {
  deposit  = "minecraft:chest_0",
  vault    = "minecraft:chest_1",
  droppers = { "minecraft:dropper_0", "minecraft:dropper_1", "minecraft:dropper_2" },
  side     = "back",     -- computer output side feeding the droppers' shared redstone line
  monitor  = nil,        -- nil = auto-find
  zone     = "all",      -- proximity zone this station answers to
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
  -- (The 1-subpixel left inset on the panel is intentional — it is what the owner approved.)
  for i = 1, #DENOM_COL do
    local lit = (st.pressIdx == i and st.tick < st.pressUntil)
    cv:fillRect((DENOM_COL[i] - 1) * 2 + 2, L.denomY, DENOM_WC * 2 - 2, L.denomH, lit and GREEN or BLACK)
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
  local scalars = { deposit = true, vault = true, side = true, monitor = true, zone = true }
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

local function findMon(name)
  if name then
    local m = peripheral.wrap(name)
    if not m or peripheral.getType(name) ~= "monitor" then
      error(("Monitor '%s' not found. Run `peripherals`, then fix monitor= in cage.cfg."):format(name), 0)
    end
    return m
  end
  local m = peripheral.find("monitor")
  if not m then
    error("No monitor attached. Attach the 2x2 advanced monitor, or set monitor= in cage.cfg.", 0)
  end
  return m
end

local mon = findMon(CFG.monitor)
mon.setTextScale(0.5)
local mw, mh = mon.getSize()
local win = window.create(mon, 1, 1, mw, mh, true)   -- offscreen buffer -> no flicker
local cv  = subpixel.new(win)

-- the hands: chests, droppers, the shared redstone line. A misconfigured cage must fail LOUDLY at
-- startup, not pretend to be a kiosk and eat someone's card balance.
local hw, hwErr = cage_hw.new(CFG)
if not hw then error(hwErr .. "\nRun `peripherals` and fix cage.cfg.", 0) end

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
  writeAt(econ.player, 2, 3, WHITE, bandAt(2))
  local status = econ.msg or (st.paying and ("PAYING " .. st.owed) or nil)
  if status then
    writeAt(status, 2, mw - #status, econ.denied and PINK or WHITE, bandAt(2))
  end

  -- each button reads as a sentence: "Withdraw / COPPER". Lowercase verb, SHOUTED noun — the metal
  -- is what you're picking, so the metal carries the weight. "Withdraw" is 8 chars in a 9-cell
  -- button: EXACTLY one cell of slack, and +1 uses it. At +2 the label spills onto the next button
  -- and DIAMOND's runs off a 36-column screen.
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
  local lastPlayer = econ.player

  -- loads[i] = items dropper i still owes the floor; nextDropper = where the next tap's round-robin
  -- starts, so consecutive taps keep the rotation even instead of always reloading dropper 1.
  local loads = {}
  for i = 1, hw.nDroppers do loads[i] = 0 end
  local nextDropper = 1

  local function owed()
    local n = 0
    for i = 1, #loads do n = n + loads[i] end
    return n
  end

  local function state()
    return {
      hasCard    = econ.player ~= nil,
      tick       = tick,
      dispBal    = dispBal,
      balTarget  = econ.balance or 0,
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

    local have = vault.countItem(hw.vaultList(), denom.item)          -- 1. stock check
    if have < qty then
      -- a vault deny is a deny: `denied` is what tints the status pink, so all four refusals
      -- (NEED $x / HUB OFFLINE / BAD CARD / VAULT: n) read the same way.
      econ.denied, econ.msg = true, "VAULT: " .. have .. " " .. denom.label
      return
    end

    local cost = denom.value * qty
    if econ.tryDebit(cost) ~= "ok" then return end                    -- 2. debit (fail closed)
    -- money moved -> the button lights green. A DENIED withdraw never gets here, and never flashes.
    pressIdx, pressUntil = i, tick + FLASH_TICKS

    local perDropper = {}
    for d = 1, hw.nDroppers do perDropper[d] = 0 end
    local _, nxt = vault.addLoad(perDropper, qty, nextDropper)        -- plan the spread
    nextDropper = nxt                                                 -- advance the rotation

    local loadedPer, loaded = hw.loadDroppers(denom.item, perDropper) -- 3. move
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
      econ.msg = nil
      return
    end
    hw.sweepToVault(moves)
    local bal = econ.deposit(total)          -- credit is guaranteed (outboxed if the hub is down)
    if bal and not econ.msg then econ.msg = "DEPOSITED $" .. total end
  end

  updateGradient(0)
  render()
  local timer = os.startTimer(TICK)

  while true do
    local ev = { os.pullEvent() }
    if ev[1] == "timer" and ev[2] == timer then
      tick = tick + 1
      updateGradient(tick * 0.05)

      -- the shower drains: ONE pulse per tick, every non-empty dropper spits one item. Taps ADD to
      -- `loads` mid-shower, so bursts overlap and spamming compounds. A blocking `for ... sleep()`
      -- here would swallow the tick timer and touch events — the [[event-pump-reentrancy]] freeze.
      if vault.anyLoaded(loads) then
        loads = vault.pulseLoads(loads)
        hw.pulse()
      end

      if econ.player ~= lastPlayer then      -- a fresh card starts its count-up from zero
        lastPlayer, dispBal = econ.player, 0
      end
      dispBal = easeToward(dispBal, econ.balance or 0)

      render()
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
      if econ.player then
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
      restorePalette(); return "quit"
    end
  end
end

require("idle_runner").run{
  name = "cage", monitor = mon, zone = CFG.zone, play = play,
}
