--!strict
-- Claim: the per-message and per-frame work draft 2 adds to the server inbound path and the client
-- send path is small next to decode and dispatch. Measures, per item, in isolation:
--   server, per message (after decode):
--     d1      : draft-1 baseline: definition lookup, direction/lane check, rate token bucket
--     d2      : d1 + permutation map, trap flag, reachability set lookup, limit bucket with slack
--     refers  : decoy check for one `refers` key field (player's decoy-key set lookup)
--     canaryS : canary lookup for one inbound string value (player's canary set)
--     canaryB : canary lookup for one inbound 64 B buffer value (buffer.tostring then lookup)
--     canaryBL: as canaryB, with a length test first (canary values are min(16, maxBytes) long)
--   server, per frame:
--     replay  : 12-bit sequence extension + 64-frame RFC 4303 bitmap update (two u32 words)
--   client, per fire:
--     rngProbe: probability-share sampling with math.random per fire
--     cntProbe: the same rate with a geometric countdown (one draw per probe, not per fire)
--     failPcall: pcall of a function that errors (CLI stand-in for the identity probe's failing read;
--                Roblox's capability error path is not reproducible here)
--   server, once per namespace:
--     permBuild: Fisher-Yates with xorshift32 over N ids, per id
-- Run: luau -O2 [--codegen] inbound_hotpath.luau

local N = 200000
local function bench(name: string, f: () -> ())
	local times = {}
	for _ = 1, 7 do
		local t0 = os.clock()
		f()
		table.insert(times, (os.clock() - t0) / N * 1e9)
	end
	table.sort(times)
	print(string.format("%-10s median %7.1f ns  (min %7.1f, max %7.1f)", name, times[4], times[1], times[7]))
end

type Def = { dir: number, lane: number, rate: number, burst: number, tokens: number, last: number, trap: boolean, reach: boolean }
local defs: { Def } = {}
for i = 1, 64 do
	defs[i] = { dir = 1, lane = i % 2, rate = 10, burst = 20, tokens = 20, last = 0, trap = false, reach = true }
end
local perm = table.create(64, 0)
for i = 1, 64 do
	perm[i] = (i * 37) % 64 + 1
end
local reachable: { [number]: boolean } = {}
for i = 1, 64 do
	reachable[i] = true
end
local sink = 0

local function bucket(d: Def, now: number, slack: number): boolean
	local t = math.min(d.burst + d.rate * slack, d.tokens + (now - d.last) * d.rate)
	d.last = now
	if t < 1 then
		d.tokens = t
		return false
	end
	d.tokens = t - 1
	return true
end

bench("d1", function()
	local now = 0
	for i = 1, N do
		now += 0.001
		local d = defs[i % 64 + 1]
		if d.dir == 1 and d.lane == (i % 64 + 1) % 2 and bucket(d, now, 0) then
			sink += 1
		end
	end
end)

bench("d2", function()
	local now = 0
	for i = 1, N do
		now += 0.001
		local id = perm[i % 64 + 1]
		local d = defs[id]
		if d.dir == 1 and d.lane == id % 2 and not d.trap and bucket(d, now, 2) then
			if not reachable[id] then
				sink -= 1
			end
			sink += 1
		end
	end
end)

local decoyKeys: { [number]: number } = { [12345] = 1, [67890] = 2 }
bench("refers", function()
	for i = 1, N do
		if decoyKeys[i] ~= nil then
			sink += 1
		end
	end
end)

local canary: { [string]: number } = {}
for i = 1, 64 do
	canary[string.format("%016x", i * 7919)] = i
end
local strs = table.create(64, "")
for i = 1, 64 do
	strs[i] = "player chat line number " .. i
end
bench("canaryS", function()
	for i = 1, N do
		if canary[strs[i % 64 + 1]] then
			sink += 1
		end
	end
end)

local bufs = table.create(64)
for i = 1, 64 do
	local b = buffer.create(64)
	buffer.writeu32(b, 0, i)
	bufs[i] = b
end
bench("canaryB", function()
	for i = 1, N do
		if canary[buffer.tostring(bufs[i % 64 + 1])] then
			sink += 1
		end
	end
end)
bench("canaryBL", function()
	for i = 1, N do
		local b = bufs[i % 64 + 1]
		if buffer.len(b) == 16 and canary[buffer.tostring(b)] then
			sink += 1
		end
	end
end)

-- replay window: highest accepted sequence (full value), 64-bit bitmap in two words
local highest, w0, w1 = 1000, 0, 0
bench("replay", function()
	for i = 1, N do
		local s12 = (highest + 1 + (i % 3 == 0 and -2 or 0)) % 4096
		-- extend to the value nearest highest
		local base = highest - highest % 4096
		local s = base + s12
		if s > highest + 2048 then
			s -= 4096
		elseif s < highest - 2048 then
			s += 4096
		end
		local d = s - highest
		if d > 0 then
			if d >= 64 then
				w0, w1 = 0, 0
			elseif d >= 32 then
				w1 = bit32.lshift(w0, d - 32)
				w0 = 0
			else
				w1 = bit32.bor(bit32.lshift(w1, d), bit32.rshift(w0, 32 - d))
				w0 = bit32.lshift(w0, d)
			end
			w0 = bit32.bor(w0, 1)
			highest = s
		else
			local back = -d
			if back < 64 then
				local word = if back < 32 then w0 else w1
				local bit = bit32.lshift(1, back % 32)
				if bit32.band(word, bit) == 0 then
					if back < 32 then
						w0 = bit32.bor(w0, bit)
					else
						w1 = bit32.bor(w1, bit)
					end
				else
					sink += 1 -- duplicate
				end
			end
		end
	end
end)

bench("rngProbe", function()
	for i = 1, N do
		if math.random() < 0.05 then
			sink += 1
		end
	end
end)

local countdown = 20
bench("cntProbe", function()
	for i = 1, N do
		countdown -= 1
		if countdown == 0 then
			sink += 1
			countdown = 1 + math.floor(math.log(1 - math.random()) / math.log(0.95))
		end
	end
end)

local function failing()
	error("The current thread cannot access 'X' (lacking capability)")
end
bench("failPcall", function()
	for i = 1, N do
		pcall(failing)
	end
end)

local IDS = 200
local p = table.create(IDS, 0)
local Np = N
N = 2000
bench("permBuild", function()
	for _ = 1, N do
		for i = 1, IDS do
			p[i] = i
		end
		local x = 0x9e3779b9
		for i = IDS, 2, -1 do
			x = bit32.bxor(x, bit32.lshift(x, 13))
			x = bit32.bxor(x, bit32.rshift(x, 17))
			x = bit32.bxor(x, bit32.lshift(x, 5))
			local j = x % i + 1
			p[i], p[j] = p[j], p[i]
		end
	end
end)
print("permBuild figure is per namespace of " .. IDS .. " ids; divide by " .. IDS .. " for per id")
N = Np
print("sink", sink)
