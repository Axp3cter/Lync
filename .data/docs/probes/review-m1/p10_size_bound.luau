--!nocheck
-- The planner's worst case (dataMaxBits, dataMaxTail) against the real encoder: random codecs,
-- random values, one message each. test/plan/sizes.spec.luau compares the planner with a second
-- model of the encoder; this compares it with Run.encode's output. Run: lune run p10_size_bound.luau [seed]
local process = require("@lune/process")
local P = require("./prelude")
local Gen = require("../../../../test/support/gen")
local Bits, Run = P.Bits, P.Run

math.randomseed(tonumber(process.args[1]) or 1)
local pool = { Instance.new("Part"), Instance.new("Model"), Instance.new("Part") }
local over, checked = 0, 0
for _ = 1, 20000 do
	local schema
	while schema == nil do
		local ok, s = pcall(function()
			return P.Lync.schema("p", { e = P.Lync.event({ from = "client", data = Gen.codec(3, math.random(1, 40)) }) })
		end)
		schema = if ok then s else nil
	end
	local definition = schema.ir.byName.e
	local value = Gen.value(definition.data, 40, Gen.style(pool))
	local instances = { list = {}, index = {} }
	local okEncode = pcall(function()
		Run.collect(definition.data, { value }, 1, instances)
		local w = Bits.writer()
		Run.encode(w, definition.data, { value }, 1, instances, "p.e:fire")
		checked += 1
		if w.bit > definition.dataMaxBits or w.tailBytes > definition.dataMaxTail then
			over += 1
			print(string.format("over: %d bits (bound %d), %d tail (bound %d)", w.bit, definition.dataMaxBits, w.tailBytes, definition.dataMaxTail))
		end
	end)
end
print(string.format("%d messages encoded, %d over the planner's worst case", checked, over))
