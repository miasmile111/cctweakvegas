-- card.lua — membership floppy read/write. A card = a mounted disk holding the file
-- /<mount>/ccvegas_card = serialize{ id=<string>, score=<number> }. No file => anonymous.
-- `score` is a display mirror only; the hub is authoritative (see wallet + hub).
--
-- Every read/write takes an OPTIONAL `drive` (a peripheral name). Omit it and you get the first
-- drive holding a disk -- exactly what this module did before multiplayer existed, which is what
-- lets slot/cage/issue keep calling read() and writeMirror() unchanged. Name a drive and you get
-- that one: a multi-seat station is N drives, and a seat must be able to read ITS card and no other.
local M = {}
local FILE = "ccvegas_card"

-- every disk drive attached, by peripheral name, SORTED.
--
-- Includes drives with NO disk: a drive is a SEAT, and an empty seat still exists -- filtering
-- them out here would make a cardless player disappear from the station rather than show up as an
-- anonymous seat. readAll() does the card filtering.
--
-- Sorted so seat order is stable across reboots FOR THIS STATION. It does NOT make names stable
-- across identically-built stations -- CC burns <type>_<n> indices on attach/detach, so the first
-- cage's droppers came up 1-4, not 0-3 ([[station-hardware-discovery]]). That is what the per-
-- station .cfg override exists for.
function M.drives()
  local out = {}
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "drive" then out[#out + 1] = name end
  end
  table.sort(out)
  return out
end

-- mount path of `drive`, or of the first drive holding a disk when `drive` is nil. nil if none.
local function mountPath(drive)
  if drive then
    if peripheral.getType(drive) ~= "drive" then return nil end
    local d = peripheral.wrap(drive)
    if not d or not d.isDiskPresent() then return nil end
    return d.getMountPath()
  end
  for _, name in ipairs(M.drives()) do
    local d = peripheral.wrap(name)
    if d and d.isDiskPresent() then
      local mp = d.getMountPath()
      if mp then return mp end
    end
  end
  return nil
end

-- read the card in `drive` (nil = the first drive with a disk).
-- Returns { id, score } or nil (no disk / blank / unreadable).
function M.read(drive)
  local mp = mountPath(drive); if not mp then return nil end
  local path = mp .. "/" .. FILE
  if not fs.exists(path) then return nil end
  local f = fs.open(path, "r"); if not f then return nil end
  local d = f.readAll(); f.close()
  local ok, t = pcall(textutils.unserialize, d)
  if ok and type(t) == "table" and type(t.id) == "string" then
    return { id = t.id, score = t.score }
  end
  return nil
end

-- every card on the station: { { drive, id, score }, ... } in drives() order.
-- Drives holding no readable card are omitted -- an empty seat has no card to report.
function M.readAll()
  local out = {}
  for _, name in ipairs(M.drives()) do
    local c = M.read(name)
    if c then out[#out + 1] = { drive = name, id = c.id, score = c.score } end
  end
  return out
end

-- write id + score to the card in `drive` (nil = first drive with a disk). true, or false,reason.
function M.write(id, score, drive)
  local mp = mountPath(drive); if not mp then return false, "no disk" end
  local f = fs.open(mp .. "/" .. FILE, "w")
  if not f then return false, "cannot open" end
  f.write(textutils.serialize({ id = id, score = score })); f.close()
  return true
end

-- update just the score mirror on `drive`'s card (id preserved). Best-effort.
function M.writeMirror(score, drive)
  local c = M.read(drive); if not c then return false, "no card" end
  return M.write(c.id, score, drive)
end

-- true for events that change disk state, so a play loop knows to re-read the card.
-- ev[2] is the drive's name/side -- a multi-seat station uses it to refresh only the seat that
-- actually changed (see card_session.onEvent).
function M.isCardEvent(ev)
  return type(ev) == "table" and (ev[1] == "disk" or ev[1] == "disk_eject")
end

return M
