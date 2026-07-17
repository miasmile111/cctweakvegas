-- gps_constellation.lua — spike + regression test for the GPS constellation geometry rule.
-- Run from the repo root: luajit test/spikes/gps_constellation.lua
--
-- WHY THIS EXISTS. The per-station proximity design lets a station self-locate with gps.locate()
-- so hundreds of stations never need hand-typed coordinates. The open question was whether a
-- constellation squeezed into ONE force-loaded chunk can locate a station 1000+ blocks away, or
-- whether the hosts must be spread across the map.
--
-- THE ANSWER IS GEOMETRY, NOT DISTANCE. CC's GPS is not real GPS: WirelessNetwork.tryTransmit
-- hands the receiver Math.sqrt(distanceSq) computed from exact block positions, so the distances
-- carry NO measurement noise. "Spread your satellites out" exists in real GPS purely to stop noise
-- being amplified by bad geometry; with exact distances there is nothing to amplify, and a
-- one-chunk constellation is EXACT (err = 0) out to tens of thousands of blocks.
--
-- What does still break it is degeneracy, and this file pins both forms:
--   * trilaterate() rejects near-collinear hosts (|a2b_hat . a2c_hat| > 0.999).
--   * three hosts only ever yield a MIRRORED PAIR about their plane; narrow() needs a fourth fix
--     OFF that plane to pick. Four coplanar hosts fail at ANY distance.
-- So the build rule is: three hosts at the chunk's corners + ONE LIFTED. Vertical separation is
-- the whole requirement; horizontal spread buys nothing.
--
-- trilaterate/narrow below are transcribed VERBATIM from CC:T rom/apis/gps.lua (mc-1.21.x) so this
-- tests the real algorithm, not our idea of it. See docs/superpowers/specs/
-- 2026-07-17-per-station-proximity-design.md fact (9).

package.path = "test/?.lua;" .. package.path
local t = require("runner")

-- minimal stand-in for CC's vector API (only what gps.lua touches)
local vector = {}
vector.__index = vector
local function v(x, y, z) return setmetatable({ x = x, y = y, z = z }, vector) end
function vector.__add(a, b) return v(a.x + b.x, a.y + b.y, a.z + b.z) end
function vector.__sub(a, b) return v(a.x - b.x, a.y - b.y, a.z - b.z) end
function vector.__mul(a, m) return v(a.x * m, a.y * m, a.z * m) end
function vector:dot(o) return self.x * o.x + self.y * o.y + self.z * o.z end
function vector:cross(o)
  return v(self.y * o.z - self.z * o.y, self.z * o.x - self.x * o.z, self.x * o.y - self.y * o.x)
end
function vector:length() return math.sqrt(self:dot(self)) end
function vector:normalize() return self * (1 / self:length()) end
function vector:round(n)
  n = n or 1
  return v(math.floor(self.x / n + 0.5) * n, math.floor(self.y / n + 0.5) * n, math.floor(self.z / n + 0.5) * n)
end

-- ---- verbatim from rom/apis/gps.lua ----------------------------------------
local function trilaterate(A, B, C)
  local a2b = B.vPosition - A.vPosition
  local a2c = C.vPosition - A.vPosition
  if math.abs(a2b:normalize():dot(a2c:normalize())) > 0.999 then return nil end
  local d = a2b:length()
  local ex = a2b:normalize()
  local i = ex:dot(a2c)
  local ey = (a2c - ex * i):normalize()
  local j = ey:dot(a2c)
  local ez = ex:cross(ey)
  local r1, r2, r3 = A.nDistance, B.nDistance, C.nDistance
  local x = (r1 * r1 - r2 * r2 + d * d) / (2 * d)
  local y = (r1 * r1 - r3 * r3 - x * x + (x - i) * (x - i) + j * j) / (2 * j)
  local result = A.vPosition + ex * x + ey * y
  local zSquared = r1 * r1 - x * x - y * y
  if zSquared > 0 then
    local z = math.sqrt(zSquared)
    local result1, result2 = result + ez * z, result - ez * z
    local rounded1, rounded2 = result1:round(0.01), result2:round(0.01)
    if rounded1.x ~= rounded2.x or rounded1.y ~= rounded2.y or rounded1.z ~= rounded2.z then
      return rounded1, rounded2
    else
      return rounded1
    end
  end
  return result:round(0.01)
end

local function narrow(p1, p2, fix)
  local dist1 = math.abs((p1 - fix.vPosition):length() - fix.nDistance)
  local dist2 = math.abs((p2 - fix.vPosition):length() - fix.nDistance)
  if math.abs(dist1 - dist2) < 0.01 then
    return p1, p2
  elseif dist1 < dist2 then
    return p1:round(0.01)
  else
    return p2:round(0.01)
  end
