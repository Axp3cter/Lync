--!strict
-- Per-message cost of the `checks` constraints and of telemetry ring writes, per player state in buffers.
-- Part A: raw kernels (state in buffers, no dispatch).
--   within(ref, maxDist): distance of a client Vector3 claim to a server-known position (squared compare)
--   monotonic(): integer strictly greater than the last accepted value
--   maxTotal(cap, window): sliding sum over `window` seconds kept as B time buckets (ring), O(1) amortised
--   aim ring: one u16 pitch + u16 yaw sample per tick into a per-player ring
--   atom: copy `before + after` seconds of the aim ring (VACnet 0.5 s + 0.25 s at 60 Hz = 45 samples, 180 B)
-- Part B: the checks as designed in research/checks-telemetry.md, through a table-driven runner over a decoded
--   payload table, as server-view declarations would run (no generated code: checks are declared at run time).
-- Fix (2026-10-15): the atom line ran N/10 copies but divided by N, printing a tenth of the real cost. `bench`
-- now takes the operation count it divides by.
-- Run: luau -O2 checks_cost.luau  and  luau -O2 --codegen checks_cost.luau   (Luau 0.742)
local PLAYERS = 100
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
	print(string.format("%-58s %7.1f ns/op  (sink %d)", name, best * 1e9 / ops, sink % 7))
end

print("-- A. raw kernels")

-- server-known positions (e.g. the rewound shooter), f32 xyz per player
local pos = buffer.create(PLAYERS * 12)
for p = 0, PLAYERS - 1 do
	buffer.writef32(pos, p * 12, p)
	buffer.writef32(pos, p * 12 + 4, 0)
	buffer.writef32(pos, p * 12 + 8, -p)
end
bench("within (distance^2 <= max^2)", N, function()
	local ok = 0
	local max2 = 4 * 4
	for i = 1, N do
		local p = i % PLAYERS
		local o = p * 12
		local dx = (p + 1.5) - buffer.readf32(pos, o)
		local dy = 0.5 - buffer.readf32(pos, o + 4)
		local dz = (-p + 2) - buffer.readf32(pos, o + 8)
		if dx * dx + dy * dy + dz * dz <= max2 then
			ok += 1
		end
	end
	return ok
end)

local last = buffer.create(PLAYERS * 8)
bench("monotonic (f64 last, strict >)", N, function()
	local ok = 0
	for i = 1, N do
		local o = (i % PLAYERS) * 8
		local v = i
		if v > buffer.readf64(last, o) then
			buffer.writef64(last, o, v)
			ok += 1
		end
	end
	return ok
end)

-- maxTotal: B buckets per player, each f64 sum, plus head index and head time
local B, WINDOW, CAP = 16, 60, 1e9
local BW = WINDOW / B
local sums = buffer.create(PLAYERS * B * 8)
local total = buffer.create(PLAYERS * 8)
local headT = buffer.create(PLAYERS * 8)
bench("maxTotal (16-bucket sliding sum)", N, function()
	local ok = 0
	local now = 0
	for i = 1, N do
		now += 0.0005
		local p = i % PLAYERS
		local slotNow = now // BW
		local h = buffer.readf64(headT, p * 8)
		local t = buffer.readf64(total, p * 8)
		if slotNow > h then
			-- expire buckets passed over (at most B)
			local n = math.min(B, slotNow - h)
			for s = 1, n do
				local o = (p * B + (h + s) % B) * 8
				t -= buffer.readf64(sums, o)
				buffer.writef64(sums, o, 0)
			end
			buffer.writef64(headT, p * 8, slotNow)
		end
		local amount = 3
		if t + amount <= CAP then
			local o = (p * B + slotNow % B) * 8
			buffer.writef64(sums, o, buffer.readf64(sums, o) + amount)
			t += amount
			ok += 1
		end
		buffer.writef64(total, p * 8, t)
	end
	return ok
end)

