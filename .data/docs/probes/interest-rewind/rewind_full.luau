--!strict
-- Rewind, extended (D2). Extends rewind_cost.luau with what the design in research/interest-rewind.md §11 needs:
--   1. a 24 B slot per record per state tick: tick u32, position x y z f32 (the decoded quantized values the row
--      carried), rotation as the t.rotation(9) code (u32), flags u8 (`:rewind()` booleans), 3 B pad;
--   2. perceived-tick resolution from the ack in the claim's frame (seq -> tick and send time ring, ping, delay);
--   3. a rewound sample at a fractional tick: position lerp + rotation decode (smallest-three, both codes) + nlerp;
--   4. "as received" mode: per (viewer, record) ring of the ticks of rows the viewer acked; the query brackets P
--      with the viewer's own samples, as the client's interpolation did;
--   5. an error simulation: truth-at-P (one sample per tick) against as-received when rows were lost or deferred;
--   6. memory for the docs' traffic models.
-- Run: luau -O2 rewind_full.luau  and  luau -O2 --codegen rewind_full.luau   (Luau 0.742)
local N = 1_000_000

local function bench(name: string, f: () -> number)
	local best = math.huge
	local sink = 0
	for _ = 1, 5 do
		local t = os.clock()
		sink += f()
		best = math.min(best, os.clock() - t)
	end
	print(string.format("%-58s %8.1f ns/op  (sink %d)", name, best * 1e9 / N, math.floor(sink) % 7))
end

-- 1. the ring -----------------------------------------------------------------------------------------------
local RECORDS, K, SLOT = 100, 24, 24
local ring = buffer.create(RECORDS * K * SLOT)

local function push(r: number, tick: number, x: number, y: number, z: number, rot: number, flags: number)
	local o = (r * K + tick % K) * SLOT
	buffer.writeu32(ring, o, tick)
	buffer.writef32(ring, o + 4, x)
	buffer.writef32(ring, o + 8, y)
	buffer.writef32(ring, o + 12, z)
	buffer.writeu32(ring, o + 16, rot)
	buffer.writeu8(ring, o + 20, flags)
end

-- smallest-three decode of a 9-bit code: flag 0, dropped index u2, three u9
local BITS = 9
local SCALE = 1 / ((2 ^ BITS - 1) * math.sqrt(2) / 2)
local MASK = 2 ^ BITS - 1
local function decodeRot(code: number): (number, number, number, number)
	local drop = bit32.extract(code, 1, 2)
	local a = bit32.extract(code, 3, BITS) * SCALE - 1 / math.sqrt(2)
	local b = bit32.extract(code, 3 + BITS, BITS) * SCALE - 1 / math.sqrt(2)
	local c = bit32.extract(code, 3 + 2 * BITS, BITS) * SCALE - 1 / math.sqrt(2)
	local d = math.sqrt(math.max(0, 1 - a * a - b * b - c * c))
	if drop == 0 then
		return d, a, b, c
	elseif drop == 1 then
		return a, d, b, c
	elseif drop == 2 then
		return a, b, d, c
	end
	return a, b, c, d
end

-- returns position x + quaternion w (a sink); NaN when either tick has left the ring
local function sampleAt(r: number, p: number): number
	local t0 = math.floor(p)
	local f = p - t0
	local o0 = (r * K + t0 % K) * SLOT
	local o1 = (r * K + (t0 + 1) % K) * SLOT
	if buffer.readu32(ring, o0) ~= t0 or buffer.readu32(ring, o1) ~= t0 + 1 then
		return 0 / 0
	end
	local x = buffer.readf32(ring, o0 + 4) + (buffer.readf32(ring, o1 + 4) - buffer.readf32(ring, o0 + 4)) * f
	local y = buffer.readf32(ring, o0 + 8) + (buffer.readf32(ring, o1 + 8) - buffer.readf32(ring, o0 + 8)) * f
	local z = buffer.readf32(ring, o0 + 12) + (buffer.readf32(ring, o1 + 12) - buffer.readf32(ring, o0 + 12)) * f
	local ax, ay, az, aw = decodeRot(buffer.readu32(ring, o0 + 16))
	local bx, by, bz, bw = decodeRot(buffer.readu32(ring, o1 + 16))
	if ax * bx + ay * by + az * bz + aw * bw < 0 then
		bx, by, bz, bw = -bx, -by, -bz, -bw
	end
	local qx, qy, qz, qw = ax + (bx - ax) * f, ay + (by - ay) * f, az + (bz - az) * f, aw + (bw - aw) * f
	local m = 1 / math.sqrt(qx * qx + qy * qy + qz * qz + qw * qw)
	return x + y * 0 + z * 0 + qw * m
