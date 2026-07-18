-- match_logic.lua — the pure half of the match state machine. No peripherals, no drawing, no
-- events; match.lua is the impure runner around it (the idle_logic / idle_runner split).
--
-- Everything here is a decision the state machine makes, hoisted out so it can be tested without
-- a monitor, a hub or an event pump.
local M = {}

-- ---- ready flags -----------------------------------------------------------
-- READY IS PER-MATCH CONSENT, NEVER A STICKY FLAG. If it survived a match, a player who walked away
-- is still "ready" and the next GO antes their card for a game they are not at. That is a money
-- bug, not a UI wrinkle -- every path back to the lobby calls newReady().
function M.newReady(n)
  local r = {}
  for i = 1, (n or 0) do r[i] = false end
  return r
end

function M.toggle(ready, i)
  if ready[i] ~= nil then ready[i] = not ready[i] end
  return ready
end

-- GO is live only when EVERY seat has consented. An empty table is never ready -- a station with no
-- seats must not present a live GO.
function M.allReady(ready)
  if #ready == 0 then return false end
  for i = 1, #ready do
    if not ready[i] then return false end
  end
  return true
end

-- ---- balance capture -------------------------------------------------------
-- The results screen REPLAYS a completed transaction: the ante was debited at GO and the pot
-- credited at finish, so by the time results draws, the money has already moved. Capture each
-- seat's balance immediately BEFORE mp_econ.start() or there is nothing honest to animate from.
-- An anonymous seat captures nil, not 0: it has no balance, and 0 would animate a drain from broke.
function M.captureBalances(status)
  local out = {}
  for i, s in ipairs(status.seats) do out[i] = s.balance end
  return out
end

-- ---- deny copy -------------------------------------------------------------
-- The three deny states must never collapse into one. Telling a player holding $500 that they are
-- INSUFFICIENT because the hub was unreachable is a lie about money, and this project has shipped
-- that bug twice (kb/economy.md lesson 7).
--
-- ASCII ONLY, capped at 55. The line is native cell-text on a 57-cell canvas (one cell of margin
-- each side), and an em dash is not reliably in CC's charset -- it renders as a box.
M.MSG_MAX = 55

function M.denyMessage(reason, seat)
  local msg
  if reason == "timeout" then
    msg = "HUB OFFLINE - nobody charged"
  elseif reason == "already playing" then
    msg = "MATCH ALREADY RUNNING"
  else
    msg = ("SEAT %d: %s - all antes REFUNDED"):format(seat or 0, tostring(reason):upper())
  end
  return msg:sub(1, M.MSG_MAX)
end

-- ---- results ---------------------------------------------------------------
function M.staked(potBefore)
  return (potBefore or 0) > 0
end

-- Best score wins; a tie takes the lowest seat index. Pong cannot tie at first-to-5, so this is a
-- guard for an aborted match (both on 0), not a tournament rule.
local function bestSeat(n, scores)
  local best, bestScore = 1, nil
  for i = 1, n do
    local sc = scores[i] or 0
    if bestScore == nil or sc > bestScore then best, bestScore = i, sc end
  end
  return best
end

M.bestSeat = bestSeat

-- The win flash: a 1-second panel over the finished rally, before the results screen. It names the
-- winner by their CARD ID when there is one -- a player should see their own name at the moment
-- they win, not a seat number. An anonymous seat has no id, so it falls back to the seat label
-- rather than rendering "anon WON!".
M.FLASH_MAX = 24   -- keeps the panel inside the canvas whatever a player called themselves

function M.winnerText(seatLabels, status, scores)
  local i = bestSeat(#seatLabels, scores)
  local s = (status.seats or {})[i] or {}
  local who = s.player or seatLabels[i] or ("SEAT " .. i)
  local suffix = " WON!"
  if #(who .. suffix) > M.FLASH_MAX then
    who = who:sub(1, M.FLASH_MAX - #suffix)
  end
  return who .. suffix
end

-- A free match moved no money, so there is nothing to animate -- it just names the winner.
function M.freeResultText(seatLabels, scores)
  return seatLabels[bestSeat(#seatLabels, scores)] .. " PLAYER WON"
end

-- One row per seat: where its counter starts and where it lands. An anonymous seat still gets a row
-- (it played) but has nothing to animate at either end.
function M.resultRows(seatLabels, before, status, scores)
  local rows = {}
  for i = 1, #status.seats do
    local s = status.seats[i]
    rows[i] = {
      seat  = i,
      label = seatLabels[i] or ("SEAT " .. i),
      id    = s.player,
      from  = before[i],
      to    = s.balance,
      score = scores[i] or 0,
    }
  end
  return rows
end

return M
