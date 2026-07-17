package.path = "src/lib/?.lua;src/slot/?.lua;test/?.lua;" .. package.path
local t = require("runner")
local S = require("slot_style")

-- a tiny recording canvas (mirrors the subpixel canvas contract)
local function mockCanvas(w, h)
  local cv = { w = w, h = h, px = {} }
  function cv:setPixel(x, y, color)
    if x < 1 or y < 1 or x > self.w or y > self.h then return end
    self.px[y * 1000 + x] = color
  end
  function cv:fillRect(x, y, w, h, color)
    for dy = 0, h - 1 do for dx = 0, w - 1 do self:setPixel(x + dx, y + dy, color) end end
  end
  return cv
end

-- the constants slot.lua and slot_advert.lua must agree on
t.eq(#S.GRAD, 5, "5 gradient palette slots")
t.eq(S.GRAD[1], 2048, "first gradient slot is 2048")
t.eq(S.RED, 16384, "RED")
t.eq(S.YELLOW, 16, "YELLOW")
t.eq(S.WHITE, 1, "WHITE")
t.eq(S.BLACK, 32768, "BLACK")
t.eq(S.GREY, 128, "GREY")

-- gradientRGB is PURE: same input, same output, no CC globals needed
do
  local r1, g1, b1 = S.gradientRGB(1, 0)
  local r2, g2, b2 = S.gradientRGB(1, 0)
  t.eq(r1, r2, "gradientRGB is deterministic (r)")
  t.eq(g1, g2, "gradientRGB is deterministic (g)")
  t.eq(b1, b2, "gradientRGB is deterministic (b)")
  -- every channel stays inside the deep..teal envelope, so a band can never be
  -- brighter than teal or darker than deep no matter the phase
  for _, phase in ipairs({ 0, 1, 2, 3, 4, 5, 6 }) do
    for i = 1, #S.GRAD do
      local r, g, b = S.gradientRGB(i, phase)
      t.ok(g >= S.GRAD_DEEP[2] - 1e-9 and g <= S.GRAD_TEAL[2] + 1e-9,
           ("band %d phase %d: green inside deep..teal"):format(i, phase))
      t.ok(r >= 0 and r <= 1 and b >= 0 and b <= 1,
           ("band %d phase %d: r,b are valid 0..1"):format(i, phase))
    end
  end
end

-- bandFill covers EVERY pixel of the canvas -- a gap would show as a black stripe
do
  local cv = mockCanvas(30, 72)
  S.bandFill(cv)
  local missing = 0
  for y = 1, 72 do for x = 1, 30 do if cv.px[y * 1000 + x] == nil then missing = missing + 1 end end end
  t.eq(missing, 0, "bandFill leaves no unpainted pixel")
end

-- bulb: 2x2, on = YELLOW, off = GREY, parity from seed + bulbTick
do
  local cv = mockCanvas(30, 72)
  S.bulb(cv, 5, 5, 0, 0)                     -- (0 + 0) % 2 == 0 -> on
  t.eq(cv.px[5 * 1000 + 5], S.YELLOW, "bulb on: top-left is YELLOW")
  t.eq(cv.px[6 * 1000 + 6], S.YELLOW, "bulb on: it is 2x2")
  t.eq(cv.px[5 * 1000 + 7], nil, "bulb on: it is only 2 wide")
  S.bulb(cv, 9, 9, 1, 0)                     -- (1 + 0) % 2 == 1 -> off
  t.eq(cv.px[9 * 1000 + 9], S.GREY, "bulb off: GREY")
end

t.done()
