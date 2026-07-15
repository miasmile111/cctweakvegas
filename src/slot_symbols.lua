-- slot_symbols.lua — reel icons as subpixel sprite data (0 = transparent).
local W, H = 8, 9
local C = { _=0, r=16384, y=16, o=2, l=32, g=8192, k=32768, w=1 }
-- build sprite from H strings of W chars keyed into C
local function make(rows)
  local px = {}
  for y = 1, H do
    local line = rows[y]
    for x = 1, W do px[(y - 1) * W + x] = C[line:sub(x, x)] end
  end
  return { w = W, h = H, px = px }
end

local seven = make({
  "rrrrrrrr",
  "rrrrrrrr",
  "______rr",
  "_____rr_",
  "____rr__",
  "___rr___",
  "__rr____",
  "__rr____",
  "__rr____",
})
local cherry = make({
  "_____gg_",
  "____gg__",
  "_g__g___",
  "rrr_rrr_",
  "rrrrrrrr",
  "rrrrrrrr",
  "_rrr_rr_",
  "__r___r_",
  "________",
})
local bell = make({
  "___yy___",
  "__yyyy__",
  "__yyyy__",
  "_yyyyyy_",
  "_yyyyyy_",
  "yyyyyyyy",
  "yyyyyyyy",
  "___kk___",
  "___kk___",
})
local bar = make({
  "kkkkkkkk",
  "kwwwwwwk",
  "kw_ww_wk",
  "kw_ww_wk",
  "kwwwwwwk",
  "kw_ww_wk",
  "kw_ww_wk",
  "kwwwwwwk",
  "kkkkkkkk",
})
return { seven, cherry, bell, bar }
