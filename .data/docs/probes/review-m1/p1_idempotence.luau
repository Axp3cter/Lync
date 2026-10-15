--!nocheck
-- v5.md §3.3 "Rule. For every quantizer, encode(decode(q)) = q for every code q the decoder accepts."
-- Exhaustive over t.direction at 8 bits, and t.number / t.angle cases. Run: lune run p1_idempotence.luau
local P = require("./prelude")
local Leaves, Quant, Rows, Bits = P.Leaves, P.Quant, P.Rows, P.Bits
local t = P.Lync.types

-- t.direction: every (qx, qy) the decoder accepts (all of them) must re-encode to itself.
for _, bits in { 8, 10 } do
	local maxCode = 2 ^ bits - 1
	local bad, total, example = 0, 0, nil
	for qx = 0, maxCode do
		for qy = 0, maxCode do
			total += 1
			local v = Leaves.directionOf(qx, qy, bits)
			local ex, ey = Leaves.directionCodes(v, bits)
			if ex ~= qx or ey ~= qy then
				bad += 1
				example = example or { qx, qy, ex, ey, v }
			end
		end
	end
	print(string.format("direction %d bits: %d of %d accepted codes are not fixed points (%.3f%%)", bits, bad, total, 100 * bad / total))
	if example then
		print(string.format("  e.g. (%d, %d) decodes to %s and re-encodes to (%d, %d)", example[1], example[2], tostring(example[5]), example[3], example[4]))
	end
end

-- t.number(0, 0.3, 0.1): the design's own example (n = 3). Decode q = 3, then re-encode.
local codec = P.plan(P.Lync, t.number(0, 0.3, 0.1))
local w = Bits.writer()
Bits.write(w, codec.width, 3)
local decoded, rule = Rows.read(Bits.reader(Bits.finish(w)), codec, {})
print(string.format("t.number(0, 0.3, 0.1): q = 3 decodes (rule %d) to %.17g; max is %.17g", rule, decoded, codec.max))
local ok, err = pcall(Rows.encodeValue, Bits.writer(), codec, decoded, { list = {}, index = {} }, "p.e:fire")
print("  re-encoding the decoded value:", ok and "accepted" or err)

-- A scan of simple t.number declarations for the same failure.
local failures = 0
local checked = 0
for _, case in { { 0, 0.3, 0.1 }, { 0, 0.7, 0.1 }, { -1, 1, 0.1 }, { 0, 1.1, 0.1 }, { 0, 2.3, 0.1 }, { 0.1, 0.9, 0.1 }, { 0, 0.9, 0.3 } } do
	local ok2, c = pcall(P.plan, P.Lync, t.number(case[1], case[2], case[3]))
	if ok2 then
		for q = 0, c.steps do
			checked += 1
			local v = Quant.unnumber(q, c.min, c.step)
			local code = Leaves.numberCode(v, c)
			if code ~= q then
				failures += 1
				print(string.format("  t.number(%g, %g, %g): q = %d decodes to %.17g, re-encodes to %s", case[1], case[2], case[3], q, v, tostring(code)))
			end
		end
	end
end
print(string.format("t.number scan: %d of %d codes not fixed points", failures, checked))

-- t.angle: every code for a spread of steps.
local angleBad, angleChecked = 0, 0
for _, step in { math.rad(1), math.rad(0.1), 2 * math.pi / 1000, 0.001, 0.0001, math.rad(7), 0.3 } do
	local n = Quant.angleSteps(step)
	for q = 0, n - 1 do
		angleChecked += 1
		if Leaves.angleCode(Quant.unangle(q, n), n) ~= q then
			angleBad += 1
		end
	end
end
print(string.format("t.angle scan: %d of %d codes not fixed points", angleBad, angleChecked))

-- t.color3 through a Color3 (f32 on Roblox and Lune).
local colorBad = 0
for q = 0, 255 do
	local r = Leaves.color3Codes(Leaves.color3Of(q, q, q))
	if r ~= q then
		colorBad += 1
	end
end
print(string.format("t.color3: %d of 256 codes not fixed points", colorBad))