end
-- ---------------------------------------------------------------------------

-- The distance a host reports is EXACT (WirelessNetwork.tryTransmit -> Math.sqrt(distanceSq)).
local function fixOf(host, target) return { vPosition = host, nDistance = (target - host):length() } end

-- Mirrors gps.locate()'s decision path: 3 fixes -> trilaterate, 4th -> narrow.
-- Returns pos, or nil + why.
local function locate(hosts, target)
  local f = {}
  for i = 1, #hosts do f[i] = fixOf(hosts[i], target) end
  local p1, p2 = trilaterate(f[1], f[2], f[3])
  if not p1 then return nil, "degenerate: hosts near-collinear" end
  if p2 and f[4] then p1, p2 = narrow(p1, p2, f[4]) end
  if p2 then return nil, "ambiguous: mirror unresolved (4th host coplanar)" end
  return p1
end

local function errOf(got, want)
  return math.max(math.abs(got.x - want.x), math.abs(got.y - want.y), math.abs(got.z - want.z))
end

-- A constellation inside ONE chunk (x,z in 0..15): 3 at the corners, 4th LIFTED off their plane.
local ONE_CHUNK = { v(0, 100, 0), v(15, 100, 0), v(0, 100, 15), v(7, 140, 7) }

-- Exact at every distance the floor will ever use.
for _, case in ipairs({
  { "100 blocks out",   v(100, 72, 60) },
  { "1,000 blocks out", v(1000, 64, -800) },
  { "5,000 blocks out", v(5000, 200, 5000) },
}) do
  local got, why = locate(ONE_CHUNK, case[2])
  t.ok(got ~= nil, "one-chunk constellation locates a station " .. case[1] .. " (" .. tostring(why) .. ")")
  if got then t.eq(errOf(got, case[2]), 0, "exact (err=0) at " .. case[1]) end
end

-- The two ways to build it wrong. Both must fail, or the build rule is a superstition.
do
  local coplanar = { v(0, 100, 0), v(15, 100, 0), v(0, 100, 15), v(15, 100, 15) }
  local got, why = locate(coplanar, v(1000, 64, -800))
  t.ok(got == nil, "4 COPLANAR hosts cannot resolve the mirror -> the 4th host MUST be lifted")
  t.ok(why == "ambiguous: mirror unresolved (4th host coplanar)", "coplanar fails via narrow(), not trilaterate()")

  local collinear = { v(0, 100, 0), v(5, 100, 0), v(10, 100, 0), v(15, 100, 0) }
  local got2, why2 = locate(collinear, v(1000, 64, -800))
  t.ok(got2 == nil, "4 COLLINEAR hosts are degenerate")
  t.ok(why2 == "degenerate: hosts near-collinear", "collinear is rejected by trilaterate()'s 0.999 dot check")
end

-- Reach vs. lift. narrow() separates the mirror only while the two candidates' residuals differ by
-- >= 0.01, so lift (not horizontal spread) is what buys distance. Even +5 clears 20k blocks.
for _, case in ipairs({
  { lift = 5,  reach = 20000 },
  { lift = 10, reach = 50000 },
  { lift = 40, reach = 100000 },
}) do
  local hosts = { v(0, 100, 0), v(15, 100, 0), v(0, 100, 15), v(7, 100 + case.lift, 7) }
  local target = v(case.reach, 64, -case.reach * 0.8)
  local got = locate(hosts, target)
  t.ok(got ~= nil and errOf(got, target) < 0.05,
    ("4th host +%d y stays exact out to %d blocks"):format(case.lift, case.reach))
end

-- "Wouldn't a LONGER A->B / A->C help?" -- the obvious question, and the answer is no. Hold the lift
-- and grow the triangle 2000x: the reach does not move a single block. A, B and C define a PLANE, and
-- three exact distances always narrow to a mirrored pair reflected across it; enlarging the triangle
-- does not move the plane, so the mirror is unchanged. Only the 4th host's distance OFF the plane
-- separates the candidates for narrow(). Baseline length is the lever in real GPS purely because it
-- averages down measurement noise -- CC has none, so exactness takes that lever away. This asserts the
-- build rule ("spread vertically, not horizontally") stays true rather than staying merely written down.
do
  local reach = 200000
  for _, span in ipairs({ 5, 15, 100, 1000, 10000 }) do
    local hosts = { v(0, 100, 0), v(span, 100, 0), v(0, 100, span), v(7, 140, 7) }
    local target = v(reach, 64, -reach * 0.8)
    local got = locate(hosts, target)
    t.ok(got ~= nil and errOf(got, target) < 0.05,
      ("A->B = A->C = %d blocks reaches %d -- horizontal span is irrelevant"):format(span, reach))
  end
end

t.done()
