--!strict
-- Per-message cost of the `checks` constraints and of telemetry ring writes, per player state in buffers.
--   within(ref, maxDist): distance of a client Vector3 claim to a server-known position (squared compare)
--   monotonic(): integer strictly greater than the last accepted value
--   maxTotal(cap, window): sliding sum over `window` seconds kept as B time buckets (ring), O(1) amortised
--   aim ring: one u16 pitch + u16 yaw sample per tick into a per-player ring
--   atom: copy `before + after` seconds of the aim ring (VACnet 0.5 s + 0.25 s at 60 Hz = 45 samples, 180 B)
-- Run: luau -O2 checks_cost.luau  and  luau -O2 --codegen checks_cost.luau
local PLAYERS = 100
local N = 2_000_000

local function bench(name: string, f: () -> number)
	local best = math.huge
	local sink = 0
	for _ = 1, 5 do
		local t = os.clock()
		sink += f()
		best = math.min(best, os.clock() - t)
	end
	print(string.format("%-44s %7.1f ns/op  (sink %d)", name, best * 1e9 / N, sink % 7))
end

-- server-known positions (e.g. the rewound shooter), f32 xyz per player
local pos = buffer.create(PLAYERS * 12)
for p = 0, PLAYERS - 1 do
	buffer.writef32(pos, p * 12, p)
	buffer.writef32(pos, p * 12 + 4, 0)
	buffer.writef32(pos, p * 12 + 8, -p)
end
bench("within (distance^2 <= max^2)", function()
	local ok = 0
	local max2 = 4 * 4
	for i = 1, N do
		local p = i % PLAYERS
		local o = p * 12
		local dx = (p + 1.5) - buffer.readf32(pos, o)
		local dy = 0.5 - buffer.readf32(pos, o + 4)
		local dz = (-p + 2) - buffer.readf32(pos, o + 8)
		if dx * dx + dy * dy + dz * dz <= max2 then ok += 1 end
	end
	return ok
end)

local last = buffer.create(PLAYERS * 8)
bench("monotonic (f64 last, strict >)", function()
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
bench("maxTotal (16-bucket sliding sum)", function()
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
bench("aim ring write (u16 pitch, u16 yaw)", function()
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
bench("atom copy (45 samples, 180 B, two-part ring copy) /10", function()
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
