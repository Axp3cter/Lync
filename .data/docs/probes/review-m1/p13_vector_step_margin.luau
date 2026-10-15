--!nocheck
-- t.vector3 with a step just above the f32 spacing that vectorStep allows: do decoded components
-- (stored in f32) still re-quantize to their own codes? Run: lune run p13_vector_step_margin.luau
local P = require("./prelude")
local Leaves, Quant = P.Leaves, P.Quant
local t = P.Lync.types

local n = math.floor(6000 * 2 ^ 12) - 1
local step = 6000 / n
local codec = P.plan(P.Lync, t.vector3(-3000, 3000, step))
local axis = codec.axis
print(string.format("t.vector3(-3000, 3000, %.17g): %d steps, f32 spacing at 3000 = %.17g", step, axis.steps, 2 ^ -12))
local bad, checked = 0, 0
local function check(q)
	checked += 1
	local v = Vector3.new(Quant.unnumber(q, axis.min, axis.step), 0, 0)
	local code = Leaves.vector3Codes(v.X, 0, 0, axis)
	if code ~= q then
		bad += 1
		if bad <= 3 then
			print(string.format("  q = %d decodes to %.17g (f32 %.17g), re-encodes to %s", q, Quant.unnumber(q, axis.min, axis.step), v.X, tostring(code)))
		end
	end
end
for q = axis.steps - 200000, axis.steps do check(q) end
for q = 0, 200000 do check(q) end
math.randomseed(3)
for _ = 1, 200000 do check(math.random(0, axis.steps)) end
print(string.format("%d of %d codes do not re-encode to themselves", bad, checked))
