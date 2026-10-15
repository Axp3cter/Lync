--!strict
-- Hot-path cost of diagnostics. Run:  luau -O2 bench.luau ; luau -O2 --codegen bench.luau
-- Each row: median of 7 runs, ns per operation.

local N = 200_000

local function median(xs: { number }): number
	table.sort(xs)
	return xs[(#xs + 1) // 2]
end

local sink: any = nil

local function bench(name: string, n: number, f: (number) -> ())
	f(math.min(n, 1000)) -- warm
	local samples = {}
	for _ = 1, 7 do
		local t0 = os.clock()
		f(n)
		table.insert(samples, (os.clock() - t0) / n * 1e9)
	end
	print(string.format("%-58s %9.1f ns", name, median(samples)))
end

-- 1. Success path of a check that can raise -------------------------------------------------

local function failCount(path: string, value: unknown): never
	error(`[Lync] LYNC2001 {path} must be a whole number from 0 to 99, got {value}`, 2)
end

local values = table.create(1024, 0)
for i = 1, 1024 do
	values[i] = i % 100
end

bench("check, no message work (guard + cold fail call)", N, function(n)
	for i = 1, n do
		local v = values[(i % 1024) + 1]
		if typeof(v) ~= "number" or v < 0 or v > 99 or v % 1 ~= 0 then
			failCount("value.count", v)
		end
	end
end)

bench("check, assert with constant message", N, function(n)
	for i = 1, n do
		local v = values[(i % 1024) + 1]
		assert(typeof(v) == "number" and v >= 0 and v <= 99 and v % 1 == 0, "[Lync] LYNC2001 bad count")
	end
end)

bench("check, assert with interpolated message (eager)", N, function(n)
	for i = 1, n do
		local v = values[(i % 1024) + 1]
		assert(
			typeof(v) == "number" and v >= 0 and v <= 99 and v % 1 == 0,
			`[Lync] LYNC2001 value.count must be 0 to 99, got {v}`
		)
	end
end)

bench("baseline: same loop, no check", N, function(n)
	local acc = 0
	for i = 1, n do
		local v = values[(i % 1024) + 1]
		acc += v
	end
	sink = acc
end)

-- 2. Raising and catching ------------------------------------------------------------------

local function raiseString0()
	error("[Lync] LYNC2001 value.count must be 0 to 99, got 120", 0)
end
local function raiseString1()
	error("[Lync] LYNC2001 value.count must be 0 to 99, got 120", 1)
end
local ERR_TABLE = table.freeze({ code = "LYNC2001" })
local function raiseTableShared()
	error(ERR_TABLE)
end
local function raiseTableFresh()
	error({ code = "LYNC2001", path = "value.count", got = 120 })
end
local function ok() end
local M = 20_000

bench("pcall(ok)  (no error)", N, function(n)
	for _ = 1, n do
		pcall(ok)
	end
end)
bench("pcall(error(string, 0))", M, function(n)
	for _ = 1, n do
		pcall(raiseString0)
	end
end)
bench("pcall(error(string, 1))  (adds position)", M, function(n)
	for _ = 1, n do
		pcall(raiseString1)
	end
end)
bench("pcall(error(shared frozen table))", M, function(n)
	for _ = 1, n do
		pcall(raiseTableShared)
	end
end)
bench("pcall(error(fresh table))", M, function(n)
	for _ = 1, n do
		pcall(raiseTableFresh)
	end
end)
local function handler(e: any): any
	return debug.traceback(tostring(e), 2)
end
bench("xpcall(error(string,1), traceback handler)", M, function(n)
	for _ = 1, n do
		xpcall(raiseString1, handler)
	end
end)
bench("xpcall(ok, traceback handler)  (no error)", N, function(n)
	for _ = 1, n do
		xpcall(ok, handler)
	end
end)

-- 3. debug.info walks ------------------------------------------------------------------------

local OWN = debug.info(1, "s")
local function walk(): (string?, number?)
	local level = 2
	while true do
		local source, line = debug.info(level, "sl")
		if source == nil then
			return nil, nil
		end
		if source ~= OWN then
			return source, line
		end
		level += 1
	end
end

-- user frames come from another chunk; Lync frames are nested here d deep
local userChunk = assert(loadstring(
	[[
local f, n = ...
for _ = 1, n do f() end
]],
	"=User"
))

local function nest(depth: number): () -> ()
	if depth == 1 then
		return function()
			local s = walk()
			sink = s
		end
	end
	local inner = nest(depth - 1)
	return function()
		inner()
		sink = sink -- prevent tail call
	end
end

for depth = 1, 5 do
	local f = nest(depth)
	bench(`debug.info walk to first non-Lync frame, Lync depth {depth}`, M, function(n)
		userChunk(f, n)
	end)
end

bench("debug.info(2, \"sl\") single read", N, function(n)
	for _ = 1, n do
		local s, l = debug.info(2, "sl")
		sink = l
	end
end)
bench("debug.info(fn, \"sl\") on a function value", N, function(n)
	for _ = 1, n do
		local s, l = debug.info(ok, "sl")
		sink = l
	end
end)
bench("debug.traceback() (string build)", M, function(n)
	for _ = 1, n do
		sink = debug.traceback()
	end
end)

-- 4. Formatting -------------------------------------------------------------------------------

bench("string.format(\"%s %d %s\")", N, function(n)
	for i = 1, n do
		sink = string.format("[Lync] %s must be from 0 to 99, got %d (%s)", "value.count", i, "arena.buy")
	end
end)
bench("interpolation `{} {} {}`", N, function(n)
	for i = 1, n do
		local path, def = "value.count", "arena.buy"
		sink = `[Lync] {path} must be from 0 to 99, got {i} ({def})`
	end
end)
bench("concatenation .. .. ..", N, function(n)
	for i = 1, n do
		sink = "[Lync] " .. "value.count" .. " must be from 0 to 99, got " .. tostring(i) .. " (" .. "arena.buy" .. ")"
	end
end)

-- 5. Observer event versus counter ----------------------------------------------------------

local counters = table.create(64, 0)
bench("counter: array slot += 1", N, function(n)
	for i = 1, n do
		local r = (i % 32) + 1
		counters[r] += 1
	end
end)

local perPlayer: { [any]: { number } } = {}
local players = {}
for i = 1, 16 do
	players[i] = newproxy(false)
	perPlayer[players[i]] = table.create(32, 0)
end
bench("counter: per-player array slot += 1 (hash lookup)", N, function(n)
	for i = 1, n do
		local p = players[(i % 16) + 1]
		local r = (i % 32) + 1
		local row = perPlayer[p]
		row[r] += 1
	end
end)

local buf = buffer.create(64 * 4)
bench("counter: buffer u32 += 1", N, function(n)
	for i = 1, n do
		local o = (i % 32) * 4
		buffer.writeu32(buf, o, buffer.readu32(buf, o) + 1)
	end
end)

local listeners: { (any) -> () } = {
	function(e)
		sink = e
	end,
}
bench("event: build frozen table + 1 listener direct call", N, function(n)
	for i = 1, n do
		local e = table.freeze({
			kind = "anomaly",
			reason = "overLimit",
			player = players[(i % 16) + 1],
			definition = "arena.chat",
			count = 1,
			first = 0,
			last = 0,
			evidence = table.freeze({ perSecond = 5, burst = 5 }),
		})
		for _, l in listeners do
			l(e)
		end
	end
end)

local function coroutineDispatch(l: (any) -> (), e: any)
	local co = coroutine.create(l)
	coroutine.resume(co, e)
end
bench("event: frozen table + fresh coroutine per listener", M, function(n)
	for i = 1, n do
		local e = table.freeze({ kind = "anomaly", reason = "overLimit", count = 1 })
		for _, l in listeners do
			coroutineDispatch(l, e)
		end
	end
end)

-- coalesced: occurrence counted into a per-(player,reason,def) slot; event only on first
local windows: { [any]: { [string]: number } } = {}
bench("coalesced occurrence: key lookup + count (no event)", N, function(n)
	for i = 1, n do
		local p = players[(i % 16) + 1]
		local w = windows[p]
		if w == nil then
			w = {}
			windows[p] = w
		end
		local key = "overLimit"
		local c = w[key]
		w[key] = if c == nil then 1 else c + 1
	end
end)
