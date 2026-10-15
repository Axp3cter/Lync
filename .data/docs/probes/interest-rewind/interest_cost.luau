--!strict
-- Per-viewer interest costs that state-sync's interest_cost.luau did not cover:
--   1. visibility classes per (viewer, record) pair: owner, team, threshold, firstSight
--   2. a PVS bitset test per pair
--   3. the relevancy fact counters (U13): relevant pair-ticks per collection, enters/leaves per viewer
-- Run: luau -O2 interest_cost.luau  and  luau -O2 --codegen interest_cost.luau
local VIEWERS, RECORDS, REL = 100, 1000, 160 -- REL: relevant records per viewer (cell membership)
local CELLS = 4096 -- 64 x 64 grid
local ITER = 200

local function bench(name: string, f: () -> number)
	local best = math.huge
	local sink = 0
	for _ = 1, 5 do
		local t = os.clock()
		for _ = 1, ITER do
			sink += f()
		end
		best = math.min(best, (os.clock() - t) / ITER)
	end
	print(string.format("%-34s %8.3f ms/pass  %6.1f ns/pair  (sink %d)", name, best * 1e3, best * 1e9 / (VIEWERS * REL), sink % 7))
end

-- data
local seed = 1
local rng = {}
function rng:NextInteger(lo: number, hi: number): number
	seed = (seed * 1103515245 + 12345) % 2147483648
	return lo + seed % (hi - lo + 1)
end
local recOwner = buffer.create(RECORDS * 2) -- u16 owner viewer index (0 = none)
local recTeam = buffer.create(RECORDS)
local recHp = buffer.create(RECORDS)
local recCell = buffer.create(RECORDS * 2)
for i = 0, RECORDS - 1 do
	buffer.writeu16(recOwner, i * 2, rng:NextInteger(0, VIEWERS))
	buffer.writeu8(recTeam, i, rng:NextInteger(0, 1))
	buffer.writeu8(recHp, i, rng:NextInteger(0, 100))
	buffer.writeu16(recCell, i * 2, rng:NextInteger(0, CELLS - 1))
end
local viewerTeam = buffer.create(VIEWERS)
local viewerCell = buffer.create(VIEWERS * 2)
for v = 0, VIEWERS - 1 do
	buffer.writeu8(viewerTeam, v, rng:NextInteger(0, 1))
	buffer.writeu16(viewerCell, v * 2, rng:NextInteger(0, CELLS - 1))
end
-- per-viewer relevant set (indices into records), as a flat u16 buffer
local rel = buffer.create(VIEWERS * REL * 2)
for v = 0, VIEWERS - 1 do
	for k = 0, REL - 1 do
		buffer.writeu16(rel, (v * REL + k) * 2, rng:NextInteger(0, RECORDS - 1))
	end
end
-- firstSight: one bit per (viewer, record)
local seen = buffer.create(VIEWERS * RECORDS // 8 + 1)
-- PVS: CELLS x CELLS bits = 2 MiB
local pvs = buffer.create(CELLS * CELLS // 8)
for i = 0, buffer.len(pvs) - 1, 4 do
	buffer.writeu32(pvs, i, rng:NextInteger(0, 0xFFFFFFFF))
end

local THRESH = 30

-- 1. visibility classes: computes a 4-bit field-class mask per pair
bench("classes owner/team/threshold/seen", function()
	local acc = 0
	for v = 0, VIEWERS - 1 do
		local team = buffer.readu8(viewerTeam, v)
		local base = v * REL
		for k = 0, REL - 1 do
			local r = buffer.readu16(rel, (base + k) * 2)
			local m = 0
			if buffer.readu16(recOwner, r * 2) == v + 1 then m += 1 end
			if buffer.readu8(recTeam, r) == team then m += 2 end
			if buffer.readu8(recHp, r) < THRESH then m += 4 end
			local bit = v * RECORDS + r
			local byte = bit // 8
			local b = buffer.readu8(seen, byte)
			local mask = bit32.lshift(1, bit % 8)
			if bit32.band(b, mask) ~= 0 then
				m += 8
			else
				buffer.writeu8(seen, byte, bit32.bor(b, mask))
			end
			acc += m
		end
	end
	return acc
end)

-- 2. PVS bitset test per pair
bench("pvs bit test", function()
	local acc = 0
	for v = 0, VIEWERS - 1 do
		local vc = buffer.readu16(viewerCell, v * 2)
		local row = vc * CELLS
		local base = v * REL
		for k = 0, REL - 1 do
			local r = buffer.readu16(rel, (base + k) * 2)
			local bit = row + buffer.readu16(recCell, r * 2)
			if bit32.band(buffer.readu8(pvs, bit // 8), bit32.lshift(1, bit % 8)) ~= 0 then
				acc += 1
			end
		end
	end
	return acc
end)

-- 3. relevancy fact counters: per collection pair-ticks += |relevant|, per viewer enters/leaves from the diff
local pairTicks = 0
local enters = buffer.create(VIEWERS * 4)
bench("relevancy counters (per viewer)", function()
	for v = 0, VIEWERS - 1 do
		pairTicks += REL -- one add per viewer: the relevant set size is known
		buffer.writeu32(enters, v * 4, buffer.readu32(enters, v * 4) + 3) -- diff size from the membership pass
	end
	return pairTicks
end)
print(string.format("pvs bitset bytes for %d cells: %d", CELLS, buffer.len(pvs)))
