--!strict
-- Supplement to bench.luau: direct call vs pcall for a validator, and repeat of the raise rows.
local function median(xs: { number }): number table.sort(xs) return xs[(#xs + 1) // 2] end
local sink: any
local function bench(name: string, n: number, f: (number) -> ())
	f(1000)
	local s = {}
	for _ = 1, 9 do local t0 = os.clock() f(n) table.insert(s, (os.clock() - t0) / n * 1e9) end
	table.sort(s)
	print(string.format("%-50s median %8.1f ns  (min %8.1f, max %8.1f)", name, median(s), s[1], s[#s]))
end
local function validator(p: any, v: number): boolean return v >= 0 end
bench("validator direct call", 500000, function(n) for i = 1, n do sink = validator(nil, i) end end)
bench("validator in pcall", 500000, function(n) for i = 1, n do local ok, r = pcall(validator, nil, i) sink = r end end)
local function raise() error("[Lync] LYNC2001 x", 0) end
bench("pcall(error(string,0)) repeat", 20000, function(n) for _ = 1, n do pcall(raise) end end)
