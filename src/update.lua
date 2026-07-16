-- update.lua — install/update this station's packages from the canonical repo, and
-- auto-register its identity (a unique label like slot2) with the hub.
--
-- Usage:  update <package> [<package> ...]     e.g.  update slot
--         update                                (re-pull whatever is already installed)
--
-- WHY http.get, not wget: `wget <url> <name>` REFUSES to overwrite an existing file, and
-- raw.githubusercontent.com caches ~5 min per IP. We overwrite freely and cache-bust every
-- fetch (?cb=<epoch>) so `update` always lands the newest commit.
--
-- ONE-TIME on a fresh computer (or use an installer floppy — see mkinstaller):
--   wget https://raw.githubusercontent.com/miasmile111/cctweakvegas/main/src/update.lua update
--   update slot
--
-- Preflight (fails loudly): a WIRED MODEM is always required (rednet). A player station
-- (slot, pong, ...) also requires a DISK DRIVE (member cards). Infra like `hub` needs no drive.
-- Hub offline -> installs anyway but leaves the station UNREGISTERED (no name) until re-run.

local REPO      = "https://raw.githubusercontent.com/miasmile111/cctweakvegas/main/src/"
local PROTO     = "ccvegas"
local INSTALLED = ".installed"   -- local record of which packages live on this computer

-- ---------------------------------------------------------------- helpers ----
local function fetch(subpath)
  local url = REPO .. subpath .. "?cb=" .. os.epoch("utc")   -- cache-bust every fetch
  local h, err = http.get(url)
  if not h then return nil, err end
  local body = h.readAll(); h.close()
  return body
end

local function save(name, body)
  local f = fs.open(name, "w"); f.write(body); f.close()
end

local function findWiredModem()
  return peripheral.find("modem", function(_, m) return not m.isWireless() end)
end

local function loudBanner(title)
  local bar = ("="):rep(#title + 2)
  print(bar); print(" " .. title); print(bar)
end

-- ---------------------------------------------------- preflight: http --------
if not http then
  error("http API disabled — the pack must allow HTTP. Cannot update.", 0)
end

-- --------------------------------------- work out which packages to install --
local requested = { ... }
if #requested == 0 and fs.exists(INSTALLED) then
  for line in io.lines(INSTALLED) do
    line = line:match("^%s*(%S+)%s*$")
    if line then requested[#requested + 1] = line end
  end
end
if #requested == 0 then
  print("Usage: update <package> [<package> ...]   e.g.  update slot")
  print("(or run `update` with no args once packages are installed)")
  return
end

-- ------------------------------------------------ fetch the package manifest --
local manBody, manErr = fetch("packages.lua")
if not manBody then error("Could not fetch package manifest: " .. tostring(manErr), 0) end
save("packages", manBody)
local ok, PACKAGES = pcall(dofile, "packages")
if not ok or type(PACKAGES) ~= "table" then
  error("Package manifest is invalid: " .. tostring(PACKAGES), 0)
end

-- does anything we're installing make this a player station (needs a disk drive)?
local needsDrive = false
for _, pkg in ipairs(requested) do
  local def = PACKAGES[pkg]
  if def and def.station then needsDrive = true end
end

-- ------------------------------------------ preflight: required hardware -----
local modem = findWiredModem()
local drive = peripheral.find("drive")
if not modem or (needsDrive and not drive) then
  if needsDrive then loudBanner("I need a disk drive and wired modem!")
  else               loudBanner("I need a wired modem!") end
  print("Missing on this station:")
  if not modem then print("  - a WIRED MODEM (for the rednet network)") end
  if needsDrive and not drive then print("  - a DISK DRIVE  (for member cards)") end
  print("Attach them (modem on a network cable), then re-run `update`.")
  return                                   -- hard stop: not a valid station yet
end

-- -------------------------------------------------------- install the files --
local installedNow, stations, failed = {}, {}, 0
for _, pkg in ipairs(requested) do
  local def = PACKAGES[pkg]
  if not def then
    print("FAIL  unknown package '" .. pkg .. "'")
    failed = failed + 1
  else
    print("Installing package '" .. pkg .. "':")
    for _, file in ipairs(def.files) do
      local path = file.path or (file.name .. ".lua")
      local body, err = fetch(path)
      if body then
        save(file.name, body)
        print(("  ok  %s  (%db)"):format(file.name, #body))
      else
        print(("FAIL  %s <- %s  (%s)"):format(file.name, path, tostring(err)))
        failed = failed + 1
      end
    end
    installedNow[pkg] = true
    if def.station then stations[#stations + 1] = pkg end
  end
end

-- record installed packages (merge with any prior record)
do
  local set = {}
  if fs.exists(INSTALLED) then
    for line in io.lines(INSTALLED) do
      line = line:match("^%s*(%S+)%s*$"); if line then set[line] = true end
    end
  end
  for pkg in pairs(installedNow) do set[pkg] = true end
  local names = {}; for pkg in pairs(set) do names[#names + 1] = pkg end
  table.sort(names)
  save(INSTALLED, table.concat(names, "\n") .. "\n")
end

-- ------------------------------------------- register identity with the hub --
if #stations > 0 then
  rednet.open(peripheral.getName(modem))
  local hub = rednet.lookup(PROTO, "hub")
  if not hub then
    loudBanner("HUB OFFLINE")
    print("Files installed, but this station is UNREGISTERED (no name).")
    print("Bring the hub online, then re-run `update` here to get a label.")
  else
    local labelParts = {}
    for _, pkg in ipairs(stations) do
      rednet.send(hub, { kind = "register", computerID = os.getComputerID(), package = pkg }, PROTO)
      local instance
      local t0 = os.epoch("utc")
      while os.epoch("utc") - t0 < 3000 do
        local sender, msg = rednet.receive(PROTO, 3)
        if not sender then break end                       -- timed out
        if sender == hub and type(msg) == "table"
           and msg.kind == "assigned" and msg.package == pkg then
          instance = msg.instance; break
        end
      end
      if instance then
        labelParts[#labelParts + 1] = pkg .. instance
      else
        print("WARN  no reply from hub for '" .. pkg .. "' — name deferred.")
      end
    end
    if #labelParts > 0 then
      local label = table.concat(labelParts, "+")
      os.setComputerLabel(label)
      print("Registered. This station is now: " .. label)
    end
  end
end

print(("update: done (%d file error%s)"):format(failed, failed == 1 and "" or "s"))
