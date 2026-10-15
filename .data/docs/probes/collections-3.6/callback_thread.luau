-- B2: a callback run in its own thread; detect yield at the call; cost per call
local function cb(x) return x + 1 end
local function yielder(x) coroutine.yield() return x end

-- fresh thread per call
local function callFresh(f, x)
	local co = coroutine.create(f)
	local ok, r = coroutine.resume(co, x)
	return ok, r, coroutine.status(co)
end
print("fresh, normal:", callFresh(cb, 1))
print("fresh, yields:", callFresh(yielder, 1))
print("fresh, throws:", callFresh(function() error("boom", 0) end, 1))

-- pooled worker: done flag distinguishes our hand-back from a callback's yield
local function newWorker()
	local w = {}
	w.co = coroutine.create(function(f, x)
		while true do
			local r = f(x)
			w.done = true
			f, x = coroutine.yield(r)
		end
	end)
	return w
end
local worker = newWorker()
local function callPooled(f, x)
	worker.done = false
	local ok, r = coroutine.resume(worker.co, f, x)
	if not ok then worker = newWorker() return false, r, "threw" end
	if not worker.done then worker = newWorker() return false, nil, "yielded" end
	return true, r, "ok"
end
print("pooled, normal:", callPooled(cb, 1))
print("pooled, yields:", callPooled(yielder, 1))
print("pooled, after:", callPooled(cb, 2))
print("coroutine.close exists:", coroutine.close ~= nil)

local N = 200000
local function bench(name, fn)
	local best = math.huge
	for _ = 1, 5 do
		local t = os.clock()
		for i = 1, N do fn(cb, i) end
		best = math.min(best, os.clock() - t)
	end
	print(string.format("%s: %.1f ns/call", name, best / N * 1e9))
end
bench("direct pcall", function(f, x) return pcall(f, x) end)
bench("fresh thread", callFresh)
bench("pooled thread", callPooled)
