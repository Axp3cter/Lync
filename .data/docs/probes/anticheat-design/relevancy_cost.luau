--!native
--!strict
-- Cost of a per-viewer relevancy pass: N viewers x M entities, distance cull + PVS bit test + hysteresis.
-- PVS: cells of 32 studs on a 64x64 grid (4096 cells), one bitset row per cell (4096 bits = 128 u32 words).
local CELLS = 64
local NCELL = CELLS * CELLS
local WORDS = NCELL // 32
local pvs = buffer.create(NCELL * WORDS * 4) -- 2 MiB
local rng = Random and nil
local seed = 12345
local function rand(): number
	seed = (seed * 1103515245 + 12345) % 2147483648
	return seed / 2147483648
end
for i = 0, NCELL * WORDS - 1 do
	-- ~30% visible
	local w = 0
	for b = 0, 31 do
		if rand() < 0.3 then w = bit32.bor(w, bit32.lshift(1, b)) end
	end
	buffer.writeu32(pvs, i * 4, w)
end
local function cellOf(x: number, z: number): number
	local cx = math.clamp(x // 32, 0, CELLS - 1)
	local cz = math.clamp(z // 32, 0, CELLS - 1)
	return cz * CELLS + cx
end
local function visible(a: number, b: number): boolean
	local word = buffer.readu32(pvs, (a * WORDS + b // 32) * 4)
	return bit32.btest(word, bit32.lshift(1, b % 32))
end
local function run(N: number, M: number, reps: number): number
	local vx, vz, vc = table.create(N, 0), table.create(N, 0), table.create(N, 0)
	local ex, ez, ec = table.create(M, 0), table.create(M, 0), table.create(M, 0)
	for i = 1, N do vx[i] = rand() * 2048; vz[i] = rand() * 2048; vc[i] = cellOf(vx[i], vz[i]) end
	for j = 1, M do ex[j] = rand() * 2048; ez[j] = rand() * 2048; ec[j] = cellOf(ex[j], ez[j]) end
	local holdUntil = buffer.create(N * M * 4) -- hysteresis: relevant-until tick per pair (u32)
	local R2 = 512 * 512
	local count = 0
	local t0 = os.clock()
	for tick = 1, reps do
		for i = 1, N do
			local x, z, c = vx[i], vz[i], vc[i]
			local base = (i - 1) * M
			for j = 1, M do
				local dx, dz = ex[j] - x, ez[j] - z
				local rel = false
				if dx * dx + dz * dz <= R2 and visible(c, ec[j]) then
					rel = true
					buffer.writeu32(holdUntil, (base + j - 1) * 4, tick + 3)
				elseif buffer.readu32(holdUntil, (base + j - 1) * 4) >= tick then
					rel = true
				end
				if rel then count += 1 end
			end
		end
	end
	local dt = os.clock() - t0
	return dt / reps, count
end
for _, cfg in { { 30, 60 }, { 50, 100 }, { 100, 200 } } do
	local times = {}
	for r = 1, 5 do
		local per, _ = run(cfg[1], cfg[2], 20)
		table.insert(times, per)
	end
	table.sort(times)
	print(string.format("N=%3d viewers x M=%3d entities: median %.3f ms per pass (min %.3f, max %.3f), %.1f ns/pair",
		cfg[1], cfg[2], times[3] * 1e3, times[1] * 1e3, times[5] * 1e3, times[3] / (cfg[1] * cfg[2]) * 1e9))
end
