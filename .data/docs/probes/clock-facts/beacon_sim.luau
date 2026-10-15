--!strict
-- U3 and the BEACON frame gap: the clock-beacon estimator of design/v5-integrity.md §6, simulated per player.
-- Every engine timing is an assumption (marked); the network models are v5.md §9's default and one chosen "mobile"
-- model. Nothing here is measured on Roblox.
--
-- Client (60 Hz frames, one flush per frame, v5.md §5.1):
--   beacon delivery "force": the beacon is pending reliable data, so it leaves at the first flush at or after
--     lastBeacon + P (P = clock.beacon / 10 s);
--   "ride" with game reliable sends as a Poisson process of rate lambda per s: it leaves with the first reliable
--     frame after lastBeacon + P, approximated as the flush after lastBeacon + P + Exp(1 / lambda) (memoryless);
--     lambda = 0 is a client that sends only unreliable frames, or nothing.
--   stamp = floor((send + err) * 1000) / 1000 (the u16 ms beacon, unwrapped); err = the client's GetServerTimeNow
--     error: correction episodes at up to 0.6% (the documented bound), a sustained 0.6% slew, or a modified clock
--     with net rate excess r on top.
-- Network, reliable lane, ordered: one-way = base + jitter, plus an optional uplink queue q(t); stalls hold every
--   frame due inside them until they end. Server decodes at its next 60 Hz step; arrival clock = server os.clock().
-- Estimator: windows w = floor(decode / 5) aligned to the server clock; min of o = decode - stamp per window; first
--   30 s after join ignored; a decode gap over 3 * P restarts (windows cleared); at each 5 s epoch a player whose
--   12 latest windows are all present gets a Theil-Sen fit; s = -slope (seconds of client clock gain per second).
-- Fact rule: F = 3 consecutive fits with |s| > T and one sign. Evidence computed: s, the leave-one-out median of the
--   other players' s at the same epoch (othersSlope), drift = o(first window since restart) - o(current window).
-- Run: luau -O2 beacon_sim.luau
local WIN, NWIN, WARM, STEP = 5.0, 12, 30.0, 1 / 60

local function expo(mean: number): number
	return -mean * math.log(1 - math.random())
end

type Net = { name: string, base: number, jitter: (() -> number), stallRate: number, stallLen: (() -> number) }
local DEFAULT: Net = {
	name = "v5 §9 default (0.05 + U(0, 0.02) s, stalls 0.05/s x 0.3 s)",
	base = 0.05,
	jitter = function() return math.random() * 0.02 end,
	stallRate = 0.05,
	stallLen = function() return 0.3 end,
}
local MOBILE: Net = {
	name = "mobile, chosen (0.08 + Exp(0.04) s, stalls 0.2/s x U(0.1, 0.8) s)",
	base = 0.08,
	jitter = function() return expo(0.04) end,
	stallRate = 0.2,
	stallLen = function() return 0.1 + math.random() * 0.7 end,
}

type Sc = {
	name: string,
	net: Net,
	n: number,
	period: number,
	lambda: number?, -- nil = force
	clock: string, -- "episodes" | "slew"
	modified: { count: number, rate: number }?,
	queue: ((t: number) -> number)?, -- uplink queue delay, every player at the same time
	queueAt: ((t: number, t0: number) -> number)?, -- uplink queue delay, per player from a random t0 in [100, 400) s
	common: ((t: number) -> number)?, -- server-side inbound delay, every player
	duration: number,
}

local slopes = table.create(66, 0)
local function theilSen(ys: { number }): number
	local k = 0
	for i = 1, NWIN - 1 do
		for j = i + 1, NWIN do
			k += 1
			slopes[k] = (ys[j] - ys[i]) / (WIN * (j - i))
		end
	end
	table.sort(slopes)
	return (slopes[33] + slopes[34]) / 2
end

