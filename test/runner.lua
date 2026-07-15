-- Minimal assert harness. Run test files with: luajit test/test_xxx.lua
local M = { pass = 0, fail = 0 }
function M.eq(actual, expected, msg)
  if actual == expected then M.pass = M.pass + 1
  else M.fail = M.fail + 1
    print(("FAIL: %s\n  expected: %s\n  actual:   %s"):format(tostring(msg), tostring(expected), tostring(actual)))
  end
end
function M.ok(cond, msg)
  if cond then M.pass = M.pass + 1
  else M.fail = M.fail + 1; print("FAIL: " .. tostring(msg)) end
end
function M.done()
  print(("%d passed, %d failed"):format(M.pass, M.fail))
  if M.fail > 0 then os.exit(1) end
end
return M
