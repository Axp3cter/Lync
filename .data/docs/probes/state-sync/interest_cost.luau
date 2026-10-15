--!native
--!strict
-- Interest management cost per server tick: P players x E entities on a square map.
-- Variants:
--   brute : every (player, entity) pair, squared-distance test.
--   grid  : uniform grid (cell = enter radius), incremental cell moves, 3x3 query,
--           hysteresis (enter R, leave 1.1 R), enter/leave diff against the previous tick.
-- Each tick, MOVE_FRACTION of entities and all players move by up to STEP studs.
-- Output: median ms per tick (5 runs x TICKS ticks) and mean relevant set size.

local MAP = 4096
local STEP = 4 -- studs per tick (about 16 studs/s character speed at 60 Hz would be 0.27; this is pessimistic)
local MOVE_FRACTION = 0.3
local TICKS = 20

local seed = 1
local function rand(): number
	seed = (seed * 1103515245 + 12345) % 2147483648
	return seed / 2147483648
end

local function run(P: number, E: number, R: number, mode: string): (number, number)
	seed = 7
	local ex: { number } = table.create(E, 0)
	local ez: { number } = table.create(E, 0)
	for i = 1, E do
		ex[i] = rand() * MAP
		ez[i] = rand() * MAP
	end
	local px: { number } = table.create(P, 0)
	local pz: { number } = table.create(P, 0)
	for i = 1, P do
		px[i] = rand() * MAP
		pz[i] = rand() * MAP
	end
	local enter2 = R * R
	local leave2 = (R * 1.1) * (R * 1.1)
	local CELL = R
	local SIDE = math.ceil(MAP / CELL) + 2

	-- grid state: cells[key] = array of entity ids; slot[i] = index within its cell; cellOf[i] = key
	local cells: { [number]: { number } } = {}
	local cellOf: { number } = table.create(E, 0)
	local slot: { number } = table.create(E, 0)
	local function keyOf(x: number, z: number): number
		return (x // CELL + 1) + (z // CELL + 1) * SIDE
	end
	local function insert(i: number, k: number)
		local c = cells[k]
		if c == nil then
			c = {}
			cells[k] = c
		end
		local n = #c + 1
		c[n] = i
		slot[i] = n
		cellOf[i] = k
	end
	local function remove(i: number)
		local c = cells[cellOf[i]]
		local n = #c
		local s = slot[i]
		local last = c[n]
		c[s] = last
		slot[last] = s
		c[n] = nil
	end
	for i = 1, E do
		insert(i, keyOf(ex[i], ez[i]))
	end

	-- per-player relevant sets: seen[id] = stamp; list = ids
	local seen: { { [number]: number } } = table.create(P)
	local lists: { { number } } = table.create(P)
	for p = 1, P do
		seen[p] = {}
		lists[p] = {}
	end

	local times = {}
	local totalRelevant = 0
	local stamp = 0
	local enters, leaves = 0, 0
	for run = 1, 5 do
		local t0 = os.clock()
		for _ = 1, TICKS do
			stamp += 1
			-- movement (not timed separately; included, since a real server pays the cell update)
			local moves = math.floor(E * MOVE_FRACTION)
			for m = 1, moves do
				local i = (m * 7919 + stamp * 104729) % E + 1
				local x = math.clamp(ex[i] + (rand() - 0.5) * 2 * STEP, 0, MAP - 1)
				local z = math.clamp(ez[i] + (rand() - 0.5) * 2 * STEP, 0, MAP - 1)
				ex[i] = x
				ez[i] = z
				if mode == "grid" then
					local k = keyOf(x, z)
					if k ~= cellOf[i] then
						remove(i)
						insert(i, k)
					end
				end
			end
			for p = 1, P do
				px[p] = math.clamp(px[p] + (rand() - 0.5) * 2 * STEP, 0, MAP - 1)
				pz[p] = math.clamp(pz[p] + (rand() - 0.5) * 2 * STEP, 0, MAP - 1)
			end
			-- relevancy
			if mode == "brute" then
				for p = 1, P do
					local x, z = px[p], pz[p]
					local count = 0
					for i = 1, E do
						local dx = ex[i] - x
						local dz = ez[i] - z
						if dx * dx + dz * dz <= enter2 then
							count += 1
						end
					end
					totalRelevant += count
				end
			else
				for p = 1, P do
					local x, z = px[p], pz[p]
					local s = seen[p]
					local list = lists[p]
					local cx = x // CELL + 1
					local cz = z // CELL + 1
					local newList: { number } = {}
					local n = 0
					for oz = -1, 1 do
						for ox = -1, 1 do
							local c = cells[(cx + ox) + (cz + oz) * SIDE]
							if c then
								for j = 1, #c do
									local i = c[j]
									local dx = ex[i] - x
									local dz = ez[i] - z
									local d2 = dx * dx + dz * dz
									local was = s[i]
									if (was ~= nil and d2 <= leave2) or d2 <= enter2 then
										if was == nil then
											enters += 1
										end
										s[i] = stamp
										n += 1
										newList[n] = i
									end
								end
							end
						end
					end
					-- leaves: previously relevant ids not stamped this tick
					for j = 1, #list do
						local i = list[j]
						if s[i] ~= stamp then
							s[i] = nil
							leaves += 1
						end
					end
					lists[p] = newList
					totalRelevant += n
				end
			end
		end
		times[run] = (os.clock() - t0) / TICKS * 1000
	end
	table.sort(times)
	return times[3], totalRelevant / (5 * TICKS * P)
end

local radius = tonumber((...)) or 256
print(`R={radius} studs, map {MAP}x{MAP}, ticks of {TICKS}, median of 5`)
print("players\tentities\tmode\tms/tick\tavgRelevant")
for _, P in { 50, 100, 200 } do
	for _, E in { 1000, 5000, 10000 } do
		for _, mode in { "brute", "grid" } do
			local ms, rel = run(P, E, radius, mode)
			print(`{P}\t{E}\t{mode}\t{string.format("%.3f", ms)}\t{string.format("%.1f", rel)}`)
		end
	end
end
