-- match.lua — the reusable multi-screen match framework: LOBBY -> PLAY -> RESULTS.
--
--   require("idle_runner").run{
--     name = "pong", monitor = mon,
--     play = require("match").run{ title = "PONG", seatLabels = {"LEFT","RIGHT"}, ... },
--   }
--
-- A game supplies ONE function -- play(ctx) -> scores -- and gets the lobby, the ante, the pot, the
-- results screen and the money animation for free. Pong is its first consumer; any future 2-4
-- player game is the same shape.
--
-- MATCH OWNS THE EVENT PUMP; play() NEVER CALLS os.pullEvent. This is the single most important
-- boundary in the design. Event-pump re-entrancy is this project's most expensive recurring bug
-- class ([[event-pump-reentrancy]]: the floppy-swap freeze cost an entire session), and a game
-- author must not be able to get it wrong. play() gets ctx.tick(), which yields exactly one frame
-- and returns false when the match must abort.
--
-- Screens are DEBUG-GRADE NATIVE TEXT this session, on purpose; the art pass is separate.
local ml      = require("match_logic")
local lobbyUI = require("lobby")
local counter = require("counter")

local TICK         = 0.05
local RESULT_TICKS = 160   -- ~8s before results auto-returns to the lobby
local FLASH_TICKS  = 20    -- ~1s win flash over the finished board, before the money screen

local M = {}

local TINT = { up = colors.yellow, down = colors.pink, rest = colors.white }

-- The results screen's seat band sits HIGHER and runs LONGER than the lobby's: it drops the READY
-- row and gains the counter (approved design, tools/pong-preview.html).
local RES_BAND_Y, RES_BAND_H = 5, 12

