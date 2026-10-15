--!strict
-- R21: counting `limit` by client send time against the design's arrival-time bucket.
-- Three server rules, each a token bucket that starts full and refills continuously (v5.md §5.4):
--   A  design:     clock = arrival time a_i; capacity burst + W * perSecond (W = the 2 s slack).
--   B  send time:  clock = the client-stated time, clamped to [max(previous clamped, a_i - W), a_i]; capacity burst.
--   C  count time: clock = upstream reliable frame count / 60 (M11's "frame tick"); capacity burst.
-- Honest client: game code fires at a steady rate; the client throttles itself to (perSecond, burst) with a FIFO
-- (v5.md §5.4), flushes every 1/60 s, one frame per flush; a reliable-lane stall of d seconds holds every frame
-- sent in it and releases them together (the simulated network of v5.md §9). Its stated time is its true send time.
-- Modified client: chooses arrival times and stated times freely (no client throttle).
-- Prints accepted and dropped counts. Deterministic: no randomness except a seeded xorshift for strategy "random".

local LAT = 0.05 -- one-way latency, s (Net.DEFAULT)
local W = 2.0 -- slack seconds (v5.md §4.9)

type Msg = { a: number, s: number, frame: number } -- arrival, stated send time, frame count at send

local function bucket(perSecond: number, cap: number)
	local tokens, last = cap, nil :: number?
	return function(t: number): boolean
		if last then
			tokens = math.min(cap, tokens + perSecond * (t - (last :: number)))
		end
		last = t
		if tokens >= 1 then
			tokens -= 1
			return true
		end
		return false
	end
end

local function ruleA(msgs: { Msg }, p: number, b: number): number
	local take, ok = bucket(p, b + W * p), 0
	for _, m in msgs do
		if take(m.a) then ok += 1 end
	end
	return ok
end

local function ruleB(msgs: { Msg }, p: number, b: number): number
	local take, ok, prev = bucket(p, b), 0, -math.huge
	for _, m in msgs do
		local t = math.clamp(m.s, math.max(prev, m.a - W), m.a)
		prev = t
		if take(t) then ok += 1 end
	end
	return ok
end

local function ruleC(msgs: { Msg }, p: number, b: number): number
	local take, ok = bucket(p, b), 0
	for _, m in msgs do
		if take(m.frame / 60) then ok += 1 end
	end
	return ok
end

-- Honest: fires every 1/rate s for `dur` s; client bucket (p, b) with FIFO of b; flush at 60 Hz;
-- stall [stallAt, stallAt + d) holds frames, released at stallAt + d.
local function honest(rate: number, p: number, b: number, dur: number, stallAt: number, d: number): { Msg }
	local msgs: { Msg } = {}
	local tokens, fifo, nextFire, frame = b, 0, 0.0, 0
	local t = 0.0
	while t < dur do
		tokens = math.min(b, tokens + p / 60)
		while nextFire <= t do
			fifo += 1
			nextFire += 1 / rate
		end
		if fifo > b then fifo = b end -- sendDropped cause 3 on the client: not sent
		local sent = 0
		while fifo > 0 and tokens >= 1 do
			tokens -= 1
			fifo -= 1
			sent += 1
		end
		if sent > 0 then
			local a = t + LAT
			if t >= stallAt and t < stallAt + d then a = stallAt + d + LAT end
			for _ = 1, sent do
				table.insert(msgs, { a = a, s = t, frame = frame })
			end
			frame += 1 -- one frame per flush that carries data
		end
		t += 1 / 60
	end
	table.sort(msgs, function(x, y) return x.a < y.a or (x.a == y.a and x.s < y.s) end)
	return msgs
end

print("== honest client, true stated times; dropped messages per rule (A design, B send time, C count time)")
print(string.format("%-28s %6s %6s %6s %6s %6s", "limit / fire rate / stall", "sent", "A", "B", "C", ""))
for _, cfg in { { p = 10, b = 20, rate = 10 }, { p = 10, b = 20, rate = 5 }, { p = 1, b = 2, rate = 1 }, { p = 60, b = 60, rate = 60 } } do
	for _, d in { 0, 0.3, 0.85, 1.5, 1.9, 2.0, 2.5, 4.0 } do
		local msgs = honest(cfg.rate, cfg.p, cfg.b, 20, 5, d)
		local n = #msgs
		print(string.format("p=%-3d b=%-3d fire=%-3d d=%-4.2f %6d %6d %6d %6d", cfg.p, cfg.b, cfg.rate, d, n,
			n - ruleA(msgs, cfg.p, cfg.b), n - ruleB(msgs, cfg.p, cfg.b), n - ruleC(msgs, cfg.p, cfg.b)))
	end
end

-- Modified client strategies. Stated time strategy: "early" (-inf, clamps to the window's start), "late" (= arrival),
-- "random" (uniform in the window), "paced" (1/perSecond apart from the earliest allowed). Frames: one message per frame (count clock advances per message) unless noted.
local x = 0x2545F491
local function rnd(): number
	x = bit32.bxor(x, bit32.lshift(x, 13)); x = bit32.bxor(x, bit32.rshift(x, 17)); x = bit32.bxor(x, bit32.lshift(x, 5))
	return x / 2 ^ 32
end
local function stated(kind: string, a: number, i: number, first: number, p: number): number
	if kind == "early" then return -math.huge end
	if kind == "late" then return a end
	if kind == "paced" then return first - W + (i - 1) / p end -- one token's worth apart, from the earliest allowed
	return a - W * rnd()
end

local function attack(name: string, arrivals: { number }, p: number, b: number)
	local best = 0
	for _, kind in { "early", "late", "random", "paced" } do
		local msgs: { Msg } = {}
		for i, a in arrivals do
			table.insert(msgs, { a = a, s = stated(kind, a, i, arrivals[1], p), frame = i - 1 })
		end
		best = math.max(best, ruleB(msgs, p, b))
	end
	local msgs: { Msg } = {}
	for i, a in arrivals do
		table.insert(msgs, { a = a, s = a, frame = i - 1 })
	end
	local span = arrivals[#arrivals] - arrivals[1]
	print(string.format("%-46s %7d %7d %7d %7d   bound b + p(W + span) = %.0f", name, #arrivals, ruleA(msgs, p, b), best,
		ruleC(msgs, p, b), b + p * (W + span)))
end

print("== modified client; accepted messages (A design, B best of four stated-time strategies, C count time)")
print(string.format("%-46s %7s %7s %7s %7s", "arrival pattern (p = 10, b = 20)", "sent", "A", "B", "C"))
local p, b = 10, 20
do
	local arr = {}
	for i = 1, 1000 do arr[i] = 10.0 end
	attack("1000 at one instant after 10 s idle", arr, p, b)
end
do
	local arr = {}
	for i = 1, 1000 do arr[i] = (i - 1) / 100 end
	attack("100/s for 10 s (10 x limit)", arr, p, b)
end
do
	local arr = {}
	for i = 1, 1200 do arr[i] = (i - 1) / 120 end
	attack("120 frames/s for 10 s, 1 message each", arr, p, b)
end
do
	local arr = {}
	local k = 0
	for burst = 0, 9 do
		for _ = 1, 100 do k += 1; arr[k] = burst * 3.0 end
	end
	attack("100 every 3 s, 10 times (hold and release)", arr, p, b)
end
do
	local arr = {}
	for i = 1, 600 do arr[i] = (i - 1) / 60 end
	attack("60/s for 10 s, one frame each (6 x limit)", arr, p, b)
end
