--!strict
-- R35: `maxRate` as a checks kind. Part A: honest traffic on v5.md §9's network, largest bucket level reached,
-- against the derived default burst. Part B: per-message cost through a table-driven runner (as C6 measures the
-- other kinds), interpreted and native.
-- Two kernels, per player and check:
--   bucket (the research's leaky bucket on |dv| between consecutive messages): L' = max(0, L - rate*dt) + d(v, v*);
--          fails when L' > burst. Shown to drift on honest traffic: quantization makes each step look longer.
--   anchor (the form specified): anchor (a, t_a); fails when d(v, a) > rate*(t - t_a) + burst; on commit, when
--          t - t_a >= window and the frame is the newest so far, the anchor moves to (v, t).
-- d: Euclidean on vector3, or on (x, z) for plane "xz". t: server evaluation time (next 60 Hz step after arrival).
local RATE = 16 -- studs/s: Roblox's default WalkSpeed
local Q = 1 / 32 -- t.vector3 step
local QERR = math.sqrt(3) * Q / 2 -- max decode error per value, v5.md §3.3
local WINDOW = 10 -- s, anchor refresh
local function quant(x: number): number
	return math.floor(x / Q + 0.5) * Q
end

local function simulate(lane: string, msgs: number, seed: number, jitter: number, stalls: boolean): (number, number, number)
	math.randomseed(seed)
	-- client: 60 Hz frames, moves at exactly RATE in a direction that turns randomly, fires its position each frame
	local x, z, dir = 0, 0, 0
	local sends: { { t: number, k: number, x: number, z: number } } = {}
	local stallUntil = -1
	for i = 1, msgs do
		local t = i / 60
		dir += (math.random() - 0.5) * 0.6
		x += math.cos(dir) * RATE / 60
		z += math.sin(dir) * RATE / 60
		local arrive: number
		if lane == "unreliable" then
			if math.random() < 0.05 then
				continue -- lost
			end
			arrive = t + 0.05 + math.random() * jitter
		else
			-- reliable: delivered in order; a stall (p99 0.85 s in the §4.9 model) holds frames, then releases them
			if stalls and t > stallUntil and math.random() < 1 / 600 then
				stallUntil = t + 0.85
			end
			local base = t + 0.05 + math.random() * jitter
			arrive = if t <= stallUntil then stallUntil + 0.05 else base
		end
		-- server evaluates at its next 60 Hz step
		table.insert(sends, { t = arrive, k = i, x = quant(x), z = quant(z) })
	end
	table.sort(sends, function(a, b) return a.t < b.t end)
	if lane == "reliable" then
		-- ordered lane: arrival order is send order (a later send can't overtake)
		local last = -math.huge
		for _, m in sends do
			if m.t < last then m.t = last end
			last = m.t
		end
		table.sort(sends, function(a, b) return a.k < b.k end)
	end
	for _, m in sends do m.t = math.ceil(m.t * 60) / 60 end -- evaluated at the next server step
	-- bucket kernel
	local has, vx, vz, sk, L, ts = false, 0, 0, 0, 0, 0
	local maxL, late = 0, 0
	for _, m in sends do
		if not has then
			has, vx, vz, sk, ts = true, m.x, m.z, m.k, m.t
		elseif m.k >= sk then
			local d = math.sqrt((m.x - vx) ^ 2 + (m.z - vz) ^ 2)
			local l2 = math.max(0, L - RATE * (m.t - ts)) + d
			if l2 > maxL then maxL = l2 end
			vx, vz, sk, ts, L = m.x, m.z, m.k, m.t, l2
		else
			late += 1
		end
	end
	-- anchor kernel: largest d - rate*(t - t_a), i.e. the smallest burst with no failure
	local ah, ax, az, at, newest = false, 0, 0, 0, 0
	local need = 0
	for _, m in sends do
		if not ah then
			ah, ax, az, at, newest = true, m.x, m.z, m.t, m.k
		else
			local d = math.sqrt((m.x - ax) ^ 2 + (m.z - az) ^ 2)
			local e = d - RATE * (m.t - at)
			if e > need then need = e end
			if m.k > newest then
				newest = m.k
				if m.t - at >= WINDOW then ax, az, at = m.x, m.z, m.t end
			end
		end
	end
	return maxL, need, late
end

print("-- A. honest traffic at exactly rate 16 studs/s, t.vector3 step 1/32, 60 Hz, 3 x 10^6 messages per line, window 10 s")
local function derived(jitter: number, slack: number): number
	return RATE * (jitter + 1 / 60 + slack) + 2 * QERR
end
for _, c in { { "unreliable", 0.02, false, 0 }, { "unreliable", 0.05, false, 0 }, { "reliable", 0.02, false, 0 }, { "reliable", 0.02, true, 0.85 } } do
	local lane, jitter, stalls, slack = c[1] :: string, c[2] :: number, c[3] :: boolean, c[4] :: number
	local worst, worstNeed, lates = 0, 0, 0
	for seed = 1, 3 do
		local a, b, n = simulate(lane, 1_000_000, seed, jitter, stalls)
		worst = math.max(worst, a); worstNeed = math.max(worstNeed, b); lates += n
	end
	print(string.format("%-10s jitter %.2f s stalls %-5s: bucket max level %.3f studs | anchor: burst needed %.3f, derived %.3f | %d late frames",
		lane, jitter, tostring(stalls), worst, worstNeed, derived(jitter, slack), lates))
end

print("-- B. cost per message, table-driven runner (best of 7, ns)")
local PLAYERS, N, RUNS = 100, 2_000_000, 7
type Payload = { pos: vector }
local POOL = 64
local payloads: { Payload } = {}
for k = 1, POOL do
	payloads[k] = { pos = vector.create(k * 0.25, 0.5, -k * 0.25) }
end
type Check = { key: string, rate: number, burst: number, window: number, planar: boolean, slot: number }
local STRIDE = 6 -- has, ax, ay, az, t_a, newest key
local state = buffer.create(PLAYERS * 4 * STRIDE * 8)
local failures = 0
local function evaluate(c: Check, player: number, payload: any, s: number, now: number): (boolean, boolean)
	local v: vector = payload[c.key]
	local o = ((player - 1) * 4 + c.slot) * STRIDE * 8
	if buffer.readf64(state, o) == 0 then
		return true, true
	end
	local dx = v.x - buffer.readf64(state, o + 8)
	local dz = v.z - buffer.readf64(state, o + 24)
	local d2 = dx * dx + dz * dz
	if not c.planar then
		local dy = v.y - buffer.readf64(state, o + 16)
		d2 += dy * dy
	end
	local allow = c.rate * (now - buffer.readf64(state, o + 32)) + c.burst
	return d2 <= allow * allow, s > buffer.readf64(state, o + 40) and now - buffer.readf64(state, o + 32) >= c.window
end
local function commit(c: Check, player: number, payload: any, s: number, now: number)
	local v: vector = payload[c.key]
	local o = ((player - 1) * 4 + c.slot) * STRIDE * 8
	if buffer.readf64(state, o) == 0 then
		buffer.writef64(state, o, 1)
	end
	buffer.writef64(state, o + 8, v.x); buffer.writef64(state, o + 16, v.y); buffer.writef64(state, o + 24, v.z)
	buffer.writef64(state, o + 32, now); buffer.writef64(state, o + 40, s)
end
local function runChecks(checks: { Check }?, player: number, payload: any, s: number, now: number): number
	if checks == nil then return 1 end
	local drop = false
	for i = 1, #checks do
		local ok, store = evaluate(checks[i], player, payload, s, now)
		if not ok then failures += 1; drop = true end
		if store and not drop then commit(checks[i], player, payload, s, now) end
	end
	return if drop then 0 else 1
end
local clock = 0
local function bench(name: string, checks: { Check }?)
	local best, sink = math.huge, 0
	for _ = 1, RUNS do
		buffer.fill(state, 0, 0)
		local t0 = os.clock()
		local now = clock
		for i = 1, N do
			now += 0.0005
			sink += runChecks(checks, i % PLAYERS + 1, payloads[i % POOL + 1], i, now)
		end
		clock = now
		best = math.min(best, os.clock() - t0)
	end
	print(string.format("%-52s %7.1f ns/op (sink %d)", name, best * 1e9 / N, sink % 7))
end
bench("runner, no checks (nil test)", nil)
bench("runner, maxRate (anchor) vector3, 3-D", { { key = "pos", rate = 1e9, burst = 1e9, window = 0.01, planar = false, slot = 0 } })
bench("runner, maxRate (anchor) vector3, plane xz", { { key = "pos", rate = 1e9, burst = 1e9, window = 0.01, planar = true, slot = 0 } })
print(string.format("failures: %d (expected 0); state %d B per player per check", failures, STRIDE * 8))
