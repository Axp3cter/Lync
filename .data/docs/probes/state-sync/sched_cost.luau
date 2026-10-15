--!native
--!strict
-- Per-tick cost of per-viewer scheduling under a byte budget, on top of an encode-once model.
-- Each viewer has K relevant records; each tick a fraction DIRTY of records changed.
-- Every record's delta is encoded ONCE per tick into a shared buffer (CHUNK bytes each);
-- per viewer we (1) add priority to the accumulator of each dirty-or-pending record,
-- (2) choose records to send within BUDGET bytes, (3) copy their chunks into the viewer's frame,
-- (4) reset accumulators of sent records (unsent keep accumulating: starvation-free).
-- Selection variants:
--   sort   : collect candidates, table.sort by accumulator (descending)
--   bucket : 32 buckets by floor(log2(accumulator)), drain from the top (O(n), approximate order)
--   rr     : round-robin cursor over pending records, no priority (baseline)
local CHUNK = 12
local TICKS = 30

local seed = 3
local function rand(): number
	seed = (seed * 1103515245 + 12345) % 2147483648
	return seed / 2147483648
end

local function run(P: number, K: number, DIRTY: number, BUDGET: number, mode: string): (number, number, number)
	seed = 3
	local N = K * 4 -- records in the world; each viewer sees K of them
	local shared = buffer.create(N * CHUNK)
	local frame = buffer.create(BUDGET + CHUNK)
	-- viewer state: relevant ids, static priority per (viewer, record), accumulator, pending flag
	local ids: { { number } } = {}
	local prio: { { number } } = {}
	local acc: { { number } } = {}
	local pending: { { boolean } } = {}
	local cursor: { number } = {}
	for p = 1, P do
		local l = table.create(K, 0)
		local pr = table.create(K, 0)
		for k = 1, K do
			l[k] = (p * 131 + k * 7) % N + 1
			pr[k] = 0.1 + rand() * 4 -- distance-derived priority, 0.1 .. 4.1
		end
		ids[p] = l
		prio[p] = pr
		acc[p] = table.create(K, 0)
		pending[p] = table.create(K, false)
		cursor[p] = 1
	end
	local dirty = table.create(N, false)
	local cand = table.create(K, 0)
	local buckets: { { number } } = {}
	for b = 1, 40 do
		buckets[b] = table.create(K, 0)
	end
	local bucketN = table.create(40, 0)

	local times = {}
	local sentTotal, maxWait = 0, 0
	local waited: { { number } } = {}
	for p = 1, P do
		waited[p] = table.create(K, 0)
	end
	for r = 1, 5 do
		local t = 0
		for _ = 1, TICKS do
			-- world: mark dirty, encode each dirty record once (simulated by writing its chunk)
			for i = 1, N do
				local d = rand() < DIRTY
				dirty[i] = d
				if d then
					local o = (i - 1) * CHUNK
					buffer.writeu32(shared, o, i)
					buffer.writeu32(shared, o + 4, i * 3)
					buffer.writeu32(shared, o + 8, i * 5)
				end
			end
			local t0 = os.clock()
			for p = 1, P do
				local l, pr, a, pd, w = ids[p], prio[p], acc[p], pending[p], waited[p]
				local n = 0
				for k = 1, K do
					if dirty[l[k]] then
						pd[k] = true
					end
					if pd[k] then
						a[k] += pr[k]
						w[k] += 1
						n += 1
						cand[n] = k
					end
				end
				local used = 0
				local function send(k: number)
					buffer.copy(frame, used, shared, (l[k] - 1) * CHUNK, CHUNK)
					used += CHUNK
					a[k] = 0
					pd[k] = false
					if w[k] > maxWait then
						maxWait = w[k]
					end
					w[k] = 0
					sentTotal += 1
				end
				if mode == "sort" then
					local sorted = table.move(cand, 1, n, 1, table.create(n))
					table.sort(sorted, function(x: number, y: number): boolean
						return a[x] > a[y]
					end)
					for j = 1, n do
						if used + CHUNK > BUDGET then
							break
						end
						send(sorted[j])
					end
				elseif mode == "bucket" then
					for b = 1, 40 do
						bucketN[b] = 0
					end
					for j = 1, n do
						local k = cand[j]
						local b = math.clamp(math.floor(math.log(a[k], 2)) + 5, 1, 40)
						local m = bucketN[b] + 1
						bucketN[b] = m
						buckets[b][m] = k
					end
					for b = 40, 1, -1 do
						local bl = buckets[b]
						for j = 1, bucketN[b] do
							if used + CHUNK > BUDGET then
								break
							end
							send(bl[j])
						end
						if used + CHUNK > BUDGET then
							break
						end
					end
				else -- rr
					local c = cursor[p]
					for _ = 1, K do
						if used + CHUNK > BUDGET then
							break
						end
						if pd[c] then
							send(c)
						end
						c = c % K + 1
					end
					cursor[p] = c
				end
			end
			t += os.clock() - t0
		end
		times[r] = t / TICKS * 1000
	end
	table.sort(times)
	return times[3], sentTotal / (5 * TICKS * P), maxWait
end

print(`chunk {CHUNK} B, median of 5 x {TICKS} ticks; ms/tick covers accumulate + select + copy for all viewers`)
print("viewers\tK\tdirty\tbudgetB\tmode\tms/tick\tsent/viewer/tick\tmaxWaitTicks")
for _, cfg in { { 100, 300, 0.3, 600 }, { 100, 300, 0.3, 2400 }, { 200, 300, 0.3, 600 }, { 100, 1000, 0.3, 600 }, { 200, 1000, 0.1, 1000 } } do
	for _, mode in { "rr", "bucket", "sort" } do
		local ms, sent, mw = run(cfg[1], cfg[2], cfg[3], cfg[4], mode)
		print(`{cfg[1]}\t{cfg[2]}\t{cfg[3]}\t{cfg[4]}\t{mode}\t{string.format("%.3f", ms)}\t{string.format("%.1f", sent)}\t{mw}`)
	end
end
