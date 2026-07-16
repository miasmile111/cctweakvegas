-- card.lua — membership floppy read/write. A card = a mounted disk holding the file
-- /<mount>/ccvegas_card = serialize{ id=<string>, score=<number> }. No file => anonymous.
-- `score` is a display mirror only; the hub is authoritative (see wallet + hub).
local M = {}
local FILE = "ccvegas_card"

-- find a disk drive with a disk in it; return its mount path (e.g. "/disk") or nil.
local function mountPath()
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "drive" then
      local d = peripheral.wrap(name)
      if d.isDiskPresent() and d.getMountPath() then
        return d.getMountPath()
      end
    end
  end
  return nil
end

-- read the card in the drive; returns { id, score } or nil (no disk / blank / unreadable).
function M.read()
  local mp = mountPath(); if not mp then return nil end
  local path = mp .. "/" .. FILE
  if not fs.exists(path) then return nil end
  local f = fs.open(path, "r"); local d = f.readAll(); f.close()
  local ok, t = pcall(textutils.unserialize, d)
  if ok and type(t) == "table" and type(t.id) == "string" then
    return { id = t.id, score = t.score }
  end
  return nil
end

-- write id + score to the card in the drive. Returns true, or false,reason.
function M.write(id, score)
  local mp = mountPath(); if not mp then return false, "no disk" end
  local f = fs.open(mp .. "/" .. FILE, "w")
  if not f then return false, "cannot open" end
  f.write(textutils.serialize({ id = id, score = score })); f.close()
  return true
end

-- update just the score mirror on the current card (id preserved). Best-effort.
function M.writeMirror(score)
  local c = M.read(); if not c then return false, "no card" end
  return M.write(c.id, score)
end

-- true for events that change disk state, so a play loop knows to re-read the card.
function M.isCardEvent(ev)
  return type(ev) == "table" and (ev[1] == "disk" or ev[1] == "disk_eject")
end

return M
