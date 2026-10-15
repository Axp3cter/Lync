--!strict
-- Rewind rings indexed by state tick (no search): the server pushes one sample per record per state tick,
-- and a query at the perceived tick T (from the client's newest ack) reads slots T and T+1 and lerps by the
-- fractional interpolation offset. Layout: one buffer per collection, K slots per record,
-- each slot = tick u32 + x,y,z f32 (16 B). Compare with anticheat-design's binary-search ring.
-- Run: luau -O2 rewind_cost.luau  and  luau -O2 --codegen rewind_cost.luau
local RECORDS, K = 100, 64
local SLOT = 16
local ring = buffer.create(RECORDS * K * SLOT)
local N = 2_000_000

local function bench(name: string, f: () -> number)
	local best = math.huge
	local sink = 0
	for _ = 1, 5 do
		local t = os.clock()
		sink += f()
		best = math.min(best, os.clock() - t)
	end
	print(string.format("%-40s %7.1f ns/op  (sink %d)", name, best * 1e9 / N, sink % 7))
end

local function push(r: number, tick: number, x: number, y: number, z: number)
	local o = (r * K + tick % K) * SLOT
	buffer.writeu32(ring, o, tick)
	buffer.writef32(ring, o + 4, x)
	buffer.writef32(ring, o + 8, y)
	buffer.writef32(ring, o + 12, z)
end

-- returns x only (y, z are the same work); nil-free: returns NaN when the tick has left the ring
local function sample(r: number, tick: number, frac: number): number
	local o0 = (r * K + tick % K) * SLOT
	local o1 = (r * K + (tick + 1) % K) * SLOT
	if buffer.readu32(ring, o0) ~= tick or buffer.readu32(ring, o1) ~= tick + 1 then
		return 0 / 0
	end
	local x0, x1 = buffer.readf32(ring, o0 + 4), buffer.readf32(ring, o1 + 4)
	local y0, y1 = buffer.readf32(ring, o0 + 8), buffer.readf32(ring, o1 + 8)
	local z0, z1 = buffer.readf32(ring, o0 + 12), buffer.readf32(ring, o1 + 12)
	return (x0 + (x1 - x0) * frac) + (y0 + (y1 - y0) * frac) * 0 + (z0 + (z1 - z0) * frac) * 0
end

for t = 0, K - 1 do
	for r = 0, RECORDS - 1 do
		push(r, t, r + t, t, -t)
	end
end

bench("push (one record, one tick)", function()
	for i = 1, N do
		push(i % RECORDS, 64 + i % K, i, i, i)
	end
	return 1
end)

-- refill with consistent ticks for sampling
for t = 1000, 1000 + K - 1 do
	for r = 0, RECORDS - 1 do
		push(r, t, r + t, t, -t)
	end
end
bench("sample at perceived tick (lerp xyz)", function()
	local acc = 0
	for i = 1, N do
		acc += sample(i % RECORDS, 1000 + i % (K - 1), 0.37)
	end
	return acc
end)
print(string.format("memory: %d B per record (K=%d), %d B for %d records", K * SLOT, K, buffer.len(ring), RECORDS))
