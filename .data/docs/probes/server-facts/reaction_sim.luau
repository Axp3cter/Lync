--!strict
-- U10: what the server's reaction estimate does on v5.md §9's default network model, and what each trigger
-- catches. Per trial: the server flushes a stimulus at t = 0 (reliable lane); it arrives after latency + jitter
-- (+ a stall with probability stallChance * stallSeconds, held up to stallSeconds); the client dispatches it at
-- its next 60 Hz step; game code responds r later; the response leaves at the next client flush; it arrives after
-- latency + jitter (+ stall); the server decodes it at its next 60 Hz step.
--   elapsed = server decode time - stimulus flush time
--   estimate = elapsed - bound, bound = the path lower bound (min ping)
-- Reports the slack (estimate - r) and how often case 1 (time rule and receipt rule) and the floor fire for
-- unmodified responders (r >= 0 after dispatch) and for responders that fire at a fixed lead before or after
-- the stimulus left the server, without having received it.
-- Run: luau -O2 reaction_sim.luau

local LAT, JIT = 0.05, 0.02
local STALL_P, STALL_S = 0.05 * 0.3, 0.3 -- fraction of time inside a stall, stall length (s)
local STEP = 1 / 60
local TRIALS = 200_000
math.randomseed(11)

local function oneWay(): number
	local d = LAT + math.random() * JIT
	if math.random() < STALL_P then d += math.random() * STALL_S end
	return d
end

local function quantile(xs: { number }, q: number): number
	table.sort(xs)
	return xs[math.max(1, math.floor(q * #xs))]
end

-- unmodified responder with reaction r after dispatch
local function trial(r: number): (number, number)
	local arrive = oneWay()
	local dispatch = arrive + math.random() * STEP
	local fire = dispatch + r
	local leave = fire + math.random() * STEP
	local land = leave + oneWay()
	local decode = land + math.random() * STEP
	return decode, arrive
end

for _, bound in { 0.10, 0.12 } do
	print(string.format("-- bound (min ping) = %.2f s", bound))
	for _, r in { 0, 0.1, 0.15 } do
		local slack: { number } = table.create(TRIALS)
		local case1 = 0
		for i = 1, TRIALS do
			local decode = trial(r)
			slack[i] = (decode - bound) - r
			if decode < 0.5 * bound then case1 += 1 end
		end
		print(string.format("r = %.2f s: slack (estimate - r) min %.4f p1 %.4f p50 %.4f p99 %.4f; case 1 by time (factor 0.5): %d",
			r, quantile(slack, 0), quantile(slack, 0.01), quantile(slack, 0.5), quantile(slack, 0.99), case1))
		local floorHits = { [0.05] = 0, [0.1] = 0, [0.12] = 0 }
		for i = 1, TRIALS do
			local est = slack[i] + r
			for f, n in floorHits do
				if est < f then floorHits[f] = n + 1 end
			end
		end
		print(string.format("            below floor 0.05: %.2f%%, 0.10: %.2f%%, 0.12: %.2f%%",
			100 * floorHits[0.05] / TRIALS, 100 * floorHits[0.1] / TRIALS, 100 * floorHits[0.12] / TRIALS))
	end
end

-- responders that fire at a fixed lead relative to the stimulus flush, without the stimulus
print("-- responders firing at time L after the stimulus flush (negative: before), not waiting for it; bound 0.10")
for _, L in { -0.2, -0.05, 0, 0.03, 0.06 } do
	local byTime, byReceipt, byFloor = 0, 0, 0
	for _ = 1, TRIALS do
		local arrive = oneWay()
		local fire = L
		local leave = fire + math.random() * STEP
		local land = leave + oneWay()
		local decode = land + math.random() * STEP
		local elapsed = decode
		if elapsed < 0.05 then byTime += 1 end
		if leave < arrive then byReceipt += 1 end -- the response frame left before the stimulus frame arrived
		if elapsed - 0.10 < 0.10 then byFloor += 1 end
	end
	print(string.format("L = %+.2f s: case 1 by time %.1f%%, case 1 by receipt %.1f%%, floor 0.10 %.1f%%",
		L, 100 * byTime / TRIALS, 100 * byReceipt / TRIALS, 100 * byFloor / TRIALS))
end
