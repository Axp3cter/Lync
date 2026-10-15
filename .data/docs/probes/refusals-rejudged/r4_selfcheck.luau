--!strict
-- R18: cost and VM facts of a client self-check of Lync's own tables and closures (no engine functions, no getfenv).
-- Model of a generated client shard: VIEWS views, each a frozen table holding its `fire` closure; one frozen
-- runtime table holding the flush and tag closures. The check compares each slot with the closure Lync stored
-- (rawequal + rawget: fast-call builtins), tests that each table is still frozen, and optionally compares
-- debug.info(f, "sl") of each closure with this chunk's own source and the line the build emitted.
local VIEWS = 200
local RUNS = 7
local N = 200_000

local function mkFire(i: number)
	return function(self: any, v: any)
		return i + (if v then 1 else 0)
	end
end
local views: { any } = {}
local fires: { any } = {}
for i = 1, VIEWS do
	local f = mkFire(i)
	fires[i] = f
	views[i] = table.freeze({ fire = f })
end
local function flush() return 1 end
local function tag() return 2 end
local runtime = table.freeze({ flush = flush, tag = tag })
local OWN = debug.info(1, "s")
local LINE_FIRE = debug.info(fires[1], "l") -- the build knows this line; read here for the model
local LINE_FLUSH = debug.info(flush, "l")

-- facts the check relies on
print("own source:", OWN, "fire line:", LINE_FIRE, "flush line:", LINE_FLUSH)
print("C function:", debug.info(print, "s"), debug.info(print, "l"))
print("isfrozen(views[1]):", table.isfrozen(views[1]), "write to frozen view raises:", not pcall(function() (views[1] :: any).fire = nil end))

-- one item: field identity + frozen flag
local function checkField(t: any, k: string, f: any): number
	if not rawequal(rawget(t, k), f) then return 3 end
	if not table.isfrozen(t) then return 4 end
	return 0
end
-- one item: closure identity by debug info
local function checkInfo(f: any, line: number): number
	local s, l = debug.info(f, "sl")
	if s ~= OWN then return 1 end
	if l ~= line then return 2 end
	return 0
end

local function bench(name: string, ops: number, fn: () -> number)
	local best = math.huge
	local sink = 0
	for _ = 1, RUNS do
		local t0 = os.clock()
		sink += fn()
		best = math.min(best, os.clock() - t0)
	end
	print(string.format("%-62s %8.1f ns/op (sink %d)", name, best * 1e9 / ops, sink))
end

bench("empty loop", N, function()
	local x = 0
	for i = 1, N do x += i % 2 end
	return x % 3
end)
bench("field item: rawequal(rawget(t,k), f) + table.isfrozen(t)", N, function()
	local bad = 0
	for i = 1, N do
		local j = i % VIEWS + 1
		bad += checkField(views[j], "fire", fires[j])
	end
	return bad
end)
bench("field item: rawequal(rawget(t,k), f) only", N, function()
	local bad = 0
	for i = 1, N do
		local j = i % VIEWS + 1
		if not rawequal(rawget(views[j], "fire"), fires[j]) then bad += 1 end
	end
	return bad
end)
bench("info item: debug.info(f, \"sl\") vs own source and build line", N, function()
	local bad = 0
	for i = 1, N do
		local j = i % VIEWS + 1
		bad += checkInfo(fires[j], LINE_FIRE)
	end
	return bad
end)
local NF = N // 100
bench("whole pass: 200 views + runtime (field items only)", NF, function()
	local bad = 0
	for _ = 1, NF do
		for j = 1, VIEWS do bad += checkField(views[j], "fire", fires[j]) end
		bad += checkField(runtime, "flush", flush) + checkField(runtime, "tag", tag)
	end
	return bad
end)
bench("whole pass: 200 views + runtime (field and info items)", NF, function()
	local bad = 0
	for _ = 1, NF do
		for j = 1, VIEWS do bad += checkField(views[j], "fire", fires[j]) + checkInfo(fires[j], LINE_FIRE) end
		bad += checkField(runtime, "flush", flush) + checkField(runtime, "tag", tag) + checkInfo(flush, LINE_FLUSH)
	end
	return bad
end)
