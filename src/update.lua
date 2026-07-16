-- update.lua — pull this station's programs fresh from the canonical GitHub repo.
--
-- WHY: `wget <url> <name>` refuses to overwrite an existing file, and
-- raw.githubusercontent.com caches ~5 min per IP — so a naive re-fetch can serve
-- STALE code right after a push. This uses http.get (overwrites freely) with a
-- per-fetch cache-buster (?cb=<epoch>) so `update` always lands the newest commit.
--
-- ONE-TIME INSTALL on a fresh computer:
--   wget https://raw.githubusercontent.com/miasmile111/cctweakvegas/main/src/update.lua update
--   edit install.list      (list the programs THIS station needs — see format below)
--   update                 (pulls them, fresh, every time after)
--
-- ITERATE: on the PC, edit src/ + `git push`; in-game just run `update`.
--
-- install.list format (one program per line; blank lines and # comments ignored):
--   <localname> [repo-subpath]
-- localname  = the in-world file name (what you `run`/`require`), no .lua extension.
-- repo-subpath = path under src/ in the repo; defaults to "<localname>.lua".
-- Example install.list for the slot station:
--   subpixel   lib/subpixel.lua
--   slot_logic
--   slot_symbols
--   slot
--   update     update.lua      # keep the updater self-updating

local BASE = "https://raw.githubusercontent.com/miasmile111/cctweakvegas/main/src/"
local LIST = "install.list"

if not http then
  error("http API disabled — cannot update. (pack must allow HTTP)", 0)
end

if not fs.exists(LIST) then
  print("No '" .. LIST .. "' on this computer.")
  print("Create it with the programs this station needs, e.g.:")
  print("  edit " .. LIST)
  print("  subpixel   lib/subpixel.lua")
  print("  slot_logic")
  print("  slot_symbols")
  print("  slot")
  print("  update     update.lua")
  return
end

-- Parse install.list -> { {name=, path=}, ... }
local jobs = {}
for line in io.lines(LIST) do
  line = line:gsub("#.*$", "")                 -- strip comments
  local name, path = line:match("^%s*(%S+)%s+(%S+)%s*$")
  if not name then name = line:match("^%s*(%S+)%s*$") end
  if name then
    jobs[#jobs + 1] = { name = name, path = path or (name .. ".lua") }
  end
end

if #jobs == 0 then
  print("'" .. LIST .. "' is empty — nothing to update.")
  return
end

local ok, fail = 0, 0
for _, job in ipairs(jobs) do
  local url = BASE .. job.path .. "?cb=" .. os.epoch("utc")   -- cache-bust every fetch
  local h, err = http.get(url)
  if h then
    local body = h.readAll()
    h.close()
    local f = fs.open(job.name, "w")           -- overwrites; no delete step needed
    f.write(body)
    f.close()
    print("  ok  " .. job.name .. "  (" .. #body .. "b)")
    ok = ok + 1
  else
    print("FAIL  " .. job.name .. "  <- " .. job.path .. "  (" .. tostring(err) .. ")")
    fail = fail + 1
  end
end

print(("update: %d ok, %d failed"):format(ok, fail))
