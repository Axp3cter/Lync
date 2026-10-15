--!strict
-- Server cost of U9 (`derive` as a check kind) and U10 (`reactsTo`), per message, state in buffers.
-- U9: a table-driven runner over a decoded payload, as `checks` (research/checks-telemetry.md C0) runs checks:
--   the game's fn (closed-form projectile) is timed alone, then Lync's part: quantize the server's result onto
--   the field's grid and compare with the decoded claim, in steps (Chebyshev) and in studs (Euclidean).
-- U10: per stimulus sent, a ring push (key, reliable frame number, send time); per response, a ring scan for
--   the key, the elapsed time and the two comparisons; collection stimuli via a per-(viewer, slot) u32 frame
--   number and a per-player ring of reliable frame send times; the per-player path bound (10 one-second
--   minimum buckets of ping samples).
-- Run: luau -O2 server_facts_cost.luau  and  luau -O2 --codegen server_facts_cost.luau   (Luau 0.742)

local N = 2_000_000
local RUNS = 7

local function bench(name: string, ops: number, f: () -> number)
	local best = math.huge
	local sink = 0
	for _ = 1, RUNS do
		local t = os.clock()
		sink += f()
		best = math.min(best, os.clock() - t)
	end
	print(string.format("%-62s %7.1f ns/op  (sink %d)", name, best * 1e9 / ops, sink % 7))
end

----------------------------------------------------------------------------------------------------
print("-- U9 derive")
local G = vector.create(0, -196.2, 0)
type Shot = { origin: vector, velocity: vector, flight: number, hit: vector, item: number }
local STEP = 1 / 32
local INV = 32

local function grid(v: vector): vector
	return vector.floor(v * INV + vector.create(0.5, 0.5, 0.5)) * STEP
end

local shots: { Shot } = {}
math.randomseed(7)
for i = 1, 1024 do
	local o = vector.create(math.random() * 200, 10, math.random() * 200)
	local v = vector.create(math.random() * 50, 60, math.random() * 50)
	local t = math.random() * 1.5
	local hit = grid(o + v * t + G * (0.5 * t * t))
	if i % 4 == 0 then hit += vector.create(0, 0.5, 0) end -- every 4th claim is 16 steps off
	shots[i] = { origin = o, velocity = v, flight = t, hit = hit, item = i % 5 }
end

local function fn(_player: any, s: Shot): vector
	local t = s.flight
	return s.origin + s.velocity * t + G * (0.5 * t * t)
end

bench("game fn alone (closed-form projectile)", N, function()
	local acc = 0
	for i = 1, N do
		acc += fn(nil, shots[bit32.band(i, 1023) + 1]).y
	end
	return acc > 0 and 1 or 0
end)

type Check = { path: string, fn: (any, Shot) -> vector, tolerance: number }
local checkSteps: Check = { path = "hit", fn = fn, tolerance = 1 }
local checkStuds: Check = { path = "hit", fn = fn, tolerance = 1.5 * STEP }
local checksNone: { Check }? = nil

bench("runner, definition with no checks (nil test)", N, function()
	local n = 0
	for i = 1, N do
		local s = shots[bit32.band(i, 1023) + 1]
		if checksNone ~= nil then n += 1 end
		if s.item == 99 then n += 1 end
	end
	return n
end)

bench("runner, derive vector, tolerance in steps (Chebyshev)", N, function()
	local failures = 0
	local c = checkSteps
	for i = 1, N do
		local s = shots[bit32.band(i, 1023) + 1]
		local r = c.fn(nil, s)
		-- Lync's part: both onto the integer grid, max per-component step difference
		local d = vector.abs(vector.floor(r * INV + vector.create(0.5, 0.5, 0.5)) - vector.floor(s.hit * INV + vector.create(0.5, 0.5, 0.5)))
		local steps = math.max(d.x, d.y, d.z)
		if not (steps <= c.tolerance) then failures += 1 end
	end
	return failures
end)

bench("runner, derive vector, tolerance in studs (grid, Euclidean)", N, function()
	local failures = 0
	local c = checkStuds
	for i = 1, N do
		local s = shots[bit32.band(i, 1023) + 1]
		local r = grid(c.fn(nil, s))
		local dist = vector.magnitude(r - s.hit)
		if not (dist <= c.tolerance) then failures += 1 end
	end
	return failures
end)

bench("runner, derive enum/int, exact (fn returns the item)", N, function()
	local failures = 0
	for i = 1, N do
		local s = shots[bit32.band(i, 1023) + 1]
		local r = (function(_p: any, x: Shot): number return x.item end)(nil, s)
		if r ~= s.item then failures += 1 end
	end
	return failures
end)

