--!strict
-- What does `maxTotal(cap, seconds)` actually bound, under two candidate mechanisms?
--   "slide16": the sum of accepted amounts in the current bucket and the 15 before it (bucket width seconds/16),
--               times on server arrival; accept when sum + amount <= cap.
--   "bucket":  a token bucket, capacity cap, refill cap/seconds per second (the core `limit` shape, v5.md §5.4),
--               charged by amount; accept when amount <= tokens.
-- 1. A sender that sends, every 0.05 s, the largest amount the mechanism accepts (so it reaches each bound).
--    Reported: the largest accepted sum over any interval of length L, for L = seconds, 15/16 seconds, 1 s; and
--    the long-run rate.
-- 2. A steady earner at exactly cap/seconds per second (one message every 0.05 s), whose arrivals are delayed by
--    one reliable-lane stall of S seconds (queued messages arrive together when it ends): how many amounts fail.
-- Run: luau -O2 maxtotal_bounds.luau
local CAP, SECONDS, B = 1000, 60, 16
local STEP = 0.05
local DURATION = 600

type Mech = { accept: (self: Mech, now: number, amount: number) -> boolean, allowance: (self: Mech, now: number) -> number }

local function slide16(): Mech
	local bw = SECONDS / B
	local sums = table.create(B, 0)
	local head = -1 -- bucket index of the newest bucket written
	local total = 0
	local self = {}
	local function advance(now: number)
		local slot = now // bw
		if slot > head then
			local n = math.min(B, slot - head)
			for s = 1, n do
				local k = (head + s) % B + 1
				total -= sums[k]
				sums[k] = 0
			end
			head = slot
		end
	end
	function self.allowance(_: Mech, now: number): number
		advance(now)
		return CAP - total
	end
	function self.accept(_: Mech, now: number, amount: number): boolean
		advance(now)
		if total + amount <= CAP then
			local k = head % B + 1
			sums[k] += amount
			total += amount
			return true
		end
		return false
	end
	return self :: any
end

local function tokenBucket(): Mech
	local tokens, at = CAP, 0
	local self = {}
	local function refill(now: number)
		tokens = math.min(CAP, tokens + (now - at) * CAP / SECONDS)
		at = now
	end
	function self.allowance(_: Mech, now: number): number
		refill(now)
		return tokens
	end
	function self.accept(_: Mech, now: number, amount: number): boolean
		refill(now)
		if amount <= tokens then
			tokens -= amount
			return true
		end
		return false
	end
	return self :: any
end

local function maxWindow(times: { number }, amounts: { number }, L: number): number
	local best, sum, j = 0, 0, 1
	for i = 1, #times do
		sum += amounts[i]
		while times[i] - times[j] >= L do
			sum -= amounts[j]
			j += 1
		end
		best = math.max(best, sum)
	end
	return best
end

for _, name in { "slide16", "bucket" } do
	local m = if name == "slide16" then slide16() else tokenBucket()
	local times, amounts = {}, {}
	local t = 0
	while t < DURATION do
		local a = math.floor(m:allowance(t))
		if a > 0 and m:accept(t, a) then
			table.insert(times, t)
			table.insert(amounts, a)
		end
		t += STEP
	end
	local sum = 0
	for _, a in amounts do
		sum += a
	end
	print(string.format(
		"%-8s greedy: max sum over %d s %d (%.2f cap), over %.2f s %d (%.2f cap), over 1 s %d; long-run %.2f per s (cap/seconds %.2f)",
		name, SECONDS, maxWindow(times, amounts, SECONDS), maxWindow(times, amounts, SECONDS) / CAP,
		SECONDS * 15 / 16, maxWindow(times, amounts, SECONDS * 15 / 16), maxWindow(times, amounts, SECONDS * 15 / 16) / CAP,
		maxWindow(times, amounts, 1), sum / DURATION, CAP / SECONDS
	))
end

-- 2. steady earner at the cap's rate, with one stall
for _, stall in { 0, 0.85, 2, 5 } do
	for _, name in { "slide16", "bucket" } do
		for _, rate in { 1.0, 0.9 } do
			local m = if name == "slide16" then slide16() else tokenBucket()
			local amount = CAP / SECONDS * STEP * rate
			local fails, t = 0, 0
			local stallAt = 300
			while t < DURATION do
				local arrive = t
				if t >= stallAt and t < stallAt + stall then
					arrive = stallAt + stall -- held, released together
				end
				if not m:accept(arrive, amount) then
					fails += 1
				end
				t += STEP
			end
			print(string.format("%-8s steady at %.0f%% of cap/seconds, one %.2f s stall: %d of %d amounts refused",
				name, rate * 100, stall, fails, DURATION / STEP))
		end
	end
end
