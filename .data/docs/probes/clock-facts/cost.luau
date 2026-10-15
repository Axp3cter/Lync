--!strict
-- Costs for U3 (the epoch median of the common-mode guard) and U4 (timing fields on request results).
-- U3: once per aligned 5 s epoch, the median of n valid slopes (n = 100), by table.sort on a reused array and by
--     quickselect; plus the per-fit test (two subtractions and comparisons).
-- U4: building a result table for an answered server ask, without and with roundTrip/pingAtSend/pingAtAnswer,
--     frozen as Lync's results would be or not; one os.clock() read; the per-slot record (two numbers) at send.
--     Player:GetNetworkPing() is an engine call and can't be measured here.
-- Run: luau -O2 cost.luau ; luau -O2 --codegen cost.luau
local H = require("../security-costs/harness")

local N = 100
local slopes = table.create(N, 0)
local work = table.create(N, 0)
local function fill(seed: number)
	for i = 1, N do slopes[i] = ((i * 7919 + seed) % 997) / 997 * 0.002 - 0.001 end
end
local function sortMedian(): number
	table.move(slopes, 1, N, 1, work)
	table.sort(work)
	return (work[N // 2] + work[N // 2 + 1]) / 2
end
local function select(a: { number }, n: number, kth: number): number
	local lo, hi = 1, n
	while lo < hi do
		local p = a[(lo + hi) // 2]
		local i, j = lo, hi
		while i <= j do
			while a[i] < p do i += 1 end
			while a[j] > p do j -= 1 end
			if i <= j then a[i], a[j] = a[j], a[i]; i += 1; j -= 1 end
		end
		if kth <= j then hi = j elseif kth >= i then lo = i else return a[kth] end
	end
	return a[lo]
end
local function qsMedian(): number
	table.move(slopes, 1, N, 1, work)
	local lo = select(work, N, N // 2)
	local hi = math.huge
	for t = N // 2 + 1, N do if work[t] < hi then hi = work[t] end end
	return (lo + hi) / 2
end
for seed = 1, 50 do
	fill(seed)
	assert(math.abs(sortMedian() - qsMedian()) < 1e-15, "medians disagree")
end
print("check: the two medians agree on 50 inputs")

local r = H.compare("U3: median of 100 slopes, once per 5 s epoch", 20000, {
	{ name = "table.sort median", fn = function(n)
		local s = 0
		for i = 1, n do fill(i % 64); s += sortMedian() end
		return s
	end },
	{ name = "quickselect median", fn = function(n)
		local s = 0
		for i = 1, n do fill(i % 64); s += qsMedian() end
		return s
	end },
	{ name = "fill only (input setup)", fn = function(n)
		for i = 1, n do fill(i % 64) end
		return slopes[1]
	end },
})
for _, name in { "table.sort median", "quickselect median" } do
	local c = r[name] - r["fill only (input setup)"]
	print(string.format("%-22s %.0f ns per epoch; at one epoch per 5 s: %.3f us/s", name, c, c / 5 / 1000))
end

local T = 0.01
H.compare("U3: per-fit guard test (both directions)", 1000000, {
	{ name = "raw test", fn = function(n)
		local hits = 0
		for i = 1, n do
			local s = (i % 200 - 100) * 0.0002
			if s > T then hits += 1 elseif s < -T then hits -= 1 end
		end
		return hits
	end },
	{ name = "guard test", fn = function(n)
		local hits = 0
		local M = 0.0003
		for i = 1, n do
			local s = (i % 200 - 100) * 0.0002
			if s - math.max(M, 0) > T then hits += 1 elseif s - math.min(M, 0) < -T then hits -= 1 end
		end
		return hits
	end },
})

-- U4
local sendAt = table.create(16, 0)
local pingAt = table.create(16, 0)
H.compare("U4: result of an answered server ask", 1000000, {
	{ name = "result { ok, value }", fn = function(n)
		local s = 0
		for i = 1, n do
			local res = { ok = true, value = i }
			s += res.value
		end
		return s
	end },
	{ name = "result + 3 timing fields", fn = function(n)
		local s = 0
		for i = 1, n do
			local slot = i % 16 + 1
			local res = { ok = true, value = i, roundTrip = 0.1 - sendAt[slot], pingAtSend = pingAt[slot], pingAtAnswer = 0.05 }
			s += res.value
		end
		return s
	end },
	{ name = "frozen result { ok, value }", fn = function(n)
		local s = 0
		for i = 1, n do
			local res = table.freeze({ ok = true, value = i })
			s += res.value
		end
		return s
	end },
	{ name = "frozen result + 3 timing fields", fn = function(n)
		local s = 0
		for i = 1, n do
			local slot = i % 16 + 1
			local res = table.freeze({ ok = true, value = i, roundTrip = 0.1 - sendAt[slot], pingAtSend = pingAt[slot], pingAtAnswer = 0.05 })
			s += res.value
		end
		return s
	end },
	{ name = "os.clock() read", fn = function(n)
		local s = 0
		for _ = 1, n do s += os.clock() end
		return s
	end },
	{ name = "record send time + ping in slot", fn = function(n)
		for i = 1, n do
			local slot = i % 16 + 1
			sendAt[slot] = i * 1e-6
			pingAt[slot] = 0.05
		end
		return sendAt[1]
	end },
})
print("sink", H.sink)
