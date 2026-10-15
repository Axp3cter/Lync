--!strict
-- R16: what one viewer can learn about its own decoys from slot numbers alone, under three slot schemes, and the
-- allocation cost of the scheme that hides them. Model, not Lync code.
-- Collection: maxRecords 1024 slots; real records arrive Poisson at RATE/s, live EXP(LIFE) s, slot reusable 2 s
-- after a remove (v5-collections.md §2), drawn uniformly among free slots. One viewer sees every real record
-- (audience all, no interest) and its own decoys: maxPerViewer 1, each decoy lives EXP(DLIFE) s and the behaviour
-- replaces it at the next state tick (20 Hz) once a slot is available.
-- Schemes:
--   range   decoy slots outside the shared range: slot index >= maxRecords (R16 as proposed)
--   pool0   the design's pool (v5-integrity.md §8): one pool slot per lane, fixed, reused with no delay
--   pool2   the same pool, honouring the 2 s reuse delay
--   shared  one allocator: a decoy takes a slot from the same free list as real records (R16 re-judged)
-- Statistic a viewer can compute: for every add it sees in slot s, the gap since it last saw slot s removed.
-- Output: share of decoy adds and of real adds whose gap is under G, for several G; the best single-threshold
-- accuracy of "gap < G means decoy", balanced over the two classes.
local MAX, RATE, LIFE, DLIFE, TICK, T = 1024, 3.2, 20, 5, 0.05, 7200
local function expo(mean: number): number
	return -mean * math.log(1 - math.random())
end
local function run(scheme: string, seed: number)
	math.randomseed(seed)
	local free: { number } = {}
	for s = 0, MAX - 1 do
		free[#free + 1] = s
	end
	local cooling: { { at: number, slot: number } } = {} -- removed slots waiting 2 s
	local live: { { slot: number, dies: number } } = {}
	local lastRemove: { [number]: number } = {}
	local gapsReal: { number }, gapsDecoy: { number } = {}, {}
	local poolSlot = -1
	if scheme == "pool0" or scheme == "pool2" then
		local i = math.random(#free)
		poolSlot = free[i]
		free[i] = free[#free]
		free[#free] = nil
	end
	local decoy: { slot: number, dies: number }? = nil
	local poolFreeAt = 0
	local nextArrival = expo(1 / RATE)
	local function take(): number?
		if #free == 0 then
			return nil
		end
		local i = math.random(#free)
		local s = free[i]
		free[i] = free[#free]
		free[#free] = nil
		return s
	end
	local function seen(s: number, t: number, isDecoy: boolean)
		local r = lastRemove[s]
		if r then
			table.insert(if isDecoy then gapsDecoy else gapsReal, t - r)
		end
	end
	local t = 0
	while t < T do
		t += TICK
		-- cooled slots return
		local k = 1
		while k <= #cooling do
			if cooling[k].at <= t then
				free[#free + 1] = cooling[k].slot
				cooling[k] = cooling[#cooling]
				cooling[#cooling] = nil
			else
				k += 1
			end
		end
		-- real removes
		k = 1
		while k <= #live do
			local r = live[k]
			if r.dies <= t then
				lastRemove[r.slot] = t
				table.insert(cooling, { at = t + 2, slot = r.slot })
				live[k] = live[#live]
				live[#live] = nil
			else
				k += 1
			end
		end
		-- real adds
		while nextArrival <= t do
			local s = take()
			if s then
				seen(s, t, false)
				table.insert(live, { slot = s, dies = t + expo(LIFE) })
			end
			nextArrival += expo(1 / RATE)
		end
		-- decoy lifecycle
		if decoy and decoy.dies <= t then
			local s = decoy.slot
			lastRemove[s] = t
			if scheme == "shared" then
				table.insert(cooling, { at = t + 2, slot = s })
			elseif scheme == "pool2" then
				poolFreeAt = t + 2
			end
			decoy = nil
		end
		if decoy == nil then
			local s: number? = nil
			if scheme == "range" then
				s = MAX -- first slot above the shared range
			elseif scheme == "pool0" then
				s = poolSlot
			elseif scheme == "pool2" then
				if t >= poolFreeAt then
					s = poolSlot
				end
			else
				s = take()
			end
			if s then
				seen(s, t, true)
				decoy = { slot = s, dies = t + expo(DLIFE) }
			end
		end
	end
	return gapsReal, gapsDecoy
end
local function share(g: { number }, lim: number): number
	local n = 0
	for _, x in g do
		if x < lim then
			n += 1
		end
	end
	return if #g == 0 then 0 else n / #g
end
print(string.format("model: maxRecords %d, real arrivals %.1f/s, life %d s, decoy life %d s, %d s simulated", MAX, RATE, LIFE, DLIFE, T))
for _, scheme in { "range", "pool0", "pool2", "shared" } do
	local real, dec = run(scheme, 42)
	local line = string.format("%-6s reuse adds seen: real %d, decoy %d |", scheme, #real, #dec)
	for _, G in { 1.99, 2.5, 5, 30, 120 } do
		line ..= string.format(" G=%g: decoy %.3f real %.4f |", G, share(dec, G), share(real, G))
	end
	-- best balanced accuracy of "gap < G => decoy" over a sweep
	local best, bestG = 0.5, 0
	for G = 0.5, 600, 0.5 do
		local acc = 0.5 * share(dec, G) + 0.5 * (1 - share(real, G))
		if acc > best then
			best, bestG = acc, G
		end
	end
	print(line .. string.format(" best balanced accuracy %.3f at G=%g", best, bestG))
end
print("range: every decoy add has slot >= maxRecords; no real add does (exact by construction)")
