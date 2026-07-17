-- test_card.lua — multi-drive card reads against a FAKE peripheral network + filesystem.
--
-- card.read() used to take the FIRST drive with a disk, which baked single-card-per-station into
-- every gateway above it. These tests pin the two halves of the fix: `drive` is addressable, and
-- omitting it still means exactly what it meant before (the no-regression bar -- slot, cage and
-- issue all call read()/writeMirror() with no argument and must not change behaviour).
package.path = "src/lib/?.lua;test/?.lua;" .. package.path
local t = require("runner")

-- ---- fake CC globals -------------------------------------------------------
local DRIVES = {}   -- name -> { type = "drive", mount = "/disk" | nil }
local FILES  = {}   -- path -> contents

_G.peripheral = {
  getNames = function()
    local n = {}
    for k in pairs(DRIVES) do n[#n + 1] = k end
    table.sort(n)
    return n
  end,
  getType = function(name) return DRIVES[name] and DRIVES[name].type or nil end,
  wrap = function(name)
    local d = DRIVES[name]
    if not d then return nil end
    return {
      isDiskPresent = function() return d.mount ~= nil end,
      getMountPath  = function() return d.mount end,
    }
  end,
}

_G.fs = {
  exists = function(p) return FILES[p] ~= nil end,
  open = function(p, mode)
    if mode == "r" then
      if not FILES[p] then return nil end
      return { readAll = function() return FILES[p] end, close = function() end }
    end
    local buf = {}
    return {
      write = function(s) buf[#buf + 1] = s end,   -- card.lua calls f.write(s), not f:write(s)
      close = function() FILES[p] = table.concat(buf) end,
    }
  end,
}

_G.textutils = {
  serialize = function(v) return ("{id=%q,score=%s}"):format(v.id, tostring(v.score)) end,
  unserialize = function(s)
    local f = loadstring("return " .. s)
    if not f then return nil end
    local ok, v = pcall(f)
    return ok and v or nil
  end,
}

local card = require("card")

local function reset()
  DRIVES, FILES = {}, {}
end

-- put a drive on the network. `mount` nil = drive with NO disk (an empty seat).
local function addDrive(name, mount)
  DRIVES[name] = { type = "drive", mount = mount }
end

local function putCard(mount, id, score)
  FILES[mount .. "/ccvegas_card"] = ("{id=%q,score=%s}"):format(id, tostring(score))
end

-- ---- drives(): EVERY drive, sorted -- an empty seat is still a seat ----
do
  reset()
  addDrive("drive_1", "/disk2")   -- deliberately out of order + a non-drive peripheral
  addDrive("drive_0", "/disk")
  DRIVES["monitor_0"] = { type = "monitor" }
  local d = card.drives()
  t.eq(#d, 2, "drives() ignores non-drive peripherals")
  t.eq(d[1], "drive_0", "drives() is sorted (stable seat order across reboots)")
  t.eq(d[2], "drive_1", "drives() is sorted")
end

do
  reset()
  addDrive("drive_0", nil)        -- no disk
  addDrive("drive_1", "/disk")
  local d = card.drives()
  t.eq(#d, 2, "drives() returns a drive with NO disk -- a seat with no card is still a seat")
  t.eq(d[1], "drive_0", "the empty drive keeps its seat position")
end

-- ---- read(drive): addressable ----
do
  reset()
  addDrive("drive_0", "/disk");  putCard("/disk", "alice", 500)
  addDrive("drive_1", "/disk2"); putCard("/disk2", "bob", 120)
  t.eq(card.read("drive_1").id, "bob", "read(drive) reads THAT drive")
  t.eq(card.read("drive_1").score, 120, "read(drive) carries the score mirror")
  t.eq(card.read("drive_0").id, "alice", "read(drive) reads THAT drive")
end

-- ---- read(nil): the no-regression bar -- still the first drive with a disk ----
do
  reset()
  addDrive("drive_0", nil)         -- empty drive sorts FIRST but holds no card
  addDrive("drive_1", "/disk2"); putCard("/disk2", "bob", 120)
  t.eq(card.read().id, "bob", "read(nil) skips a diskless drive and finds the first CARD")
end

do
  reset()
  addDrive("drive_0", "/disk");  putCard("/disk", "alice", 500)
  addDrive("drive_1", "/disk2"); putCard("/disk2", "bob", 120)
  t.eq(card.read().id, "alice", "read(nil) is the FIRST drive with a disk -- unchanged behaviour")
end

do
  reset()
  t.eq(card.read(), nil, "no drives at all -> nil, not an error")
  addDrive("drive_0", nil)
  t.eq(card.read(), nil, "a drive with no disk -> nil")
  addDrive("drive_1", "/disk2")
  t.eq(card.read(), nil, "a disk with no card file -> nil (a blank floppy is not a card)")
end

do
  reset()
  addDrive("drive_0", "/disk")
  FILES["/disk/ccvegas_card"] = "this is not lua"
  t.eq(card.read(), nil, "an unreadable card -> nil, not a crash")
  FILES["/disk/ccvegas_card"] = "{score=5}"
  t.eq(card.read(), nil, "a card with no id is not a card")
end

do
  reset()
  addDrive("drive_0", "/disk"); putCard("/disk", "alice", 500)
  t.eq(card.read("drive_9"), nil, "read() of a drive that isn't attached -> nil, not a crash")
  DRIVES["monitor_0"] = { type = "monitor" }
  t.eq(card.read("monitor_0"), nil, "read() of a non-drive peripheral -> nil, not a crash")
end

-- ---- readAll(): only drives holding a card ----
do
  reset()
  addDrive("drive_0", "/disk");  putCard("/disk", "alice", 500)
  addDrive("drive_1", nil)                                  -- empty seat: skipped
  addDrive("drive_2", "/disk3"); putCard("/disk3", "bob", 120)
  local all = card.readAll()
  t.eq(#all, 2, "readAll() skips drives with no card")
  t.eq(all[1].drive, "drive_0", "readAll() carries the drive name")
  t.eq(all[1].id, "alice", "readAll() carries the id")
  t.eq(all[2].id, "bob", "readAll() is in drives() order")
  t.eq(all[2].drive, "drive_2", "readAll() carries the drive name")
end

do
  reset()
  t.eq(#card.readAll(), 0, "readAll() with no drives -> empty list")
end

-- ---- write / writeMirror are drive-addressable, and the id survives a mirror write ----
do
  reset()
  addDrive("drive_0", "/disk");  putCard("/disk", "alice", 500)
  addDrive("drive_1", "/disk2"); putCard("/disk2", "bob", 120)
  t.ok(card.writeMirror(640, "drive_1"), "writeMirror(score, drive) writes THAT drive")
  t.eq(card.read("drive_1").score, 640, "the mirror landed")
  t.eq(card.read("drive_1").id, "bob", "writeMirror preserves the id")
  t.eq(card.read("drive_0").score, 500, "and did NOT touch the other drive")

  t.ok(card.write("carol", 10, "drive_0"), "write(id, score, drive) writes THAT drive")
  t.eq(card.read("drive_0").id, "carol", "write landed on the addressed drive")
  t.eq(card.read("drive_1").id, "bob", "and did not touch the other drive")
end

do
  reset()
  addDrive("drive_0", "/disk"); putCard("/disk", "alice", 500)
  t.ok(card.writeMirror(700), "writeMirror(score) with no drive still means the first drive")
  t.eq(card.read().score, 700, "the no-arg mirror landed")

  reset()
  t.ok(not card.write("alice", 1), "write with no drive present -> false, not a crash")
  t.ok(not card.writeMirror(1), "writeMirror with no card -> false, not a crash")
end

t.done()
