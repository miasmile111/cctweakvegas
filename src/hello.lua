-- hello.lua — smoke test for CC:Tweaked on Atlas Server
-- Run: after import, type `hello`  (or `hello YourName`)

local args = { ... }
local name = args[1] or "world"

term.clear()
term.setCursorPos(1, 1)
print("Hello, " .. name .. "!")
print("CraftOS " .. os.version())
print("Computer ID: " .. os.getComputerID())

-- prove HTTP works (needed for future imports)
if http then
  print("HTTP API: available")
else
  print("HTTP API: DISABLED (imports won't work)")
end
