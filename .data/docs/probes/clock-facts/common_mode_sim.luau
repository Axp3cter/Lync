--!strict
-- U3: what a server-wide ("common-mode") guard does to `clockRate` (v5-integrity.md §6), simulated.
--
-- Model, per player, in seconds of true server time t:
--   - a beacon every BEACON s (random phase; rides a frame the client sends anyway, so + up to 1/60 s);
--   - stamp = t + err(t), floored to 1 ms (the u16 ms beacon, unwrapped);
--     err(t): honest = correction episodes at <= 0.6% (the GetServerTimeNow contract), or, for the "slew" group,
--     a sustained 0.6% slew; modified = (rate - 1) * t on top (an accelerated or slowed clock);
--   - one-way delay = base + Exp(JIT) + a stall (prob 0.015, U(0, 0.3) s) + common(t) for affected players;
--   - the server decodes at its next 60 Hz step; during a hitch [H0, H0 + H) nothing is decoded until its end;
--   - o = decode - stamp. Windows of 5 s aligned to the server clock; keep min o per window.
--   - restart: a decode gap over 3 * BEACON clears the player's windows; the first 30 s after join are ignored.
--   - every aligned 5 s epoch, each player with 12 consecutive windows gets a Theil-Sen slope of o; the client
--     rate excess is s = -slope (positive = fast clock).
-- Rules for a fit to count toward the run (T = clock.reportSlope, run of F = clock.reportFits fits):
--   raw:     s > T (fast) or s < -T (slow), the design as written plus a symmetric slow side;
--   discard: an epoch where more than half of n >= MINN valid fits exceed T in one direction is discarded for
--            every player in that direction (runs freeze);
--   guard:   s - max(M, 0) > T (fast), s - min(M, 0) < -T (slow), M = median of the epoch's valid s when n >= MINN,
--            else M = 0.
--   literal: the research's window rule (CS T1): a window where more than half the players' minima moved the same
--            way from their previous window is dropped from every fit; reported as the share of windows dropped.
-- Output: players with at least one fact, per group and direction, per rule; first-fact delay for modified clients.
-- Run: luau -O2 common_mode_sim.luau

local BEACON, WIN, NWIN, WARM = 1.0, 5.0, 12, 30.0
local STEP = 1 / 60
local T, F = 0.01, 3

local function expo(mean: number): number
	return -mean * math.log(1 - math.random())
end

local slopes = table.create(66, 0)
local function theilSen(ys: { number }, first: number): number
	local k = 0
	for i = first, first + NWIN - 2 do
		for j = i + 1, first + NWIN - 1 do
			k += 1
			slopes[k] = (ys[j] - ys[i]) / (WIN * (j - i))
		end
	end
	table.sort(slopes)
	return (slopes[33] + slopes[34]) / 2
end