local hslopes = table.create(15, 0)
local function theilSenHalf(ys: { number }, first: number): number
	local k = 0
	for i = first, first + 4 do
		for j = i + 1, first + 5 do
			k += 1
			hslopes[k] = (ys[j] - ys[i]) / (WIN * (j - i))
		end
	end
	table.sort(hslopes)
	return hslopes[8]
end

local function nextFlush(t: number, phase: number): number
	return phase + math.ceil((t - phase) / STEP) * STEP
end

type PlayerOut = {
	modified: boolean,
	fit: { [number]: number }, -- epoch -> s
	half: { [number]: { number } }, -- epoch -> { s of windows 1-6, s of windows 7-12 }
	drift: { [number]: number },
	restarts: number,
	beacons: number,
}

local function simPlayer(sc: Sc, modified: boolean): PlayerOut
	local P = sc.period
	local phase = math.random() * STEP
	local out: PlayerOut = { modified = modified, fit = {}, half = {}, drift = {}, restarts = 0, beacons = 0 }
	-- stall intervals on this player's uplink
	local stalls: { { number } } = {}
	local t = expo(1 / sc.net.stallRate)
	while t < sc.duration + 10 do
		local len = sc.net.stallLen()
		table.insert(stalls, { t, t + len })
		t += len + expo(1 / sc.net.stallRate)
	end
	local si = 1
	local err = (math.random() - 0.5) * 0.1
	local episodeEnd, episodeRate = -1, 0
	local mins: { [number]: number } = {}
	local firstO: number? = nil
	local lastDecode, lastArrive = -1, -1
	local restartAt = 0
	local lastT = 0
	local send = nextFlush(math.random() * P, phase)
	local rate = modified and (sc.modified :: any).rate or 0
	local t0 = 100 + math.random() * 300
	while send < sc.duration do
		local dt = send - lastT
		lastT = send
		if sc.clock == "none" then
			-- no clock error: network and quantization noise only
		elseif sc.clock == "slew" then
			err += 0.006 * dt
		else
			if send > episodeEnd then
				if math.random() < 0.02 * P / 1.0 then
					local delta = (math.random() - 0.5) * 0.2
					episodeRate = (delta > 0 and 0.006 or -0.006) * math.random()
					episodeEnd = send + math.abs(delta) / math.max(math.abs(episodeRate), 1e-9)
					episodeEnd = math.min(episodeEnd, send + 60)
				else
					episodeRate = 0
				end
			end
			err += episodeRate * dt
		end
		err += rate * dt
		local stamp = math.floor((send + err) * 1000) / 1000
		local arrive = send + sc.net.base + sc.net.jitter()
		if sc.queue then arrive += (sc.queue :: (number) -> number)(send) end
		if sc.queueAt then arrive += (sc.queueAt :: (number, number) -> number)(send, t0) end
		while si <= #stalls and stalls[si][2] < arrive do si += 1 end
		if si <= #stalls and arrive >= stalls[si][1] then arrive = stalls[si][2] end
		if arrive < lastArrive then arrive = lastArrive end -- ordered lane
		lastArrive = arrive
		local decode = math.ceil(arrive / STEP) * STEP
		if sc.common then decode += (sc.common :: (number) -> number)(arrive) end
		out.beacons += 1
		if lastDecode >= 0 and decode - lastDecode > 3 * P then
			mins = {}
			firstO = nil
			restartAt = decode
			out.restarts += 1
		end
		lastDecode = decode
		if decode >= WARM then
			local w = math.floor(decode / WIN)
			if w * WIN >= restartAt then
				local o = decode - stamp
				local cur = mins[w]
				if cur == nil or o < cur then mins[w] = o end
			end
		end
		-- fit at each epoch boundary crossed before the next beacon is handled
		-- (done after the loop from mins history instead: keep a snapshot of windows per epoch)
		out.fit[-1] = 0
		-- next beacon
		local due = send + P
		if sc.lambda == nil then
			send = nextFlush(due, phase)
		elseif sc.lambda == 0 then
			break
		else
			send = nextFlush(due + expo(1 / (sc.lambda :: number)), phase)
		end
		-- record windows for fitting: store into a persistent per-epoch structure
		local e = math.floor(decode / WIN)
		local hist = (out :: any).hist or {}
		;(out :: any).hist = hist
		hist[e] = { mins = mins, first = firstO }
		if firstO == nil then
			local w0 = math.floor(decode / WIN)
			if mins[w0] then firstO = mins[w0] end
		end
	end
	out.fit[-1] = nil
	-- fits: at the end of epoch e (time (e + 1) * WIN), using the window table in force then
	local hist = (out :: any).hist or {}
	local ys = table.create(NWIN, 0)
	local nE = math.floor(sc.duration / WIN)
	local lastTbl = nil
	local lastFirst = nil
	for e = 0, nE - 1 do
		local h = hist[e]
		if h then lastTbl, lastFirst = h.mins, h.first end
		if lastTbl and e >= NWIN - 1 then
			local ok = true
			for k = 1, NWIN do
				local v = lastTbl[e - NWIN + k]
				if v == nil then ok = false break end
				ys[k] = v
			end
			if ok then
				out.fit[e] = -theilSen(ys)
				out.half[e] = { -theilSenHalf(ys, 1), -theilSenHalf(ys, 7) }
				if lastFirst then out.drift[e] = lastFirst - ys[NWIN] end
			end
		end
	end
	;(out :: any).hist = nil
	return out
