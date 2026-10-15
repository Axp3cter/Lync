--!strict
-- Claim: running every user callback in its own (pooled) thread (design §3.8, §6.1 step 7) costs a
-- resume per message over a protected call, and a fresh coroutine per message costs more again.
-- Variants, for a handler that does not yield:
--   direct : f(a, b)
--   pcall  : pcall(f, a, b)
--   pooled : GoodSignal-style reusable runner thread, resumed per call
--   fresh  : coroutine.create + resume per call (what task.spawn does, plus scheduler work on Roblox)
-- Run: luau -O2 dispatch.luau ; luau -O2 --codegen dispatch.luau

local N = 300000
local function bench(name: string, f: () -> ())
	local times = {}
	for _ = 1, 7 do
		local t0 = os.clock()
		f()
		table.insert(times, (os.clock() - t0) / N * 1e9)
	end
	table.sort(times)
	print(string.format("%-7s median %6.1f ns/call (min %6.1f, max %6.1f)", name, times[4], times[1], times[7]))
end

local total = 0
local function handler(player: number, data: number)
	total += player + data
end

bench("direct", function()
	for i = 1, N do
		handler(i, 1)
	end
end)

bench("pcall", function()
	for i = 1, N do
		pcall(handler, i, 1)
	end
end)

-- pooled runner: the thread loops, taking a function and args per resume
local runner: thread? = nil
local function runLoop(fn: (number, number) -> (), a: number, b: number)
	while true do
		fn(a, b)
		fn, a, b = coroutine.yield()
	end
end
bench("pooled", function()
	for i = 1, N do
		if runner == nil then
			runner = coroutine.create(runLoop)
		end
		coroutine.resume(runner :: thread, handler, i, 1)
	end
end)

bench("fresh", function()
	for i = 1, N do
		coroutine.resume(coroutine.create(handler), i, 1)
	end
end)