end

local function randomRot(i: number): number
	-- a well-formed code: flag 0, drop 3, three components near the middle
	return bit32.bor(bit32.lshift(3, 1), bit32.lshift(200 + i % 100, 3), bit32.lshift(250, 3 + BITS),
		bit32.lshift(300 - i % 50, 3 + 2 * BITS))
end

bench("push: one record, one tick (24 B slot)", function()
	for i = 1, N do
		push(i % RECORDS, 64 + i % K, i, i, i, randomRot(i), 1)
	end
	return 1
end)

for t = 1000, 1000 + K - 1 do
	for r = 0, RECORDS - 1 do
		push(r, t, r + t, t, -t, randomRot(r + t), 1)
	end
end

bench("sample at fractional tick: lerp xyz + 2 rot decodes + nlerp", function()
	local acc = 0
	for i = 1, N do
		acc += sampleAt(i % RECORDS, 1000 + i % (K - 1) + 0.37)
	end
	return acc
end)

-- 2. perceived tick ------------------------------------------------------------------------------------------
-- per player: a ring of L state frames, each (tick u32, send time f64). The claim's frame acks seq s.
local L = 64
local frameTick = buffer.create(L * 4)
local frameSent = buffer.create(L * 8)
local RATE = 20
for s = 0, L - 1 do
	buffer.writeu32(frameTick, s * 4, 1000 + s)
	buffer.writef64(frameSent, s * 8, 100 + s / RATE)
end
local FLUSH = 1 / 60

-- returns P, low, high in fractional ticks
local function perceived(ackSeq: number, received: number, ping: number, delay: number, jitter: number)
	local o = ackSeq % L
	local tA = buffer.readu32(frameTick, o * 4)
	local sentA = buffer.readf64(frameSent, o * 8)
	local nextSent = buffer.readf64(frameSent, ((ackSeq + 1) % L) * 8) -- next state frame to this viewer
	local hmax = (nextSent - sentA) + FLUSH
	local held = math.clamp(received - sentA - ping, 0, hmax)
	local p = tA + (held - delay) * RATE
	local u = (jitter + FLUSH) * RATE
	local lo = math.max(p - u, tA - delay * RATE)
	local hi = math.min(p + u, tA + (hmax - delay) * RATE)
	return p, lo, hi
end

bench("perceived tick from ack (ring lookup, clamp, window)", function()
	local acc = 0
	for i = 1, N do
		local p, lo, hi = perceived(i % (L - 1), 100 + (i % (L - 1)) / RATE + 0.09, 0.06, 0.1, 0.01)
		acc += p + lo + hi
	end
	return acc
end)

-- 4. as received ------------------------------------------------------------------------------------------
-- per (viewer, record): M u32 ticks of rows the viewer acked (0 = empty), written round-robin
local VIEWERS, M = 100, 4
local recv = buffer.create(VIEWERS * RECORDS * M * 4)
local head = buffer.create(VIEWERS * RECORDS)

local function onAckedRow(v: number, r: number, tick: number)
	local pr = v * RECORDS + r
	local h = buffer.readu8(head, pr)
	buffer.writeu32(recv, (pr * M + h) * 4, tick + 1)
	buffer.writeu8(head, pr, (h + 1) % M)
end

-- bracket p with the viewer's own samples a <= p < b; returns the lerped sample (or the newest, held)
local function sampleAsReceived(v: number, r: number, p: number): number
	local base = (v * RECORDS + r) * M * 4
	local a, b = -1, math.huge
	for j = 0, M - 1 do
		local t = buffer.readu32(recv, base + j * 4) - 1
		if t >= 0 then
			if t <= p and t > a then
				a = t
			elseif t > p and t < b then
				b = t
			end
		end
	end
	if a < 0 then
		return 0 / 0
	end
	local oa = (r * K + a % K) * SLOT
	if b == math.huge then
		return buffer.readf32(ring, oa + 4)
	end
	local ob = (r * K + b % K) * SLOT
	local f = (p - a) / (b - a)
	local xa = buffer.readf32(ring, oa + 4)
	local ax, ay, az, aw = decodeRot(buffer.readu32(ring, oa + 16))
	local bx, by, bz, bw = decodeRot(buffer.readu32(ring, ob + 16))
	if ax * bx + ay * by + az * bz + aw * bw < 0 then
		bw = -bw
	end
	return xa + (buffer.readf32(ring, ob + 4) - xa) * f + aw + (bw - aw) * f
