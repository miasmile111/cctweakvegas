-- mkinstaller.lua — write a reusable install floppy. Two modes:
--
--   mkinstaller               -> MASTER floppy: carries `update`. On any new computer,
--                                run it straight off the disk:  /disk/update slot
--                                (update self-updates + plants a local copy). Reusable forever.
--
--   mkinstaller slot [pong]   -> AUTO-INSTALL floppy for those packages. Insert into a new
--                                station (computer + drive + modem) and reboot -> it installs
--                                + self-registers + names the station. Remove the floppy.
--
-- Either way you only ever fetch update.lua from the web ONCE (here) — the floppy carries it.

local REPO = "https://raw.githubusercontent.com/miasmile111/cctweakvegas/main/src/"

local args = { ... }
if not http then error("http disabled — cannot fetch update.lua", 0) end

local drive = peripheral.find("drive")
if not drive then print("Put a floppy in a disk drive first (no drive found)."); return end
local dname = peripheral.getName(drive)
if not disk.isPresent(dname) or not disk.hasData(dname) then
  print("No writable floppy in the drive."); return
end
local mount = disk.getMountPath(dname)

-- fetch the current updater (the one thing that comes from the web)
local h, err = http.get(REPO .. "update.lua?cb=" .. os.epoch("utc"))
if not h then error("Could not fetch update.lua: " .. tostring(err), 0) end
local updateBody = h.readAll(); h.close()

local function write(path, body)
  local f = fs.open(path, "w"); f.write(body); f.close()
end

write(mount .. "/update", updateBody)

if #args == 0 then
  -- MASTER floppy: a startup that just plants `update` on the computer (belt-and-suspenders;
  -- you can also just run `/disk/update <pkg>` directly without rebooting).
  if fs.exists(mount .. "/pkg") then fs.delete(mount .. "/pkg") end
  write(mount .. "/startup", [[
-- master tools disk: copy `update` onto this computer.
local src
for _, name in ipairs(peripheral.getNames()) do
  if peripheral.getType(name) == "drive" and disk.hasData(name) then
    local mp = disk.getMountPath(name)
    if mp and fs.exists(mp .. "/update") and not fs.exists(mp .. "/pkg") then src = mp break end
  end
end
if not src then return end
if fs.exists("update") then fs.delete("update") end
fs.copy(src .. "/update", "update")
print("`update` installed. Run:  update <package>   e.g.  update slot")
]])
  disk.setLabel(dname, "cctweak:tools")
  print("Master floppy ready (cctweak:tools).")
  print("On a new computer:  /disk/update slot   (or reboot with it in to plant `update`).")
else
  -- AUTO-INSTALL floppy for the given package(s).
  write(mount .. "/pkg", table.concat(args, " "))
  write(mount .. "/startup", [[
-- installer disk (made by mkinstaller): copy update onto this computer, then run it.
local src
for _, name in ipairs(peripheral.getNames()) do
  if peripheral.getType(name) == "drive" and disk.hasData(name) then
    local mp = disk.getMountPath(name)
    if mp and fs.exists(mp .. "/pkg") then src = mp break end
  end
end
if not src then return end
if fs.exists("update") then fs.delete("update") end
fs.copy(src .. "/update", "update")
local pf = fs.open(src .. "/pkg", "r"); local pkgs = pf.readAll(); pf.close()
pkgs = pkgs:gsub("%s+$", "")
print("Installer disk: installing " .. pkgs .. " ...")
shell.run("update " .. pkgs)
print("Done. Remove the installer disk.")
]])
  disk.setLabel(dname, "install:" .. args[1])
  print("Auto-install floppy ready:  install:" .. args[1] .. "  (" .. table.concat(args, " ") .. ")")
  print("Insert it in a new station (computer + drive + modem) and reboot.")
end