----------------------------------------------------------------------------------------------------
print("-- U10 reactsTo")
local PLAYERS = 100
local TRACK = 8
-- per (player, declaration) ring: key f64, frame f64, time f64 = 24 B per entry
local ring = buffer.create(PLAYERS * TRACK * 24)
local head = buffer.create(PLAYERS)

local function push(p: number, key: number, frame: number, t: number)
	local h = buffer.readu8(head, p)
	local o = (p * TRACK + h) * 24
	buffer.writef64(ring, o, key)
	buffer.writef64(ring, o + 8, frame)
	buffer.writef64(ring, o + 16, t)
	buffer.writeu8(head, p, (h + 1) % TRACK)
end

bench("stimulus sent: ring push (key, frame, time)", N, function()
	for i = 1, N do
		push(i % PLAYERS, i, i, i * 0.001)
	end
	return 0
end)

-- fill rings with keys 1..TRACK per player
for p = 0, PLAYERS - 1 do
	for k = 1, TRACK do push(p, k, 100 + k, 10 + k * 0.05) end
end

local bound = 0.1
local floor = 0.12
local factor = 0.5
bench("response: scan ring for key, elapsed, case 1 and floor tests", N, function()
	local facts = 0
	for i = 1, N do
		local p = i % PLAYERS
		local key = (i % TRACK) + 1
		local receipt = 104
		local now = 10.6
		local base = p * TRACK * 24
		local oldestReceived = -1.0
		local anySent = false
		for j = 0, TRACK - 1 do
			local o = base + j * 24
			if buffer.readf64(ring, o) == key then
				anySent = true
				if buffer.readf64(ring, o + 8) <= receipt then
					local t = buffer.readf64(ring, o + 16)
					if oldestReceived < 0 or t < oldestReceived then oldestReceived = t end
				end
			end
		end
		if anySent then
			if oldestReceived < 0 then
				facts += 1 -- case 1 by receipt
			else
				local elapsed = now - oldestReceived
				if elapsed < factor * bound then facts += 1
				elseif elapsed - bound < floor then facts += 1 end
			end
		end
	end
	return facts
end)

-- collection stimulus: per (viewer, slot) u32 frame number of the add; per player ring of frame send times
local SLOTS = 1024
local FRAMES = 128 -- ring of reliable frame send times per player (about 2 s at 60 Hz)
local addFrame = buffer.create(PLAYERS * SLOTS * 4)
local frameTime = buffer.create(PLAYERS * FRAMES * 8)
for p = 0, PLAYERS - 1 do
	for s = 0, SLOTS - 1 do buffer.writeu32(addFrame, (p * SLOTS + s) * 4, 1 + (s % 200)) end
	for f = 0, FRAMES - 1 do buffer.writef64(frameTime, (p * FRAMES + f) * 8, f / 60) end
end
bench("response to a collection add: slot frame, frame time, tests", N, function()
	local facts = 0
	for i = 1, N do
		local p = i % PLAYERS
		local slot = bit32.band(i * 7, SLOTS - 1)
		local frame = buffer.readu32(addFrame, (p * SLOTS + slot) * 4)
		local receipt = 150
		local newestSent = 200
		if frame == 0 then
			facts += 1 -- case 3: never sent to this viewer
		elseif frame > receipt then
			facts += 1 -- case 1 by receipt
		elseif newestSent - frame < FRAMES then
			local t = buffer.readf64(frameTime, (p * FRAMES + frame % FRAMES) * 8)
			local elapsed = 3.4 - t
			if elapsed < factor * bound or elapsed - bound < floor then facts += 1 end
		end
	end
	return facts
end)

-- per-player path bound: 10 one-second buckets holding the minimum ping sample of that second
local buckets = buffer.create(PLAYERS * 10 * 4)
bench("path bound: record one ping sample into its 1 s bucket", N, function()
	for i = 1, N do
		local p = i % PLAYERS
		local o = (p * 10 + (i // 1000) % 10) * 4
		local v = 0.08 + (i % 13) * 0.001
		if v < buffer.readf32(buckets, o) or buffer.readf32(buckets, o) == 0 then buffer.writef32(buckets, o, v) end
	end
	return 0
end)
bench("path bound: minimum over 10 buckets", N, function()
	local acc = 0
	for i = 1, N do
		local o = (i % PLAYERS) * 40
		local m = math.huge
		for b = 0, 9 do
			local v = buffer.readf32(buckets, o + b * 4)
			if v > 0 and v < m then m = v end
		end
		acc += m
	end
	return acc > 0 and 1 or 0
end)
print(string.format("memory: event ring %d B per (player, declaration); collection %d B per viewer per collection; frame times %d B per player; bound 40 B per player",
	TRACK * 24, SLOTS * 4, FRAMES * 8))