end

local function q(xs: { number }, p: number): number
	if #xs == 0 then return 0 / 0 end
	return xs[math.max(1, math.min(#xs, math.ceil(p * #xs)))]
end

local function looMedian(sorted: { number }, x: number): (number, number)
	-- median of sorted minus one occurrence of x
	local n = #sorted
	if n <= 1 then return 0, 0 end
	local c = table.create(n - 1, 0)
	local removed = false
	local k = 0
	for i = 1, n do
		if not removed and sorted[i] == x then
			removed = true
		else
			k += 1
			c[k] = sorted[i]
		end
	end
	local m = n - 1
	if m % 2 == 1 then return c[(m + 1) // 2], m end
	return (c[m // 2] + c[m // 2 + 1]) / 2, m
end

local function report(sc: Sc, seeds: number)
	local nE = math.floor(sc.duration / WIN)
	local absH, absM = {}, {}
	local fitsH, fitsM, epochsAvail, restarts, beacons, players = 0, 0, 0, 0, 0, 0
	-- (T, F, split): split = 1 also requires both half fits (windows 1-6, 7-12) beyond T with the fit's sign
	local COMBOS = { { 0.01, 3, 0 }, { 0.01, 4, 0 }, { 0.01, 5, 0 }, { 0.0068, 3, 0 }, { 0.0068, 4, 0 }, { 0.01, 3, 1 }, { 0.0068, 3, 1 } }
	local factH, factM = table.create(#COMBOS, 0), table.create(#COMBOS, 0)
	local function combos(counts: { number }): string
		local parts = {}
		for i, c in COMBOS do table.insert(parts, string.format("(%g, %d%s) %d", c[1], c[2], c[3] == 1 and ", split" or "", counts[i])) end
		return table.concat(parts, "; ")
	end
	local nH, nM = 0, 0
	local firstM, firstMs = {}, {}
	local gapLoo, driftsH, driftsM = {}, {}, {}
	for seed = 1, seeds do
		math.randomseed(seed * 7919 + 17)
		local ps: { PlayerOut } = {}
		local nMod = sc.modified and (sc.modified :: any).count or 0
		for i = 1, sc.n do
			table.insert(ps, simPlayer(sc, i <= nMod))
		end
		-- per epoch: all fits, sorted, for the leave-one-out median
		local sortedAt: { [number]: { number } } = {}
		for e = 0, nE - 1 do
			local xs = {}
			for _, p in ps do
				local s = p.fit[e]
				if s then table.insert(xs, s) end
			end
			table.sort(xs)
			sortedAt[e] = xs
		end
		for _, p in ps do
			players += 1
			restarts += p.restarts
			beacons += p.beacons
			if p.modified then nM += 1 else nH += 1 end
			epochsAvail += math.max(0, nE - (NWIN - 1 + math.ceil(WARM / WIN)))
			for ci, combo in COMBOS do
				local T, FF, split = combo[1], combo[2], combo[3]
				local run, sign, fired, firstAt = 0, 0, false, -1
				for e = 0, nE - 1 do
					local s = p.fit[e]
					local ok = s ~= nil and math.abs(s :: number) > T
					if ok and split == 1 then
						local h = p.half[e]
						local sg = (s :: number) > 0 and 1 or -1
						ok = h[1] * sg > T and h[2] * sg > T
					end
					if s and ok then
						local sg = s > 0 and 1 or -1
						if sg == sign then run += 1 else run, sign = 1, sg end
						if run >= FF and not fired then
							fired = true
							firstAt = (e + 1) * WIN
							if ci == 1 then
								local m = looMedian(sortedAt[e], s)
								table.insert(gapLoo, math.abs(s - m))
								local d = p.drift[e]
								if d then table.insert(p.modified and driftsM or driftsH, math.abs(d)) end
							end
						end
					else
						run, sign = 0, 0
					end
				end
				if fired then
					if p.modified then factM[ci] += 1 else factH[ci] += 1 end
					if p.modified and ci == 1 then table.insert(firstM, firstAt) end
					if p.modified and ci == 6 then table.insert(firstMs, firstAt) end
				end
			end
			for e = 0, nE - 1 do
				local s = p.fit[e]
				if s then
					if p.modified then
						fitsM += 1
						table.insert(absM, math.abs(s))
					else
						fitsH += 1
						table.insert(absH, math.abs(s))
					end
				end
			end
		end
	end
	table.sort(absH)
	table.sort(absM)
	table.sort(gapLoo)
	table.sort(firstM)
	table.sort(firstMs)
	table.sort(driftsH)
	table.sort(driftsM)
	local hours = players * sc.duration / 3600
	print(string.format("## %s", sc.name))
	print(string.format("   net %s; P %.1f s; %s; %d players x %d seeds x %d s", sc.net.name, sc.period,
		sc.lambda == nil and "beacon forced" or string.format("beacon rides reliable frames, lambda %.2f/s", sc.lambda :: number),
		sc.n, seeds, sc.duration))
	print(string.format("   coverage %.1f%% of epochs after 90 s have a fit; restarts %.1f per player-hour; beacons %.2f/s per player",
		100 * (fitsH + fitsM) / math.max(1, epochsAvail), restarts / hours, beacons / (players * sc.duration)))
	if fitsH > 0 then
		print(string.format("   unmodified |s|: p50 %.5f  p99 %.5f  p99.9 %.5f  max %.5f  (%d fits)", q(absH, 0.5), q(absH, 0.99), q(absH, 0.999), absH[#absH], fitsH))
		print(string.format("   unmodified players with a fact, of %d, by (T, F): %s", nH, combos(factH)))
	end
	if nM > 0 then
		print(string.format("   modified |s|: p1 %.5f  p50 %.5f  (%d fits); first fact at (0.01, 3) p50 %.0f s, max %.0f s; at (0.01, 3, split) p50 %.0f s, max %.0f s",
			q(absM, 0.01), q(absM, 0.5), fitsM, q(firstM, 0.5), firstM[#firstM] or -1, q(firstMs, 0.5), firstMs[#firstMs] or -1))
		print(string.format("   modified players with a fact, of %d, by (T, F): %s", nM, combos(factM)))
	end
	if #gapLoo > 0 then
		print(string.format("   at first fact (T 0.01, F 3): |slope - othersSlope| p50 %.4f max %.4f (%d facts)", q(gapLoo, 0.5), gapLoo[#gapLoo], #gapLoo))
	end
	if #driftsH > 0 then print(string.format("   unmodified |drift| at first fact: p50 %.2f s max %.2f s", q(driftsH, 0.5), driftsH[#driftsH])) end
	if #driftsM > 0 then print(string.format("   modified |drift| at first fact: p50 %.2f s max %.2f s", q(driftsM, 0.5), driftsM[#driftsM])) end
end

-- an uplink queue that builds to `depth` s over `up` s from t0, then drains over `down` s (a bufferbloat episode)
local function ramp(t0: number, depth: number, up: number, down: number): (number) -> number
	return function(t: number): number
		if t < t0 then return 0 end
		if t < t0 + up then return (t - t0) / up * depth end
		if t < t0 + up + down then return depth * (1 - (t - t0 - up) / down) end
		return 0
	end
end

-- a persistent level shift of the uplink delay by h s at a per-player t0, lasting `len` s (a standing queue
-- appearing when other traffic starts on the link, and leaving when it stops)
local function stepAt(h: number, len: number): (number, number) -> number
	return function(t: number, t0: number): number
		if t >= t0 and t < t0 + len then return h end
		return 0
	end
end
local function rampAt(depth: number, up: number, down: number): (number, number) -> number
	return function(t: number, t0: number): number
		return ramp(t0, depth, up, down)(t)
	end
end

local D = 600
local SEEDS = 3
local list: { Sc } = {
	-- noise of an unmodified client, by beacon period and network
	{ name = "A0 no clock error (network and quantization only), forced, P 1.0", net = DEFAULT, n = 100, period = 1.0, clock = "none", duration = D },
	{ name = "A0m no clock error, forced, P 1.5, mobile", net = MOBILE, n = 100, period = 1.5, clock = "none", duration = D },
	{ name = "A1 unmodified, forced, P 1.0", net = DEFAULT, n = 100, period = 1.0, clock = "episodes", duration = D },
	{ name = "A2 unmodified, forced, P 0.5", net = DEFAULT, n = 100, period = 0.5, clock = "episodes", duration = D },
	{ name = "A3 unmodified, forced, P 1.5", net = DEFAULT, n = 100, period = 1.5, clock = "episodes", duration = D },
	{ name = "A4 unmodified, forced, P 1.0, mobile", net = MOBILE, n = 100, period = 1.0, clock = "episodes", duration = D },
	{ name = "A5 unmodified, forced, P 1.5, mobile", net = MOBILE, n = 100, period = 1.5, clock = "episodes", duration = D },
	{ name = "A6 unmodified, sustained 0.6% slew, forced, P 1.0", net = DEFAULT, n = 100, period = 1.0, clock = "slew", duration = D },
	{ name = "A7 unmodified, sustained 0.6% slew, forced, P 1.0, mobile", net = MOBILE, n = 100, period = 1.0, clock = "slew", duration = D },
	-- the BEACON frame gap: riding beacons by game reliable-send rate, against forcing
	{ name = "B1 riding, lambda 0 (unreliable-only or idle client)", net = DEFAULT, n = 100, period = 1.0, lambda = 0, clock = "episodes", duration = D },
	{ name = "B2 riding, lambda 0.1/s", net = DEFAULT, n = 100, period = 1.0, lambda = 0.1, clock = "episodes", duration = D },
	{ name = "B3 riding, lambda 0.33/s", net = DEFAULT, n = 100, period = 1.0, lambda = 0.33, clock = "episodes", duration = D },
	{ name = "B4 riding, lambda 1/s", net = DEFAULT, n = 100, period = 1.0, lambda = 1, clock = "episodes", duration = D },
	{ name = "B5 riding, lambda 3/s", net = DEFAULT, n = 100, period = 1.0, lambda = 3, clock = "episodes", duration = D },
	{ name = "B6 riding, lambda 10/s", net = DEFAULT, n = 100, period = 1.0, lambda = 10, clock = "episodes", duration = D },
	{ name = "B7 riding, lambda 1/s, P 1.5", net = DEFAULT, n = 100, period = 1.5, lambda = 1, clock = "episodes", duration = D },
	-- known causes on an unmodified client: an uplink queue ramp (per player)
	{ name = "C1 uplink queue 0 -> 1 s over 60 s, drains over 30 s (every player, from t = 200 s)", net = DEFAULT, n = 100, period = 1.0, clock = "episodes", queue = ramp(200, 1.0, 60, 30), duration = D },
	{ name = "C2 uplink queue 0 -> 0.5 s over 60 s, drains over 60 s", net = DEFAULT, n = 100, period = 1.0, clock = "episodes", queue = ramp(200, 0.5, 60, 60), duration = D },
	{ name = "C3 uplink queue 0 -> 2 s over 120 s, drains over 10 s", net = DEFAULT, n = 100, period = 1.0, clock = "episodes", queue = ramp(200, 2.0, 120, 10), duration = D },
	{ name = "C1r uplink queue 0 -> 1 s over 60 s, drains over 30 s, per player at a random time", net = DEFAULT, n = 100, period = 1.0, clock = "episodes", queueAt = rampAt(1.0, 60, 30), duration = D },
	{ name = "S1 uplink delay step +0.25 s for 120 s, per player at a random time", net = DEFAULT, n = 100, period = 1.0, clock = "episodes", queueAt = stepAt(0.25, 120), duration = D },
	{ name = "S2 uplink delay step +0.5 s for 120 s, per player", net = DEFAULT, n = 100, period = 1.0, clock = "episodes", queueAt = stepAt(0.5, 120), duration = D },
	{ name = "S3 uplink delay step +1.0 s for 120 s, per player", net = DEFAULT, n = 100, period = 1.0, clock = "episodes", queueAt = stepAt(1.0, 120), duration = D },
	{ name = "S4 uplink delay step +2.0 s for 120 s, per player", net = DEFAULT, n = 100, period = 1.0, clock = "episodes", queueAt = stepAt(2.0, 120), duration = D },
	{ name = "S5 uplink delay step +1.0 s for 8 s, per player (a burst shorter than 3 windows)", net = DEFAULT, n = 100, period = 1.0, clock = "episodes", queueAt = stepAt(1.0, 8), duration = D },
	{ name = "S6 uplink delay step +1.0 s for 120 s, per player, mobile", net = MOBILE, n = 100, period = 1.0, clock = "episodes", queueAt = stepAt(1.0, 120), duration = D },
	-- a server-side inbound delay that builds and drains for every player (hypothetical; nothing measured)
	{ name = "C4 server inbound delay 0 -> 1.8 s over 30 s, drains over 90 s (all players)", net = DEFAULT, n = 100, period = 1.0, clock = "episodes", common = ramp(240, 1.8, 30, 90), duration = D },
	-- modified clocks (net rate excess after the client's own sync correction)
	{ name = "D1 10 modified at +1%, forced", net = DEFAULT, n = 100, period = 1.0, clock = "episodes", modified = { count = 10, rate = 0.01 }, duration = D },
	{ name = "D1b 10 modified at +1.2%, forced, mobile", net = MOBILE, n = 100, period = 1.0, clock = "episodes", modified = { count = 10, rate = 0.012 }, duration = D },
	{ name = "D2 10 modified at +2%, forced", net = DEFAULT, n = 100, period = 1.0, clock = "episodes", modified = { count = 10, rate = 0.02 }, duration = D },
	{ name = "D3 10 modified at -2%, forced", net = DEFAULT, n = 100, period = 1.0, clock = "episodes", modified = { count = 10, rate = -0.02 }, duration = D },
	{ name = "D4 10 modified at +2%, riding, lambda 1/s", net = DEFAULT, n = 100, period = 1.0, lambda = 1, clock = "episodes", modified = { count = 10, rate = 0.02 }, duration = D },
	{ name = "D5 10 modified at +2%, forced, mobile", net = MOBILE, n = 100, period = 1.0, clock = "episodes", modified = { count = 10, rate = 0.02 }, duration = D },
	{ name = "D6 60 modified at +2% (a majority), forced", net = DEFAULT, n = 100, period = 1.0, clock = "episodes", modified = { count = 60, rate = 0.02 }, duration = D },
}
for _, sc in list do
	report(sc, SEEDS)
end
