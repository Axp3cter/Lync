--!native
--!strict
-- (1) Rewind: per-entity ring of K snapshots (time, x, y, z) in a buffer; query = binary search + lerp.
-- (2) Constraint check: per-player leaky-bucket speed check + cooldown + monotonic counter, per message.
local K = 64 -- ~1.07 s at 60 Hz
local STRIDE = 32 -- f64 t, f64 x, f64 y, f64 z
local function makeRing(): buffer return buffer.create(K * STRIDE) end
local function push(ring: buffer, head: number, t: number, x: number, y: number, z: number): number
	local o = (head % K) * STRIDE
	buffer.writef64(ring, o, t); buffer.writef64(ring, o + 8, x)
	buffer.writef64(ring, o + 16, y); buffer.writef64(ring, o + 24, z)
	return head + 1
end
-- entries [head-K, head-1] are valid, times increasing
local function sample(ring: buffer, head: number, t: number): (number, number, number)
	local lo, hi = head - K, head - 1
	if t <= buffer.readf64(ring, (lo % K) * STRIDE) then
		local o = (lo % K) * STRIDE
		return buffer.readf64(ring, o + 8), buffer.readf64(ring, o + 16), buffer.readf64(ring, o + 24)
	end
	while hi - lo > 1 do
		local mid = (lo + hi) // 2
		if buffer.readf64(ring, (mid % K) * STRIDE) <= t then lo = mid else hi = mid end
	end
	local a, b = (lo % K) * STRIDE, (hi % K) * STRIDE
	local ta, tb = buffer.readf64(ring, a), buffer.readf64(ring, b)
	local f = if tb > ta then math.clamp((t - ta) / (tb - ta), 0, 1) else 0
	return buffer.readf64(ring, a + 8) + (buffer.readf64(ring, b + 8) - buffer.readf64(ring, a + 8)) * f,
		buffer.readf64(ring, a + 16) + (buffer.readf64(ring, b + 16) - buffer.readf64(ring, a + 16)) * f,
		buffer.readf64(ring, a + 24) + (buffer.readf64(ring, b + 24) - buffer.readf64(ring, a + 24)) * f
end
local ring = makeRing()
local head = 0
for i = 1, 200 do head = push(ring, head, i / 60, i, 0, i * 0.5) end
local N = 200000
local sink = 0
local t0 = os.clock()
for i = 1, N do
	local x, y, z = sample(ring, head, 2.4 + (i % 50) / 100)
	sink += x + z
end
local tRewind = (os.clock() - t0) / N
t0 = os.clock()
for i = 1, N do head = push(ring, head, 4 + i / 60, i, 0, i) end
local tPush = (os.clock() - t0) / N

-- constraint state per player: lastX, lastZ, lastT, bucket, lastFire, counter (6 f64 = 48 B)
local st = buffer.create(48)
local MAXSPEED, CAP, COOLDOWN = 32, 64, 0.1
local function check(px: number, pz: number, t: number, fired: boolean, counter: number): boolean
	local lx, lz, lt = buffer.readf64(st, 0), buffer.readf64(st, 8), buffer.readf64(st, 16)
	local dt = t - lt
	local dist = math.sqrt((px - lx) ^ 2 + (pz - lz) ^ 2)
	-- leaky bucket: excess distance accumulates, drains at MAXSPEED per second
	local bucket = math.max(0, buffer.readf64(st, 24) + dist - MAXSPEED * dt)
	local ok = bucket <= CAP
	if fired then
		ok = ok and (t - buffer.readf64(st, 32) >= COOLDOWN)
		buffer.writef64(st, 32, t)
	end
	ok = ok and counter > buffer.readf64(st, 40)
	buffer.writef64(st, 0, px); buffer.writef64(st, 8, pz); buffer.writef64(st, 16, t)
	buffer.writef64(st, 24, bucket); buffer.writef64(st, 40, counter)
	return ok
end
local okc = 0
t0 = os.clock()
for i = 1, N do if check(i * 0.4, 0, i / 60, i % 7 == 0, i) then okc += 1 end end
local tCheck = (os.clock() - t0) / N
print(string.format("rewind sample (64-entry ring, bsearch+lerp): %.0f ns; push: %.0f ns; constraint check: %.0f ns (ok %d/%d, sink %d)",
	tRewind * 1e9, tPush * 1e9, tCheck * 1e9, okc, N, sink // 1))