-- cfg.deps = { mp_econ =, window =, os = } -- test injection only; production omits it.
function M.run(cfg)
  local deps   = cfg.deps or {}
  local mpEcon = deps.mp_econ or require("mp_econ")
  local windowApi = deps.window or window
  local osApi  = deps.os or os

  local seatLabels = cfg.seatLabels or {}
  local nSeats     = #seatLabels

  -- the value idle_runner calls: play(mon, pres) -> "sleep" | "quit"
  return function(mon, pres)
    local W, H = mon.getSize()
    local win = windowApi.create(mon, 1, 1, W, H, true)   -- offscreen buffer -> no flicker

    local econ = mpEcon.new{
      drives = cfg.drives, ante = cfg.ante,
      minSeats = cfg.minSeats, maxSeats = cfg.maxSeats,
    }

    local flashTicks  = cfg.flashTicks  or FLASH_TICKS
    local resultTicks = cfg.resultTicks or RESULT_TICKS

    local phase   = "lobby"          -- "lobby" | "results"
    local ready   = ml.newReady(nSeats)
    local message = nil
    local exit    = nil              -- "sleep" | "quit" once decided
    local rows, counters, headline, freeLabel, resultsTicks = nil, nil, nil, nil, 0
    local timer = osApi.startTimer(TICK)

    -- ---- rendering -------------------------------------------------------
    local function lobbyView()
      local st = econ.status()
      local seats = {}
      for i = 1, nSeats do
        local s = st.seats[i] or {}
        seats[i] = {
          label   = seatLabels[i],
          id      = s.player,
          balance = s.balance,
          status  = s.offline and "OFFLINE" or nil,
          ready   = ready[i],
        }
      end
      return {
        title = cfg.title, ante = cfg.ante, seats = seats,
        goEnabled = ml.allReady(ready), message = message,
      }
    end

    -- The win flash: a panel drawn OVER the finished rally, deliberately without clearing. The
    -- board the players were just watching stays visible underneath, so the moment reads as "that
    -- last point won it" rather than as a screen change. It is the beat between the rally and the
    -- money -- every game on this framework gets it for free.
    local function drawFlash(text)
      local w = #text + 4
      local x = math.floor((W - w) / 2) + 1
      local y = math.floor(H / 2) - 1
      win.setVisible(false)
      win.setBackgroundColor(colors.white)
      for dy = 0, 2 do
        win.setCursorPos(x, y + dy)
        win.write(string.rep(" ", w))
      end
      win.setTextColor(colors.black)
      win.setCursorPos(x + 2, y + 1)
      win.write(text)
      win.setBackgroundColor(colors.black)
      win.setVisible(true)
    end

    local function drawResults()
      win.setVisible(false)
      win.setBackgroundColor(colors.black)
      win.setTextColor(colors.white)
      win.clear()

      win.setCursorPos(2, 2); win.write(cfg.title .. " - RESULT")

      -- The verdict, on BOTH staked and free screens. Row 4 is deliberately ABOVE the net's
      -- protected span (rows 5-17): this string is centred and would otherwise cross col 29 and
      -- erase a cell of net, because native `write` sets the whole cell's background.
      if headline then
        win.setTextColor(colors.white)
        win.setCursorPos(math.max(1, math.floor((W - #headline) / 2) + 1), 4)
        win.write(headline)
      end

      lobbyUI.drawNet(win, RES_BAND_Y, RES_BAND_Y + RES_BAND_H - 1)

      for i = 1, #seatLabels do
        local row = rows and rows[i]
        lobbyUI.infoWrite(win, i, RES_BAND_Y, seatLabels[i], colors.lightGray)
        lobbyUI.infoWrite(win, i, RES_BAND_Y + 1,
                          (row and row.id or "anon"):sub(1, lobbyUI.ID_MAX),
                          (row and row.id) and colors.white or colors.gray)
        local c = counters and counters[i]
        if c then
          lobbyUI.infoWrite(win, i, RES_BAND_Y + 3, "$" .. tostring(c.value()), TINT[c.tint()])
        elseif freeLabel then
          -- A free match moved no money; label the panel so it does not read as broken or empty.
          lobbyUI.infoWrite(win, i, RES_BAND_Y + 3, freeLabel, colors.lightGray)
        end
      end

      -- The SAME rect as the lobby's GO, on purpose: the rematch button must be the same button in
      -- the same place so muscle memory carries between screens.
      lobbyUI.fillRect(win, lobbyUI.GO, colors.yellow)
      lobbyUI.centerIn(win, lobbyUI.GO, "GO", colors.black, colors.yellow)
      win.setBackgroundColor(colors.black)
      win.setVisible(true)
    end

    local function render()
      if phase == "lobby" then lobbyUI.draw(win, lobbyView())
      else drawResults() end
    end

    -- ---- returning to the lobby -------------------------------------------
    -- READY IS PER-MATCH CONSENT. Clearing it here, on the ONLY path back to the lobby, is what
    -- stops the next GO from anteing a player who already walked away.
    local function toLobby()
      econ.reset()
      phase, ready, message = "lobby", ml.newReady(nSeats), nil
      rows, counters, headline, freeLabel = nil, nil, nil, nil
    end

    -- ---- resolving --------------------------------------------------------
    -- A live pot must NEVER leave this loop unresolved. On the way out, whoever is ahead takes it --
    -- which is exactly what "the ante is forfeit" means when the player who walked off was losing.
    -- Without this, exiting mid-match debits every seat and credits nobody: the $ evaporates.
    local function resolve(scores)
      if econ.phase == "playing" then econ.finish(scores or {}) end
    end

    -- ---- the pump ---------------------------------------------------------
    -- The ONLY os.pullEvent in the framework. Returns when the frame timer fires, once `exit` is
    -- set, OR right after a monitor_touch is dispatched. That last case matters as much as the
    -- others: a touch handler (GO, a rematch tap) can change `phase` -- e.g. lobby -> results inside
    -- startMatch(), or results -> lobby inside toLobby(). If pump kept consuming events with the
    -- SAME onTouch closure after that, a second touch already queued for this tick would still be
    -- routed through the stale (pre-transition) handler instead of the one the new phase owns, so a
    -- rematch tap on the results screen could be misread as a second GO in the lobby. Returning after
    -- every touch hands control back to the phase loop, which re-picks the handler for the CURRENT
    -- phase before the next event is read.
    local function pump(onTouch)
      while not exit do
        local ev = { osApi.pullEvent() }
        local e = ev[1]

        if e == "timer" and ev[2] == timer then
          if pres.gone() then exit = "sleep"; return end
          timer = osApi.startTimer(TICK)
          return

        elseif e == "monitor_touch" then
          if onTouch then
            -- A handler can change `phase` (GO -> results, rematch -> lobby) and our closure was
            -- bound to the OLD phase. Return so the phase loop re-binds. WITHOUT THIS a second
            -- queued tap is dispatched through the stale lobby handler, where READY is still true,
            -- and it ANTES THE POT AGAIN -- a real second debit off one tap.
            onTouch(ev[3], ev[4])
            -- Re-arm AFTER the handler, not before: the handler reaches the hub and runs a NESTED
            -- event pump, which can swallow a pending timer. Arming first would hand it a timer to
            -- eat. Only the timer branch re-arms, so losing it blocks this loop forever
            -- ([[event-pump-reentrancy]]).
            timer = osApi.startTimer(TICK)
            render()
            return
          end
          -- No handler bound: play() owns both the screen and the clock. Returning here would let a
          -- tap advance the game's physics by a frame (breaking ctx.tick()'s "exactly one frame"
          -- contract), and render() would repaint the lobby over a live rally. Still re-arm.
          timer = osApi.startTimer(TICK)

        elseif e == "disk" or e == "disk_eject" then
          econ.onEvent(ev)
          timer = osApi.startTimer(TICK)   -- refreshCard reaches the hub: same reason as above
          if onTouch then render() end

        elseif e == "rednet_message" then
          pres.fromEvent(ev)

        elseif e == "key" and ev[2] == keys.q then
          exit = "quit"; return
        end
      end
    end

    -- ---- starting a match --------------------------------------------------
    local function startMatch()
      message = nil

      -- CAPTURE BEFORE start(). By the time results draws, the money has already moved (the ante
      -- debits here, the pot credits at finish), so the animation is a REPLAY. Reading balances
      -- after start() would animate from the post-ante number and the drain would never appear.
      local before = ml.captureBalances(econ.status())

      local res, reason, seat = econ.start()
      if res == "deny" then
        -- A deny never reaches cfg.play, so the touch branch's OWN re-arm (after this whole handler
        -- returns) is enough -- do not also re-arm here, or that re-arm becomes unfalsifiable.
        message = ml.denyMessage(reason, seat)
        render()
        return
      end

      -- econ.start() reaches the hub (wallet.debit) the same way the touch/disk branches' own nested
      -- calls do, and can swallow this loop's pending timer ([[event-pump-reentrancy]]). Re-arm here,
      -- not just in the touch branch after this handler returns: ctx.tick() below needs a valid
      -- outstanding timer for the ENTIRE match, and the touch branch's own re-arm cannot run until
      -- the whole match (every ctx.tick()) has already finished. Found via Fix 3's honest fake --
      -- without this a staked GO deadlocks the very first ctx.tick().
      timer = osApi.startTimer(TICK)

      local potBefore = econ.pot

      -- Run the game. ctx.tick() is the ONLY way play() yields.
      local ctx = {
        win = win, controls = cfg.controls, seats = seatLabels, target = cfg.target,
        tick = function()
          pump(nil)
          return exit == nil
        end,
      }
      -- A crash in a GAME's rally code must not evaporate a live pot. Without this, an error
      -- propagates out with phase == "playing", no resolve() runs, and every seat is debited with
      -- nobody paid. Resolve first, then re-raise so the supervisor still sees the real error.
      local ok, played = pcall(cfg.play, ctx)
      if not ok then
        resolve(nil)
        error(played, 0)
      end
      local scores = played or {}

      resolve(scores)
      local st = econ.status()

      -- THE WIN FLASH -- ~1s over the finished board before the money screen. Named by CARD ID when
      -- the winner has one: a player should see their own name at the moment they win.
      --
      -- PUMPED, never slept. A bare sleep(1) here would swallow presence and the quit key for a
      -- full second, and this project has paid for blocking calls inside a play loop more than once
      -- ([[event-pump-reentrancy]]).
      if not exit then
        local flash = ml.winnerText(seatLabels, st, scores)
        local held = 0
        while not exit and held < flashTicks do
          drawFlash(flash)
          pump(nil)
          held = held + 1
        end
      end

      -- The verdict headline shows on BOTH staked and free results. Once the counters settle to
      -- white a staked screen would otherwise carry no statement of who actually won.
      headline = ml.freeResultText(seatLabels, scores)

      if ml.staked(potBefore) then
        rows, freeLabel = ml.resultRows(seatLabels, before, st, scores), nil
        counters = {}
        for i, row in ipairs(rows) do
          if row.from and row.to then
            counters[i] = counter.new{ value = row.from }
            counters[i].setTarget(row.to)
          end
        end
      else
        rows, counters, freeLabel = nil, nil, "FREE MATCH"
      end

      phase, resultsTicks = "results", 0
      render()
    end

    -- ---- the phase loop ----------------------------------------------------
    render()
    while not exit do
      if phase == "lobby" then
        pump(function(x, y)
          local kind, i = lobbyUI.hitTest(x, y, nSeats)
          if kind == "ready" then
            ml.toggle(ready, i)
            message = nil
          elseif kind == "go" then
            -- The gate is enforced HERE, not merely drawn. A GO that looks inert must also BE
            -- inert -- this button spends real money.
            if ml.allReady(ready) then startMatch() end
          end
        end)

      else   -- results
        pump(function(x, y)
          -- nSeats = 0: the results screen has no READY buttons, so only GO can be hit.
          if lobbyUI.hitTest(x, y, 0) == "go" then
            toLobby()   -- skip straight to a rematch
          end
        end)
        if not exit and phase == "results" then
          if counters then
            for _, c in pairs(counters) do c.step() end
          end
          resultsTicks = resultsTicks + 1
          if resultsTicks >= resultTicks then toLobby() end
          render()
        end
      end
    end

    resolve(nil)   -- never leave a live pot behind on the way out
    return exit
  end
end

return M