local AIM = 64 -- ring samples per player (about 1 s at 60 Hz)
local aim = buffer.create(PLAYERS * AIM * 4)
bench("aim ring write (u16 pitch, u16 yaw)", N, function()
	for i = 1, N do
		local p = i % PLAYERS
		local o = (p * AIM + (i // PLAYERS) % AIM) * 4
		buffer.writeu16(aim, o, i % 65536)
		buffer.writeu16(aim, o + 2, (i * 7) % 65536)
	end
	return 1
end)

local atom = buffer.create(45 * 4)
local NA = N // 10
bench("atom copy (45 samples, 180 B, two-part ring copy)", NA, function()
	for i = 1, NA do
		local p = i % PLAYERS
		local start = (i * 3) % AIM
		local first = math.min(45, AIM - start)
		buffer.copy(atom, 0, aim, (p * AIM + start) * 4, first * 4)
		if first < 45 then
			buffer.copy(atom, first * 4, aim, p * AIM * 4, (45 - first) * 4)
		end
	end
	return 1
end)
print(string.format("memory: aim ring %d B per player; maxTotal %d B per player per constraint", AIM * 4, B * 8 + 16))

------------------------------------------------------------------------------------------------------------------
print("-- B. checks as designed, table-driven runner over decoded payloads")

-- Decoded payloads as the decoder would hand them to step 5 (one table per message). A pool of 64 is reused so
-- the loop measures the checks, not allocation.
type Payload = { origin: vector, seq: number, amount: number, range: number }
local POOL = 64
local payloads: { Payload } = {}
for k = 1, POOL do
	payloads[k] = {
		origin = vector.create(k * 0.25, 0.5, -k * 0.25),
		seq = k,
		amount = 3,
		range = 10 + k % 5,
	}
end

-- Server-known references: one vector per player, read by a game-supplied reference function.
local roots: { vector } = table.create(PLAYERS)
for p = 1, PLAYERS do
	roots[p] = vector.create(0, 0, 0)
end
local function originOf(player: number, _payload: Payload): vector
	return roots[player]
end
local function serverRange(_player: number, _payload: Payload): number
	return 12
end

-- Check kinds: 1 within (vector), 2 within (number), 3 monotonic, 4 maxTotal (16-bucket), 5 maxTotal (token bucket)
type Check = {
	kind: number,
	key: string,
	reference: ((number, Payload) -> any)?,
	bound: number, -- maxDistance, or cap
	seconds: number,
	strict: boolean,
	policy: number, -- 1 drop, 2 clamp, 3 deliver
	slot: number, -- state slot index of this check (per player)
}

-- Per-player state: each check owns STRIDE f64 words per player.
local STRIDE = 2 + B + 2 -- enough for the largest kind (maxTotal: head, total, B buckets)
local CHECKS_PER_PLAYER = 8
local state = buffer.create(PLAYERS * CHECKS_PER_PLAYER * STRIDE * 8)
local function base(player: number, slot: number): number
	return ((player - 1) * CHECKS_PER_PLAYER + slot) * STRIDE * 8
end

local failures = 0

-- Evaluate one check without committing. Returns ok, and for a pass, the value to commit (or nil).
-- seq is the extended upstream seq of the message's frame (reliable: a running count), now is os.clock().
local function evaluate(c: Check, player: number, payload: any, seq: number, now: number): (boolean, number?)
	local kind = c.kind
	if kind == 1 then
		local v: vector = payload[c.key]
		local r: vector = (c.reference :: any)(player, payload)
		local d = vector.magnitude(v - r)
		return d <= c.bound, nil
	elseif kind == 2 then
		local v: number = payload[c.key]
		local r: number = (c.reference :: any)(player, payload)
		return math.abs(v - r) <= c.bound, nil
	elseif kind == 3 then
		local v: number = payload[c.key]
		local o = base(player, c.slot)
		local seen = buffer.readf64(state, o) -- 0 none yet, else lastSeq + 1
		if seen == 0 then
			return true, v
		end
		local lastSeq = seen - 1
		local lastV = buffer.readf64(state, o + 8)
		if seq >= lastSeq then
			if c.strict then
				return v > lastV, v
			end
			return v >= lastV, v
		end
		-- late frame (unreliable reorder): sent before the value we hold, so it must not exceed it
		if c.strict then
			return v < lastV, nil
		end
		return v <= lastV, nil
	elseif kind == 4 then
		local amount: number = payload[c.key]
		local o = base(player, c.slot)
		local bw = c.seconds / B
		local slotNow = now // bw
		local h = buffer.readf64(state, o)
		local t = buffer.readf64(state, o + 8)
		if slotNow > h then
			local n = math.min(B, slotNow - h)
			for s = 1, n do
				local bo = o + 16 + ((h + s) % B) * 8
				t -= buffer.readf64(state, bo)
				buffer.writef64(state, bo, 0)
			end
			buffer.writef64(state, o, slotNow)
			buffer.writef64(state, o + 8, t)
		end
		return t + amount <= c.bound, amount
	else
		local amount: number = payload[c.key]
		local o = base(player, c.slot)
		local tokens = buffer.readf64(state, o)
		local at = buffer.readf64(state, o + 8)
		tokens = math.min(c.bound, tokens + (now - at) * c.bound / c.seconds)
		buffer.writef64(state, o, tokens)
		buffer.writef64(state, o + 8, now)
		return amount <= tokens, amount
	end
end

local function commit(c: Check, player: number, value: number, seq: number, now: number)
	local kind = c.kind
	local o = base(player, c.slot)
	if kind == 3 then
		buffer.writef64(state, o, seq + 1)
		buffer.writef64(state, o + 8, value)
	elseif kind == 4 then
		local bw = c.seconds / B
		local bo = o + 16 + ((now // bw) % B) * 8
		buffer.writef64(state, bo, buffer.readf64(state, bo) + value)
		buffer.writef64(state, o + 8, buffer.readf64(state, o + 8) + value)
	elseif kind == 5 then
		buffer.writef64(state, o, buffer.readf64(state, o) - value)
	end
end

-- Runs a definition's checks on one message: evaluate all, then (if the message is delivered) commit all.
-- Returns 1 delivered, 0 dropped. A failing check calls `fail` (the fact record is costed separately: 20.5 ns
-- native per occurrence, research/diagnostics.md §9).
local pendingValues: { number? } = table.create(CHECKS_PER_PLAYER)
local function runChecks(checks: { Check }?, player: number, payload: any, seq: number, now: number): number
	if checks == nil then
		return 1
	end
	local drop = false
	for i = 1, #checks do
		local c = checks[i]
		local ok, value = evaluate(c, player, payload, seq, now)
		pendingValues[i] = value
		if not ok then
			failures += 1
			if c.policy == 1 then
				drop = true
			end
		end
	end
	if drop then
		return 0
	end
	-- validate would run here; commit only for delivered messages
	for i = 1, #checks do
		local v = pendingValues[i]
		if v ~= nil then
			commit(checks[i], player, v, seq, now)
		end
	end
	return 1
end

local function mk(kind: number, key: string, reference: ((number, Payload) -> any)?, bound: number, slot: number): Check
	return {
		kind = kind,
		key = key,
		reference = reference,
		bound = bound,
		seconds = 60,
		strict = false,
		policy = 1,
		slot = slot,
	}
end

local function runCase(name: string, checks: { Check }?)
	buffer.fill(state, 0, 0)
	bench(name, N, function()
		local ok = 0
		local now = 0
		for i = 1, N do
			now += 0.0005
			local player = i % PLAYERS + 1
			local payload = payloads[i % POOL + 1]
			payload.seq = i -- increasing per player
			ok += runChecks(checks, player, payload, i, now)
		end
		return ok
	end)
end

runCase("runner, definition with no checks (nil test)", nil)
runCase("runner, within vector (reference fn, magnitude)", { mk(1, "origin", originOf, 64, 0) })
runCase("runner, within number (reference fn)", { mk(2, "range", serverRange, 5, 0) })
runCase("runner, monotonic nondecreasing, seq-aware", { mk(3, "seq", nil, 0, 0) })
runCase("runner, maxTotal 16-bucket sliding", { mk(4, "amount", nil, 1e12, 0) })
runCase("runner, maxTotal token bucket", { mk(5, "amount", nil, 1e12, 0) })
runCase("runner, within vector + monotonic + maxTotal (3 checks)", {
	mk(1, "origin", originOf, 64, 0),
	mk(3, "seq", nil, 0, 1),
	mk(4, "amount", nil, 1e12, 2),
})

-- Failure path: every message fails a drop check (fact record not included).
runCase("runner, within vector failing every message (drop)", { mk(1, "origin", originOf, 0.01, 0) })

-- Clamp for a failing within (vector): r + (v - r) * max / |v - r|
bench("clamp vector to sphere (on failure, policy clamp)", N, function()
	local acc = 0
	for i = 1, N do
		local v = payloads[i % POOL + 1].origin
		local r = roots[i % PLAYERS + 1]
		local d = v - r
		local m = vector.magnitude(d)
		local c = r + d * (0.5 / m)
		acc += c.x
	end
	return acc
end)

print(string.format("state: within 0 B; monotonic 16 B; maxTotal 16-bucket %d B; token bucket 16 B (per player per check)", (B + 2) * 8))
print(string.format("failures counted: %d", failures))
