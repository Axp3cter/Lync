--!strict

--[=[
	quant.golden

	Lune script that makes the golden index entries of the quantizer vectors in `quant.cases`, from
	v5.md §3.3 ("Quantizers, exactly") and the single-row encodings of its codec table alone. It
	requires nothing from `src/`, so the entries do not come from the code they test.

	lune run test/wire/quant.golden.luau

	prints a JSON array of the entries, each with `bits` in stream order; they were added once to
	`test/golden/index.json`, with `file` null.
]=]

local serde = require("@lune/serde")

local cases = require("./quant.cases")

local TAU = 2 * math.pi

local function fieldBits(width: number, value: number): string
	local digits = {}
	for i = 0, width - 1 do
		table.insert(digits, tostring(math.floor(value / 2 ^ i) % 2))
	end

	return table.concat(digits)
end

local function ceilLog2(n: number): number
	local width = 0
	while 2 ^ width < n do
		width += 1
	end

	return width
end

local function numberBits(params: { number }, v: number): string
	local min, max, step = params[1], params[2], params[3]
	local n = math.round((max - min) / step)
	local q = math.min(math.floor((v - min) / step + 0.5), n)
	return fieldBits(ceilLog2(n + 1), q)
end

local function angleBits(params: { number }, v: number): string
	local r = TAU / params[1]
	local n = math.round(r)
	if math.abs(r - n) > 1e-9 * math.max(1, r) then
		n = math.ceil(r)
	end

	local wrapped = v - math.floor(v / TAU) * TAU
	local q = math.floor(wrapped * n / TAU + 0.5) % n
	return fieldBits(ceilLog2(n), q)
end

local function sgn(v: number): number
	return if v < 0 then -1 else 1
end

local function directionBits(params: { number }, input: { number }): string
	local x, y, z = input[1], input[2], input[3]
	local s = math.abs(x) + math.abs(y) + math.abs(z)
	local px, py = x / s, y / s
	if z < 0 then
		px, py = (1 - math.abs(py)) * sgn(px), (1 - math.abs(px)) * sgn(py)
	end

	local bits = params[1]
	local m = 2 ^ bits - 1
	return fieldBits(bits, math.floor((px + 1) / 2 * m + 0.5))
		.. fieldBits(bits, math.floor((py + 1) / 2 * m + 0.5))
end

local function axisIndexOf(entries: { number }): number?
	for _, entry in entries do
		if math.abs(entry - math.round(entry)) > 1e-6 then
			return nil
		end
	end

	-- Count the rotations (signed permutations with determinant 1) that sort before this one.
	local target = 0
	for _, entry in entries do
		target = target * 3 + math.round(entry) + 1
	end

	local index = 0
	for code = 0, target - 1 do
		local e, rest = {}, code
		for i = 9, 1, -1 do
			e[i] = rest % 3 - 1
			rest //= 3
		end

		local ok = true
		for line = 0, 2 do
			ok = ok
				and math.abs(e[3 * line + 1]) + math.abs(e[3 * line + 2]) + math.abs(
					e[3 * line + 3]
				) == 1
				and math.abs(e[line + 1]) + math.abs(e[line + 4]) + math.abs(e[line + 7]) == 1
		end

		local det = e[1] * (e[5] * e[9] - e[6] * e[8])
			- e[2] * (e[4] * e[9] - e[6] * e[7])
			+ e[3] * (e[4] * e[8] - e[5] * e[7])
		if ok and det == 1 then
			index += 1
		end
	end

	return index
end

local function rotationBits(params: { number }, r: { number }): string
	local index = axisIndexOf(r)
	if index ~= nil then
		return "1" .. fieldBits(5, index)
	end

	local r00, r01, r02, r10, r11, r12, r20, r21, r22 = table.unpack(r)
	local tr = r00 + r11 + r22
	local q
	if tr >= r00 and tr >= r11 and tr >= r22 then
		local w = math.sqrt(1 + tr) / 2
		q = { (r21 - r12) / (4 * w), (r02 - r20) / (4 * w), (r10 - r01) / (4 * w), w }
	elseif r00 >= r11 and r00 >= r22 then
		local s = math.sqrt(1 + r00 - r11 - r22) * 2
		q = { s / 4, (r01 + r10) / s, (r02 + r20) / s, (r21 - r12) / s }
	elseif r11 >= r22 then
		local s = math.sqrt(1 + r11 - r00 - r22) * 2
		q = { (r01 + r10) / s, s / 4, (r12 + r21) / s, (r02 - r20) / s }
	else
		local s = math.sqrt(1 + r22 - r00 - r11) * 2
		q = { (r02 + r20) / s, (r12 + r21) / s, s / 4, (r10 - r01) / s }
	end

	local dropped = 1
	for i = 2, 4 do
		if math.abs(q[i]) > math.abs(q[dropped]) then
			dropped = i
		end
	end

	local sign = sgn(q[dropped])
	local bits = params[1]
	local m = 2 ^ bits - 1
	local out = "0" .. fieldBits(2, dropped - 1)
	for i = 1, 4 do
		if i ~= dropped then
			out ..= fieldBits(bits, math.floor((sign * q[i] * math.sqrt(2) + 1) / 2 * m + 0.5))
		end
	end

	return out
end

local function colorBits(input: { number }): string
	local out = ""
	for _, c in input do
		out ..= fieldBits(8, math.floor(c * 255 + 0.5))
	end

	return out
end

local entries = {}
for _, case in cases do
	local bits
	if case.codec == "number" then
		bits = numberBits(case.params, case.input[1])
	elseif case.codec == "angle" then
		bits = angleBits(case.params, case.input[1])
	elseif case.codec == "direction" then
		bits = directionBits(case.params, case.input)
	elseif case.codec == "rotation" then
		bits = rotationBits(case.params, case.input)
	else
		bits = colorBits(case.input)
	end

	table.insert(entries, {
		id = case.id,
		bits = bits,
		milestone = 1,
		what = `{case.what}, single-row encoding`,
		design = "v5.md §3.3",
	})
end

print(serde.encode("json", entries, true))