local function median(xs: { number }): number
	local c = table.clone(xs)
	table.sort(c)
	local n = #c
	if n % 2 == 1 then return c[(n + 1) // 2] end
	return (c[n // 2] + c[n // 2 + 1]) / 2
end

type Player = {
	group: string, -- "honest", "slew", "fast", "slow"
	rate: number, -- clock rate excess for modified clients
	base: number,
	common: boolean, -- affected by the common-mode delay
	phase: number,
	mins: { [number]: number },
	restartAt: number,
	joinAt: number,
	lastDecode: number,
	episodeEnd: number,
	episodeRate: number,
	err: number,
}

type Scenario = {
	name: string,
	n: number,
	jit: number,
	groups: { { group: string, count: number, rate: number } },
	common: ((t: number) -> number)?,
	commonShare: number?,
	hitch: { at: number, len: number }?,
	duration: number,
	minN: number,
}

local function run(sc: Scenario, seed: number)
	math.randomseed(seed)
	local players: { Player } = {}
	for _, g in sc.groups do
		for _ = 1, g.count do
			local p: Player = {
				group = g.group,
				rate = g.rate,
				base = 0.02 + math.random() * 0.1,
				common = false,
				phase = math.random() * BEACON,
				mins = {},
				restartAt = 0,
				joinAt = 0,
				lastDecode = 0,
				episodeEnd = -1,
				episodeRate = 0,
				err = (math.random() - 0.5) * 0.1,
			}
			table.insert(players, p)
		end
	end
	local share = sc.commonShare or 1
	for i, p in players do
		p.common = sc.common ~= nil and (i - 1) < share * #players
	end
	-- events: each player's beacons in time order, processed per player (players are independent until the fit)
	local nEpoch = math.floor(sc.duration / WIN)
	for _, p in players do
		local t = p.phase
		local lastT = 0
		while t < sc.duration do
			local dt = t - lastT
			lastT = t
			-- honest clock error: correction episodes at up to 0.6%, or a sustained 0.6% slew
			if p.group == "slew" then
				p.err += 0.006 * dt
			else
				if t > p.episodeEnd then
					if math.random() < 0.02 then -- an episode starts about every 50 s
						local delta = (math.random() - 0.5) * 0.2
						p.episodeRate = (delta > 0 and 0.006 or -0.006) * math.random()
						p.episodeEnd = t + math.abs(delta) / 0.006
					else
						p.episodeRate = 0
					end
				end
				p.err += p.episodeRate * dt
			end
			if p.group == "fast" or p.group == "slow" then p.err += p.rate * dt end
			local sendT = t + math.random() * STEP
			local stamp = math.floor((sendT + p.err) * 1000) / 1000
			local d = p.base + expo(sc.jit)
			if math.random() < 0.015 then d += math.random() * 0.3 end
			if p.common and sc.common then d += sc.common(sendT) end
			local arrive = sendT + d
			local decode = math.ceil(arrive / STEP) * STEP
			local h = sc.hitch
			if h and decode >= h.at and decode < h.at + h.len then decode = h.at + h.len end
			if decode - p.lastDecode > 3 * BEACON and p.lastDecode > 0 then
				p.mins = {}
				p.restartAt = decode
			end
			p.lastDecode = decode
			if decode >= p.joinAt + WARM then
				local w = math.floor(decode / WIN)
				-- only windows that start after the restart count
				if w * WIN >= p.restartAt then
					local o = decode - stamp
					local cur = p.mins[w]
					if cur == nil or o < cur then p.mins[w] = o end
				end
			end
			t += BEACON
		end
	end
	-- literal window rule: share of windows dropped under "more than half moved the same way"
	local dropped, considered = 0, 0
	for w = 1, nEpoch - 1 do
		local up, down, m = 0, 0, 0
		for _, p in players do
			local a, b = p.mins[w - 1], p.mins[w]
			if a and b then
				m += 1
				if b > a then up += 1 elseif b < a then down += 1 end
			end
		end
		if m >= 2 then
			considered += 1
			if up > m / 2 or down > m / 2 then dropped += 1 end
		end
	end
	-- fits per epoch
	local res = {}
	for _, rule in { "raw", "discard", "guard" } do
		res[rule] = { runs = {}, facts = {}, first = {} }
		for i = 1, #players do
			res[rule].runs[i] = { fast = 0, slow = 0 }
			res[rule].facts[i] = { fast = 0, slow = 0 }
		end
	end
	local ys = table.create(NWIN, 0)
	local maxAbsM = 0
	for e = NWIN - 1, nEpoch - 1 do
		local s: { [number]: number } = {}
		local valid: { number } = {}
		for i, p in players do
			local ok = true
			for k = 1, NWIN do
				local v = p.mins[e - NWIN + k]
				if v == nil then ok = false break end
				ys[k] = v
			end
			if ok then
				local sl = -theilSen(ys, 1)
				s[i] = sl
				table.insert(valid, sl)
			end
		end
		local n = #valid
		local M = 0
		if n >= sc.minN then M = median(valid) end
		if math.abs(M) > maxAbsM then maxAbsM = math.abs(M) end
		local fastCount, slowCount = 0, 0
		for _, v in valid do
			if v > T then fastCount += 1 elseif v < -T then slowCount += 1 end
		end
		local discardFast = n >= sc.minN and fastCount > n / 2
		local discardSlow = n >= sc.minN and slowCount > n / 2
		local tEpoch = (e + 1) * WIN
		for i, sl in s do
			for _, rule in { "raw", "discard", "guard" } do
				local fastHit, slowHit
				local frozenFast, frozenSlow = false, false
				if rule == "guard" then
					fastHit = sl - math.max(M, 0) > T
					slowHit = sl - math.min(M, 0) < -T
				else
					fastHit = sl > T
					slowHit = sl < -T
					if rule == "discard" then frozenFast, frozenSlow = discardFast, discardSlow end
				end
				local r = res[rule]
				local runs, facts = r.runs[i], r.facts[i]
				if not frozenFast then runs.fast = fastHit and runs.fast + 1 or 0 end
				if not frozenSlow then runs.slow = slowHit and runs.slow + 1 or 0 end
				if not frozenFast and fastHit and runs.fast >= F then
					facts.fast += 1
					if r.first[i] == nil then r.first[i] = tEpoch end
				end
				if not frozenSlow and slowHit and runs.slow >= F then
					facts.slow += 1
					if r.first[i] == nil then r.first[i] = tEpoch end
				end
			end
		end
		-- players with no fit this epoch: their runs restart (no fit, no run)
		for i = 1, #players do
			if s[i] == nil then
				for _, rule in { "raw", "discard", "guard" } do
					res[rule].runs[i].fast = 0
					res[rule].runs[i].slow = 0
				end
			end
		end
	end
	return players, res, dropped, considered, maxAbsM
end

local function report(sc: Scenario, seeds: number)
	local agg = {}
	local dropped, considered, maxM = 0, 0, 0
	local firstSum, firstN = { raw = 0, discard = 0, guard = 0 }, { raw = 0, discard = 0, guard = 0 }
	for seed = 1, seeds do
		local players, res, d, c, m = run(sc, seed * 7919 + 13)
		dropped += d
		considered += c
		if m > maxM then maxM = m end
		for _, rule in { "raw", "discard", "guard" } do
			for i, p in players do
				local key = rule .. "|" .. p.group .. (p.common and "*" or "")
				local a = agg[key] or { players = 0, fast = 0, slow = 0 }
				agg[key] = a
				a.players += 1
				if res[rule].facts[i].fast > 0 then a.fast += 1 end
				if res[rule].facts[i].slow > 0 then a.slow += 1 end
				if (p.group == "fast" or p.group == "slow") and res[rule].first[i] then
					firstSum[rule] += res[rule].first[i]
					firstN[rule] += 1
				end
			end
		end
	end
	print(string.format("## %s (n = %d, jitter mean %.2f s, %d seeds, %d s each)", sc.name, sc.n, sc.jit, seeds, sc.duration))
	print(string.format("literal window rule: %d of %d windows dropped (%.1f%%); max |median slope| %.4f", dropped, considered, 100 * dropped / math.max(1, considered), maxM))
	local keys = {}
	for k in agg do table.insert(keys, k) end
	table.sort(keys)
	for _, k in keys do
		local a = agg[k]
		print(string.format("  %-22s players %5d  with fast fact %5d (%5.1f%%)  with slow fact %5d (%5.1f%%)", k, a.players, a.fast, 100 * a.fast / a.players, a.slow, 100 * a.slow / a.players))
	end
	for _, rule in { "raw", "discard", "guard" } do
		if firstN[rule] > 0 then
			print(string.format("  %-8s mean first fact for modified clients at t = %.0f s (%d of them)", rule, firstSum[rule] / firstN[rule], firstN[rule]))
		end
	end
end

local SEEDS = 5
local function honest(n: number): { group: string, count: number, rate: number }
	return { group = "honest", count = n, rate = 0 }
end

-- a backlog that builds over 30 s and drains over 90 s: a 2% apparent fast clock while it drains (hypothetical)
local function drain(t: number): number
	if t < 240 or t > 360 then return 0 end
	if t < 270 then return (t - 240) / 30 * 1.8 end
	return 1.8 * (1 - (t - 270) / 90)
end
-- a backlog that grows by 1.8 s over 90 s: a 2% apparent slow clock (hypothetical)
local function grow(t: number): number
	if t < 240 then return 0 end
	if t < 330 then return (t - 240) / 90 * 1.8 end
	if t < 340 then return 1.8 * (1 - (t - 330) / 10) end
	return 0
end

local MINN = 3
local scenarios: { Scenario } = {
	{ name = "honest, low jitter", n = 100, jit = 0.02, groups = { honest(90), { group = "slew", count = 10, rate = 0 } }, duration = 600, minN = MINN },
	{ name = "honest, high jitter", n = 100, jit = 0.1, groups = { honest(90), { group = "slew", count = 10, rate = 0 } }, duration = 600, minN = MINN },
	{ name = "honest, very high jitter", n = 100, jit = 0.25, groups = { honest(100) }, duration = 600, minN = MINN },
	{ name = "server-wide backlog drain (all players)", n = 100, jit = 0.05, groups = { honest(100) }, common = drain, duration = 600, minN = MINN },
	{ name = "server-wide backlog growth (all players)", n = 100, jit = 0.05, groups = { honest(100) }, common = grow, duration = 600, minN = MINN },
	{ name = "backlog drain, 60% of players", n = 100, jit = 0.05, groups = { honest(100) }, common = drain, commonShare = 0.6, duration = 600, minN = MINN },
	{ name = "backlog drain, 40% of players", n = 100, jit = 0.05, groups = { honest(100) }, common = drain, commonShare = 0.4, duration = 600, minN = MINN },
	{ name = "server hitch 2 s at 300 s", n = 100, jit = 0.05, groups = { honest(100) }, hitch = { at = 300, len = 2 }, duration = 600, minN = MINN },
	{ name = "server hitch 10 s at 300 s", n = 100, jit = 0.05, groups = { honest(100) }, hitch = { at = 300, len = 10 }, duration = 600, minN = MINN },
	{ name = "10 fast clocks at +2%", n = 100, jit = 0.05, groups = { honest(90), { group = "fast", count = 10, rate = 0.02 } }, duration = 600, minN = MINN },
	{ name = "10 fast clocks at +2% during a backlog drain", n = 100, jit = 0.05, groups = { honest(90), { group = "fast", count = 10, rate = 0.02 } }, common = drain, duration = 600, minN = MINN },
	{ name = "55 fast clocks at +5% (a majority)", n = 100, jit = 0.05, groups = { honest(45), { group = "fast", count = 55, rate = 0.05 } }, duration = 600, minN = MINN },
	{ name = "10 slow clocks at -2%", n = 100, jit = 0.05, groups = { honest(90), { group = "slow", count = 10, rate = -0.02 } }, duration = 600, minN = MINN },
	{ name = "1 player, fast at +5%", n = 1, jit = 0.05, groups = { { group = "fast", count = 1, rate = 0.05 } }, duration = 600, minN = MINN },
	{ name = "2 players, one fast at +5%", n = 2, jit = 0.05, groups = { honest(1), { group = "fast", count = 1, rate = 0.05 } }, duration = 600, minN = MINN },
	{ name = "3 players, one fast at +5%", n = 3, jit = 0.05, groups = { honest(2), { group = "fast", count = 1, rate = 0.05 } }, duration = 600, minN = MINN },
	{ name = "3 players, two fast at +5%", n = 3, jit = 0.05, groups = { honest(1), { group = "fast", count = 2, rate = 0.05 } }, duration = 600, minN = MINN },
}
for _, sc in scenarios do
	report(sc, SEEDS)
end
