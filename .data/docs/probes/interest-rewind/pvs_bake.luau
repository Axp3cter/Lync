--!strict
-- Build-time PVS bake cost on a synthetic map: what a Lune/mlua build step pays to precompute
-- cell-to-cell visibility from part boxes read out of the place file (place_read.luau shows Size and CFrame
-- of Parts are readable; MeshPart/Union geometry and Terrain voxels are not).
-- Model: 2D (XZ) occlusion at eye height; occluders are axis-aligned boxes (rotated parts would use their
-- XZ bounding box). A pair of cells is visible if any of S x S sample rays (S per axis per cell) is unblocked
-- (optimistic: Riot's "any part of a voxel sees any part of the other").
-- Rays walk a uniform occluder grid (DDA) and test only boxes registered in visited grid cells.
-- Run: luau -O2 --codegen pvs_bake.luau MAP CELL BOXES SAMPLES
local args = { ... }
local MAP = tonumber(args[1]) or 1024 -- studs per side
local CELL = tonumber(args[2]) or 32 -- PVS cell size, studs
local BOXES = tonumber(args[3]) or 1500
local S = tonumber(args[4]) or 1 -- samples per axis per cell (S*S points per cell)
local G = 16 -- occluder grid size, studs

local seed = 7
local function rnd(): number
	seed = (seed * 1103515245 + 12345) % 2147483648
	return seed / 2147483648
end

-- boxes: minX, minZ, maxX, maxZ
local bx0, bz0, bx1, bz1 = {}, {}, {}, {}
for i = 1, BOXES do
	local w, d = 4 + rnd() * 40, 1 + rnd() * 4
	if rnd() < 0.5 then w, d = d, w end
	local x, z = rnd() * MAP, rnd() * MAP
	bx0[i], bz0[i], bx1[i], bz1[i] = x, z, x + w, z + d
end

-- occluder grid
local GN = math.ceil(MAP / G)
local grid: { { number } } = table.create(GN * GN)
for i = 1, GN * GN do grid[i] = {} end
for i = 1, BOXES do
	for gx = math.max(0, bx0[i] // G), math.min(GN - 1, bx1[i] // G) do
		for gz = math.max(0, bz0[i] // G), math.min(GN - 1, bz1[i] // G) do
			table.insert(grid[gz * GN + gx + 1], i)
		end
	end
end

local stamp = table.create(BOXES, 0)
local ray = 0

-- slab test of segment (x0,z0)->(x1,z1) against box i
local function hits(i: number, x0: number, z0: number, dx: number, dz: number): boolean
	local tmin, tmax = 0, 1
	if dx ~= 0 then
		local a, b = (bx0[i] - x0) / dx, (bx1[i] - x0) / dx
		if a > b then a, b = b, a end
		tmin, tmax = math.max(tmin, a), math.min(tmax, b)
	elseif x0 < bx0[i] or x0 > bx1[i] then
		return false
	end
	if dz ~= 0 then
		local a, b = (bz0[i] - z0) / dz, (bz1[i] - z0) / dz
		if a > b then a, b = b, a end
		tmin, tmax = math.max(tmin, a), math.min(tmax, b)
	elseif z0 < bz0[i] or z0 > bz1[i] then
		return false
	end
	return tmin <= tmax
end

local function blocked(x0: number, z0: number, x1: number, z1: number): boolean
	ray += 1
	local dx, dz = x1 - x0, z1 - z0
	local len = math.sqrt(dx * dx + dz * dz)
	local steps = math.max(1, math.ceil(len / (G * 0.5)))
	local lastCell = -1
	for s = 0, steps do
		local t = s / steps
		local gx = math.clamp((x0 + dx * t) // G, 0, GN - 1)
		local gz = math.clamp((z0 + dz * t) // G, 0, GN - 1)
		local c = gz * GN + gx
		if c ~= lastCell then
			lastCell = c
			for _, i in grid[c + 1] do
				if stamp[i] ~= ray then
					stamp[i] = ray
					if hits(i, x0, z0, dx, dz) then return true end
				end
			end
		end
	end
	return false
end

local CN = MAP // CELL
local N = CN * CN
local bits = buffer.create(math.ceil(N * N / 8))
local function setbit(a: number, b: number)
	local k = a * N + b
	buffer.writeu8(bits, k // 8, bit32.bor(buffer.readu8(bits, k // 8), bit32.lshift(1, k % 8)))
end

local t0 = os.clock()
local visiblePairs = 0
for a = 0, N - 1 do
	local ax, az = (a % CN) * CELL, (a // CN) * CELL
	setbit(a, a)
	for b = a + 1, N - 1 do
		local bxp, bzp = (b % CN) * CELL, (b // CN) * CELL
		local vis = false
		for i = 0, S * S - 1 do
			if vis then break end
			local ox, oz = (i % S + 0.5) * CELL / S, (i // S + 0.5) * CELL / S
			for j = 0, S * S - 1 do
				local px, pz = (j % S + 0.5) * CELL / S, (j // S + 0.5) * CELL / S
				if not blocked(ax + ox, az + oz, bxp + px, bzp + pz) then
					vis = true
					break
				end
			end
		end
		if vis then
			setbit(a, b)
			setbit(b, a)
			visiblePairs += 1
		end
	end
end
local dt = os.clock() - t0
print(string.format(
	"map %d, cell %d (%d cells), boxes %d, samples %dx%d: %.2f s, %d rays (%.2f M rays/s), visible pairs %.1f%%, table %d B (%.1f KiB)",
	MAP, CELL, N, BOXES, S, S, dt, ray, ray / dt / 1e6, 100 * visiblePairs / (N * (N - 1) / 2), buffer.len(bits), buffer.len(bits) / 1024))
