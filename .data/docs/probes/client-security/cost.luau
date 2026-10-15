local N = 200000
local function t(name, f)
  local t0 = os.clock(); for i = 1, N do f() end; local dt = os.clock() - t0
  print(string.format("%-34s %8.1f ns/op", name, dt / N * 1e9))
end
local function inner() return debug.info(2, "s") end
t("debug.info(2,'s')", inner)
local function walk() local i = 2; while true do local s = debug.info(i, "s"); if s == nil then break end; i += 1 end end
t("full debug.info walk (depth~3)", walk)
local cache = {}
t("debug.info + cache lookup", function() local s = debug.info(2, "s"); return cache[s] end)
t("pcall(error) w/ string", function() pcall(error, "x") end)
t("pcall(buffer.readu8, nil) fail", function() pcall(buffer.readu8, nil, 0) end)
t("pcall(ok fn)", function() pcall(math.abs, 1) end)
local s = 0x9E3779B9
t("16-bit tag mix over 64 B (16 words)", function()
  local h = s
  for w = 1, 16 do h = bit32.bxor(h, w * 0x45d9f3b); h = bit32.band(h * 31 + 7, 0xFFFFFFFF) end
  return h
end)
