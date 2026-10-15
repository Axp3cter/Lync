-- clock resolution
local minDelta = math.huge
for i = 1, 200000 do
  local a = os.clock(); local b = os.clock()
  while b == a do b = os.clock() end
  if b - a < minDelta then minDelta = b - a end
end
print(string.format("os.clock min nonzero delta: %.3e s", minDelta))
local b = buffer.create(8)
local readu8 = buffer.readu8
local function hook1(...) return readu8(...) end           -- Lua hook (hookfunction L->C style forwarding)
local function hook2(a, o) return readu8(a, o) end
local function vhook(...) local r = table.pack(...) return readu8(table.unpack(r, 1, r.n)) end -- arg-inspecting spy
local function bench(f, n)
  local t0 = os.clock()
  for i = 1, n do f(b, 0) end
  return os.clock() - t0
end
local function empty(n) local t0 = os.clock(); for i = 1, n do end; return os.clock() - t0 end
for _, n in {1, 10, 100, 1000, 10000} do
  local samples = {}
  for rep = 1, 200 do
    local d = bench(readu8, n); local h = bench(hook1, n)
    table.insert(samples, h / math.max(d, 1e-9))
  end
  table.sort(samples)
  print(string.format("n=%5d hook1/direct ratio p5=%.2f p50=%.2f p95=%.2f", n, samples[10], samples[100], samples[190]))
end
local N = 1e5
print(string.format("per-call ns: direct %.1f  luahook %.1f  luahook2 %.1f  spy %.1f  emptyloop/iter %.2f",
  bench(readu8,N)/N*1e9, bench(hook1,N)/N*1e9, bench(hook2,N)/N*1e9, bench(vhook,N)/N*1e9, empty(N)/N*1e9))
