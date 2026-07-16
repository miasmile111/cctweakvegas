-- mkinstaller.lua — mint a reusable installer floppy for a station package.
--
-- Run on any computer with HTTP + a floppy in a disk drive.
-- Usage:  mkinstaller <package> [<package> ...]     e.g.  mkinstaller slot
--
-- The floppy gets: `update` (the updater), `pkg` (the package list), and a `startup`
-- that auto-installs on boot. To set up a NEW station: build computer + disk drive +
-- wired modem, insert this floppy, reboot -> it copies `update` onto the computer, runs
-- `update <package>`, which self-registers + names the station. Remove the floppy; the
-- drive is now free for member cards.

local REPO = "https://raw.githubusercontent.com/miasmile111/cctweakvegas/main/src/"

local args = { ... }
if #args == 0 then print("Usage: mkinstaller <package> [<package> ...]"); return end
if not http then error("http disabled — cannot fetch update.lua", 0) end

local drive = peripheral.find("drive")
if not drive then print("Put a floppy in a disk drive first (no drive found)."); return end
local dname = peripheral.getName(drive)
if not disk.isPresent(dname) or not disk.hasData(dname) then
  print("No writable floppy in the drive."); return
end
local mount = disk.getMountPath(dname)

-- fetch the current updater
local h, err = http.get(REPO .. "update.lua?cb=" .. os.epoch("utc"))
if not h then error("Could not fetch update.lua: " .. tostring(err), 0) end
local updateBody = h.readAll(); h.close()

local function write(path, body)
  local f = fs.open(path, "w"); f.write(body); f.close()
end

write(mount .. "/update", updateBody)
write(mount .. "/pkg", table.concat(args, " "))

-- the auto-installer that runs when the disk is present at boot
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
print("Installer floppy ready:  install:" .. args[1] .. "  (" .. table.concat(args, " ") .. ")")
print("Insert it in a new station (computer + drive + modem) and reboot to auto-install.")
