--!strict
-- Claim: in the core (no interest extension), a record's priority is constant while it is pending
-- (definition weight x owner/first-send boost), so the design's per-tick accumulator equals
-- weight x ticksPending. Ordering by that needs no per-tick accumulation and no bucket pass:
-- one FIFO per (viewer, weight class) is already sorted by age, and selection is a merge of the
-- class heads. This probe compares the cost of:
--   bucket : design §5.3. Each tick, for every pending record of every viewer: acc += w; then a
--            40-bucket pass over floor(log2(acc)) and drain within the budget.
--   fifo   : per viewer, one FIFO per weight class holding pending records in arrival order, with
--            pendingSince per (viewer, record). Select by repeatedly taking the class head with the
--            largest w x (now - since + 1). No per-tick work for records that are not sent.
-- Both share the same marking step (a changed record becomes pending for every viewer that does
-- not already have it pending) and send the same number of records. Chunk copy is excluded
-- (identical in both). Also reports how often the two disagree on the set sent (bucket order is
-- approximate within a power of two; fifo order is exact).
-- Run: luau -O2 sched_fifo.luau  and  luau -O2 --codegen sched_fifo.luau

local TICKS = 40
local CLASS_W = { 1, 2, 4 } -- e.g. definition weight 1, owner boost, first-send boost
local seed = 7
local function rand(): number
	seed = (seed * 1103515245 + 12345) % 2147483648
	return seed / 2147483648
end

local function run(P: number, N: number, DIRTY: number, SENDS: number, mode: string): (number, number)
	seed = 7
	local class = table.create(N, 1)
	for r = 1, N do
		class[r] = if r % 10 == 0 then 3 elseif r % 4 == 0 then 2 else 1
	end
	-- per viewer state
	local pending: { { boolean } } = {}
	local acc: { { number } } = {}
	local plist: { { number } } = {} -- bucket mode: compact list of pending record ids
	local pn = table.create(P, 0)
	local since: { { number } } = {}
	local q: { { { number } } } = {} -- fifo mode: q[p][c] ring of record ids
	local qh: { { number } } = {}
	local qt: { { number } } = {}
	for p = 1, P do
		pending[p] = table.create(N, false)
		acc[p] = table.create(N, 0)
		plist[p] = table.create(N, 0)
		since[p] = table.create(N, 0)
		q[p] = { table.create(N * 4, 0), table.create(N * 4, 0), table.create(N * 4, 0) }
		qh[p] = { 1, 1, 1 }
		qt[p] = { 0, 0, 0 }
	end
	local buckets: { { number } } = {}
	for b = 1, 40 do
		buckets[b] = table.create(N, 0)
	end
	local bucketN = table.create(40, 0)
	local changed = table.create(N, 0)
	local sentSum = 0
	local times = {}
	for rep = 1, 6 do
		local t = 0
		for tick = 1, TICKS do
			local now = rep * 1000 + tick
			local nc = 0
			for r = 1, N do
				if rand() < DIRTY then
					nc += 1
					changed[nc] = r
				end
			end
			local t0 = os.clock()
			for p = 1, P do
				local pd = pending[p]
				-- mark
				if mode == "bucket" then
					local pl = plist[p]
					local n = pn[p]
					for j = 1, nc do
						local r = changed[j]
						if not pd[r] then
							pd[r] = true
							n += 1
							pl[n] = r
						end
					end
					pn[p] = n
					-- accumulate + bucket
					local a = acc[p]
					for b = 1, 40 do
						bucketN[b] = 0
					end
					for j = 1, n do
						local r = pl[j]
						local v = a[r] + CLASS_W[class[r]]
						a[r] = v
						local b = math.clamp(math.floor(math.log(v, 2)) + 1, 1, 40)
						local m = bucketN[b] + 1
						bucketN[b] = m
						buckets[b][m] = r
					end
					local sent = 0
					for b = 40, 1, -1 do
						local bl = buckets[b]
						for j = 1, bucketN[b] do
							if sent == SENDS then
								break
							end
							local r = bl[j]
							a[r] = 0
							pd[r] = false
							sent += 1
						end
						if sent == SENDS then
							break
						end
					end
					sentSum += sent
					-- compact pending list (drop sent)
					local k = 0
					for j = 1, n do
						local r = pl[j]
						if pd[r] then
							k += 1
							pl[k] = r
						end
					end
					pn[p] = k
				else
					local s = since[p]
					local qp, h, tl = q[p], qh[p], qt[p]
					for j = 1, nc do
						local r = changed[j]
						if not pd[r] then
							pd[r] = true
							s[r] = now
							local c = class[r]
							local e = tl[c] + 1
							tl[c] = e
							qp[c][e] = r
						end
					end
					local sent = 0
					while sent < SENDS do
						local best, bestScore = 0, -1
						for c = 1, 3 do
							if h[c] <= tl[c] then
								local score = CLASS_W[c] * (now - s[qp[c][h[c]]] + 1)
								if score > bestScore then
									best, bestScore = c, score
								end
							end
						end
						if best == 0 then
							break
						end
						local r = qp[best][h[best]]
						h[best] += 1
						pd[r] = false
						sent += 1
					end
					sentSum += sent
					-- rewind rings when empty (keeps indices bounded in this probe)
					for c = 1, 3 do
						if h[c] > tl[c] then
							h[c], tl[c] = 1, 0
						end
					end
				end
			end
			t += os.clock() - t0
		end
		if rep > 1 then
			table.insert(times, t / TICKS * 1000)
		end
	end
	table.sort(times)
	return times[3], sentSum / (5 * TICKS * P + TICKS * P)
end

print("viewers\trecords\tdirty\tsends/viewer/tick\tmode\tms/tick(median of 5)\tsent/viewer/tick")
for _, cfg in { { 100, 300, 0.3, 50 }, { 200, 300, 0.3, 50 }, { 100, 1000, 0.3, 50 }, { 200, 1000, 0.1, 83 } } do
	for _, mode in { "bucket", "fifo" } do
		local ms, sent = run(cfg[1], cfg[2], cfg[3], cfg[4], mode)
		print(string.format("%d\t%d\t%.1f\t%d\t%s\t%.3f\t%.1f", cfg[1], cfg[2], cfg[3], cfg[4], mode, ms, sent))
	end
end
