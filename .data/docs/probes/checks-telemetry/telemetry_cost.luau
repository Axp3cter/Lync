--!strict
-- Per-message and per-atom cost of the `telemetry` sampler as designed in research/checks-telemetry.md (T1).
-- Every line runs over 100 players with state in buffers, slot found by a hash lookup on a player key, as the
-- server view would. Lines:
--   cadence write   : u16 arrival ms + u16 frame key into a 64-entry ring (4 B per entry)
--   aim write, code : the same plus two u16 already given (the cost floor, C6's "aim ring write" with time + key)
--   aim write, dir  : a decoded unit direction converted to yaw/pitch (atan2, asin), quantized to two u16, 8 B entry
--   atom trigger    : the trigger message's numeric fields (5 values) copied as f64 into a pending slot
--   atom complete   : the window found by binary search over the ring's arrival times (6 probes), then a two-part
--                     copy of the window (45 entries, 360 B at 60 Hz for 0.5 s + 0.25 s) into the batch buffer
--   batch hand-off  : a batch of 16 atoms copied into a fresh buffer of exact size plus a frozen batch table
-- Run: luau -O2 telemetry_cost.luau  and  luau -O2 --codegen telemetry_cost.luau   (Luau 0.742)
local PLAYERS = 100
local N = 2_000_000
local RUNS = 7
local RING = 64

local function bench(name: string, ops: number, f: () -> number)
	local best = math.huge
	local sink = 0
	for _ = 1, RUNS do
		local t = os.clock()
		sink += f()
		best = math.min(best, os.clock() - t)
	end
	print(string.format("%-58s %7.1f ns/op  (sink %d)", name, best * 1e9 / ops, sink % 7))
end

-- player keys: tables stand in for Player instances; slot = index into the state buffers
local keys: { {} } = {}
local slotOf: { [{}]: number } = {}
for p = 1, PLAYERS do
	local k = {}
	keys[p] = k
	slotOf[k] = p - 1
end

local heads = buffer.create(PLAYERS * 4) -- u8 head per ring (u32 for alignment), cadence and aim share layout
local cadence = buffer.create(PLAYERS * RING * 4)
local aim = buffer.create(PLAYERS * RING * 8)

-- baseline: loop, player key fetch, slot lookup
bench("baseline: loop + slot lookup", N, function()
	local s = 0
	for i = 1, N do
		local k = keys[i % PLAYERS + 1]
		s += slotOf[k]
	end
	return s
end)

bench("cadence write (u16 ms, u16 key)", N, function()
	for i = 1, N do
		local k = keys[i % PLAYERS + 1]
		local slot = slotOf[k]
		local h = buffer.readu8(heads, slot * 4)
		local o = (slot * RING + h) * 4
		buffer.writeu16(cadence, o, (i * 17) % 65536)
		buffer.writeu16(cadence, o + 2, i % 65536)
		buffer.writeu8(heads, slot * 4, (h + 1) % RING)
	end
	return 1
end)

bench("aim write, code given (u16 ms, u16 key, 2 x u16)", N, function()
	for i = 1, N do
		local k = keys[i % PLAYERS + 1]
		local slot = slotOf[k]
		local h = buffer.readu8(heads, slot * 4 + 1)
		local o = (slot * RING + h) * 8
		buffer.writeu16(aim, o, (i * 17) % 65536)
		buffer.writeu16(aim, o + 2, i % 65536)
		buffer.writeu16(aim, o + 4, (i * 7) % 65536)
		buffer.writeu16(aim, o + 6, (i * 13) % 65536)
		buffer.writeu8(heads, slot * 4 + 1, (h + 1) % RING)
	end
	return 1
end)

-- decoded directions (unit vectors), precomputed so the line measures the sampler, not the decoder
local DIRS = 1024
local dirs: { vector } = {}
for j = 1, DIRS do
	local a = j * 0.731
	local e = math.sin(j * 0.17) * 1.2
	dirs[j] = vector.create(math.cos(e) * math.sin(a), math.sin(e), math.cos(e) * math.cos(a))
end
local TAU = 2 * math.pi
local HALF = math.pi / 2

bench("aim write, direction -> yaw/pitch u16 (atan2, asin)", N, function()
	for i = 1, N do
		local k = keys[i % PLAYERS + 1]
		local slot = slotOf[k]
		local d = dirs[i % DIRS + 1]
		local yaw = math.atan2(-d.x, -d.z) -- Roblox look convention: -Z forward
		local pitch = math.asin(math.clamp(d.y, -1, 1))
		local qy = (math.floor((yaw + math.pi) * (65536 / TAU) + 0.5)) % 65536
		local qp = math.floor((pitch + HALF) * (65535 / math.pi) + 0.5)
		local h = buffer.readu8(heads, slot * 4 + 1)
		local o = (slot * RING + h) * 8
		buffer.writeu16(aim, o, (i * 17) % 65536)
		buffer.writeu16(aim, o + 2, i % 65536)
		buffer.writeu16(aim, o + 4, qy)
		buffer.writeu16(aim, o + 6, qp)
		buffer.writeu8(heads, slot * 4 + 1, (h + 1) % RING)
	end
	return 1
end)

-- atom trigger: 5 numeric fields (e.g. origin xyz, target id, a tick) into one of 8 pending slots per player
local PENDING = 8
local FIELDS = 5
local pend = buffer.create(PLAYERS * PENDING * (16 + FIELDS * 8))
local PSTRIDE = 16 + FIELDS * 8
type Msg = { origin: vector, target: number, tick: number }
local msgs: { Msg } = {}
for j = 1, DIRS do
	msgs[j] = { origin = vector.create(j, -j, j * 0.5), target = j * 1001, tick = j }
end
local NT = N // 4
bench("atom trigger (5 fields as f64, time, key, def)", NT, function()
	for i = 1, NT do
		local k = keys[i % PLAYERS + 1]
		local slot = slotOf[k]
		local m = msgs[i % DIRS + 1]
		local o = (slot * PENDING + (i // PLAYERS) % PENDING) * PSTRIDE
		buffer.writef64(pend, o, i * 1e-3) -- due time (os.clock + after)
		buffer.writeu32(pend, o + 8, i) -- trigger ms since join
		buffer.writeu16(pend, o + 12, i % 65536) -- frame key
		buffer.writeu16(pend, o + 14, 3) -- definition index
		local org = m.origin
		buffer.writef64(pend, o + 16, org.x)
		buffer.writef64(pend, o + 24, org.y)
		buffer.writef64(pend, o + 32, org.z)
		buffer.writef64(pend, o + 40, m.target)
		buffer.writef64(pend, o + 48, m.tick)
	end
	return 1
end)

-- fill aim rings with times 16-17 ms apart so the window holds a realistic count
for p = 0, PLAYERS - 1 do
	for e = 0, RING - 1 do
		buffer.writeu16(aim, (p * RING + e) * 8, (e * 1000 // 60) % 65536)
	end
	buffer.writeu8(heads, p * 4 + 1, 0)
end
local WINDOW_MS_BEFORE = 500
local WINDOW_MS_AFTER = 250
local OUT_ATOM = 16 + FIELDS * 8 + 1 + RING * 8
local batchBuf = buffer.create(16 * OUT_ATOM)
local NC = N // 10
local copied = 0
bench("atom complete (binary search + two-part copy, ~45 entries)", NC, function()
	local total = 0
	for i = 1, NC do
		local slot = i % PLAYERS
		local h = buffer.readu8(heads, slot * 4 + 1)
		local newest = (h - 1) % RING
		local base = slot * RING
		local tNewest = buffer.readu16(aim, (base + newest) * 8)
		local tFrom = (tNewest - WINDOW_MS_AFTER - WINDOW_MS_BEFORE) % 65536
		-- entries are in arrival order: find the oldest entry with time >= tFrom by binary search over ages
		-- (age 0 = newest); times compare as wrapped differences from the newest
		local span = (tNewest - tFrom) % 65536
		local lo, hi = 0, RING - 1 -- ages
		while lo < hi do
			local mid = (lo + hi + 1) // 2
			local t = buffer.readu16(aim, (base + (newest - mid) % RING) * 8)
			if (tNewest - t) % 65536 <= span then
				lo = mid
			else
				hi = mid - 1
			end
		end
		local count = lo + 1
		local start = (newest - lo) % RING
		local dst = (i % 16) * OUT_ATOM
		buffer.copy(batchBuf, dst, pend, (slot * PENDING) * PSTRIDE, PSTRIDE)
		buffer.writeu8(batchBuf, dst + PSTRIDE, count)
		local first = math.min(count, RING - start)
		buffer.copy(batchBuf, dst + PSTRIDE + 1, aim, (base + start) * 8, first * 8)
		if first < count then
			buffer.copy(batchBuf, dst + PSTRIDE + 1 + first * 8, aim, base * 8, (count - first) * 8)
		end
		total += count
	end
	copied = total // NC
	return total
end)
print(string.format("atom window entries copied (mean): %d", copied))

local NB = N // 100
bench("batch hand-off (16 atoms: exact buffer + frozen table)", NB, function()
	local s = 0
	for i = 1, NB do
		local size = 16 * (PSTRIDE + 1 + 45 * 8)
		local b = buffer.create(size)
		buffer.copy(b, 0, batchBuf, 0, size)
		local t = table.freeze({ player = keys[i % PLAYERS + 1], namespace = "arena", count = 16, data = b })
		s += t.count
	end
	return s
end)

print(string.format(
	"memory per player: cadence ring %d B per definition; aim ring %d B; pending %d B (%d slots); one atom %d B (45 entries)",
	RING * 4, RING * 8, PENDING * PSTRIDE, PENDING, PSTRIDE + 1 + 45 * 8))