end

bench("as-received: record one acked row (per viewer, record)", function()
	for i = 1, N do
		onAckedRow(i % VIEWERS, (i * 7) % RECORDS, 1000 + i % K)
	end
	return 1
end)

for v = 0, VIEWERS - 1 do
	for r = 0, RECORDS - 1 do
		for t = 1000 + K - 8, 1000 + K - 1, 2 do -- every other tick received
			onAckedRow(v, r, t)
		end
	end
end
bench("as-received: bracket P with own samples + lerp + 2 decodes", function()
	local acc = 0
	for i = 1, N do
		acc += sampleAsReceived(i % VIEWERS, (i * 7) % RECORDS, 1000 + K - 5.5)
	end
	return acc
end)

-- 5. error simulation -----------------------------------------------------------------------------------------
-- A target strafes on x at 16 studs/s, reversing every 0.2-0.6 s. Server truth sampled each 20 Hz tick.
-- The viewer receives each tick's row with probability 1 - drop (loss or budget deferral). Its render tick P
-- is a uniform fraction behind the newest tick by D = 2 ticks. Error = |client display - truth-at-P lerp|.
local function simulate(drop: number, seed: number)
	math.randomseed(seed)
	local function uniform(lo: number, hi: number): number
		return lo + (hi - lo) * math.random()
	end
	local TICKS = 200_000
	local xs = table.create(TICKS + 1, 0)
	local x, v, untilFlip = 0, 16, 0.4
	for t = 0, TICKS do
		xs[t + 1] = x
		local dt = 1 / RATE
		untilFlip -= dt
		if untilFlip <= 0 then
			v = -v
			untilFlip = uniform(0.2, 0.6)
		end
		x += v * dt
	end
	local got = table.create(TICKS + 1, false)
	for t = 0, TICKS do
		got[t + 1] = math.random() >= drop
	end
	local errs = {}
	for _ = 1, 100_000 do
		local p = uniform(20, TICKS - 40)
		local t0 = math.floor(p)
		local truth = xs[t0 + 1] + (xs[t0 + 2] - xs[t0 + 1]) * (p - t0)
		local a = t0
		while not got[a + 1] and a > 0 do
			a -= 1
		end
		local b = t0 + 1
		while not got[b + 1] and b <= t0 + 2 do -- the client holds samples up to 2 ticks ahead of P (D = 2)
			b += 1
		end
		local shown
		if got[b + 1] then
			shown = xs[a + 1] + (xs[b + 1] - xs[a + 1]) * (p - a) / (b - a)
		else
			shown = xs[a + 1] -- no newer sample: held (extrapolation off)
		end
		table.insert(errs, math.abs(shown - truth))
	end
	table.sort(errs)
	local sum = 0
	for _, e in errs do
		sum += e
	end
	return sum / #errs, errs[math.floor(#errs * 0.99)], errs[#errs]
end

print("error of truth-at-P against the client's own samples, studs (16 studs/s strafe, 20 Hz, D = 2 ticks):")
for _, drop in { 0, 0.05, 0.33, 0.5 } do
	local mean, p99, max = simulate(drop, 7)
	print(string.format("  rows missing %4.0f%%: mean %.3f  p99 %.3f  max %.3f", drop * 100, mean, p99, max))
end

-- 6. memory -------------------------------------------------------------------------------------------------
print("memory (slot 24 B; ring K = ceil((maxRewind + 0.25 s) * rate) + 2; as-received M = 4 x u32 per pair):")
for _, m in { { "shooter 30", 30, 20 }, { "shooter 30", 30, 60 }, { "shooter 100", 100, 20 }, { "mmo 300 tracked, 100 viewers", 300, 20 } } do
	local name: string, records: number, rate: number = m[1] :: any, m[2] :: any, m[3] :: any
	local viewers = if records > 100 then 100 else records
	for _, maxRewind in { 0.5, 1.0 } do
		local k = math.ceil((maxRewind + 0.25) * rate) + 2
		local ringB = records * k * SLOT
		local seqB = viewers * k * 12
		local recvB = viewers * records * (M * 4 + 1)
		print(string.format("  %-30s %2d Hz maxRewind %.1f s: K=%3d ring %7d B (%5d B/record), seq map %6d B, as-received %8d B",
			name, rate, maxRewind, k, ringB, k * SLOT, seqB, recvB))
	end
end
