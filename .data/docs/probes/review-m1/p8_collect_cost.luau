--!nocheck
-- Run.collect lists a run's instances by encoding the whole run into a scratch writer, so every
-- run of a definition with instances is encoded twice, rotation canonicalisation included.
-- Run: lune run p8_collect_cost.luau
local P = require("./prelude")
local Bits, Run, Leaves = P.Bits, P.Run, P.Leaves
local t = P.Lync.types

local codec = P.plan(P.Lync, {
	target = t.instance("BasePart"),
	look = t.rotation(9),
	position = t.vector3(-2048, 2048, 1 / 32),
	health = t.int(0, 100),
})
local parts = {}
for i = 1, 8 do parts[i] = Instance.new("Part") end
local values = {}
for i = 1, 8 do
	values[i] = {
		target = parts[i],
		look = CFrame.Angles(i * 0.3, i * 0.7, i * 0.11),
		position = Vector3.new(i, 2 * i, 3 * i),
		health = i * 10,
	}
end

local function encodeOnly(instances)
	local w = Bits.writer()
	Run.encode(w, codec, values, #values, instances, "p.e:fire")
end

local ROUNDS, REPEATS = 15, 200
local best = { math.huge, math.huge }
for _ = 1, ROUNDS do
	local t0 = os.clock()
	for _ = 1, REPEATS do
		local instances = { list = {}, index = {} }
		Run.collect(codec, values, #values, instances)
	end
	best[1] = math.min(best[1], os.clock() - t0)
	t0 = os.clock()
	for _ = 1, REPEATS do
		local instances = { list = {}, index = {} }
		Run.collect(codec, values, #values, instances)
		encodeOnly(instances)
	end
	best[2] = math.min(best[2], os.clock() - t0)
end
print(string.format("8-row run with an instance and a rotation: Run.collect %.1f µs, collect + encode %.1f µs (collect is %.0f%% of the total)",
	best[1] * 1e6 / REPEATS, best[2] * 1e6 / REPEATS, 100 * best[1] / best[2]))
