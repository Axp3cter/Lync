--!strict

--[=[
	quant.cases

	The inputs of the milestone 1 quantizer vectors in the golden index (m1-plan.md §4.4): edges
	of each quantizer, every smallest-three branch, and the 24 axis-aligned rotations.

	`quant.golden.luau` encodes them from v5.md §3.3 alone to make the index entries, and
	`quant.spec.luau` checks that `Quant` reproduces them. Rotations are given as quaternions and
	turned into matrices here, so both sides start from the same matrix.
]=]

export type Case = {
	id: string,
	what: string,
	codec: "number" | "angle" | "direction" | "rotation" | "color3",
	params: { number },
	input: { number },
}

local function matrixOf(x: number, y: number, z: number, w: number): { number }
	return {
		1 - 2 * (y * y + z * z),
		2 * (x * y - z * w),
		2 * (x * z + y * w),
		2 * (x * y + z * w),
		1 - 2 * (x * x + z * z),
		2 * (y * z - x * w),
		2 * (x * z - y * w),
		2 * (y * z + x * w),
		1 - 2 * (x * x + y * y),
	}
end

local LARGE = math.sqrt(0.86)

local cases: { Case } = {
	{
		id = "Q-number-min",
		what = "t.number(-2048, 2048, 0.1) of -2048",
		codec = "number",
		params = { -2048, 2048, 0.1 },
		input = { -2048 },
	},
	{
		id = "Q-number-max",
		what = "t.number(-2048, 2048, 0.1) of 2048",
		codec = "number",
		params = { -2048, 2048, 0.1 },
		input = { 2048 },
	},
	{
		id = "Q-number-half",
		what = "t.number(-2048, 2048, 0.1) of 0.05",
		codec = "number",
		params = { -2048, 2048, 0.1 },
		input = { 0.05 },
	},
	{
		id = "Q-number-tolerance",
		what = "t.number(0, 0.3, 0.1) of 0.3 (n = 3 within 1e-9)",
		codec = "number",
		params = { 0, 0.3, 0.1 },
		input = { 0.3 },
	},
	{
		id = "Q-number-third",
		what = "t.number(0, 1, 1/3) of 0.5",
		codec = "number",
		params = { 0, 1, 1 / 3 },
		input = { 0.5 },
	},
	{
		id = "Q-number-fine",
		what = "t.number(-1, 1, 0.001) of 0.0005",
		codec = "number",
		params = { -1, 1, 0.001 },
		input = { 0.0005 },
	},
	{
		id = "Q-angle-zero",
		what = "t.angle(math.rad(1)) of 0",
		codec = "angle",
		params = { math.rad(1) },
		input = { 0 },
	},
	{
		id = "Q-angle-below-zero",
		what = "t.angle(math.rad(1)) of -1e-9",
		codec = "angle",
		params = { math.rad(1) },
		input = { -1e-9 },
	},
	{
		id = "Q-angle-wrap",
		what = "t.angle(math.rad(1)) of math.rad(359.5)",
		codec = "angle",
		params = { math.rad(1) },
		input = { math.rad(359.5) },
	},
	{
		id = "Q-angle-half",
		what = "t.angle(math.rad(1)) of pi",
		codec = "angle",
		params = { math.rad(1) },
		input = { math.pi },
	},
	{
		id = "Q-angle-negative",
		what = "t.angle(2pi/1000) of -pi/2 (n = 1000)",
		codec = "angle",
		params = { 2 * math.pi / 1000 },
		input = { -math.pi / 2 },
	},
	{
		id = "Q-direction-up",
		what = "t.direction(10) of (0, 0, 1)",
		codec = "direction",
		params = { 10 },
		input = { 0, 0, 1 },
	},
	{
		id = "Q-direction-down",
		what = "t.direction(10) of (0, 0, -1), sgn(0) = +1",
		codec = "direction",
		params = { 10 },
		input = { 0, 0, -1 },
	},
	{
		id = "Q-direction-x",
		what = "t.direction(10) of (1, 0, 0)",
		codec = "direction",
		params = { 10 },
		input = { 1, 0, 0 },
	},
	{
		id = "Q-direction-minus-x",
		what = "t.direction(10) of (-1, 0, 0)",
		codec = "direction",
		params = { 10 },
		input = { -1, 0, 0 },
	},
	{
		id = "Q-direction-y",
		what = "t.direction(10) of (0, 1, 0)",
		codec = "direction",
		params = { 10 },
		input = { 0, 1, 0 },
	},
	{
		id = "Q-direction-minus-y",
		what = "t.direction(10) of (0, -1, 0)",
		codec = "direction",
		params = { 10 },
		input = { 0, -1, 0 },
	},
	{
		id = "Q-direction-diagonal",
		what = "t.direction(12) of (1, 1, 1)",
		codec = "direction",
		params = { 12 },
		input = { 1, 1, 1 },
	},
	{
		id = "Q-direction-fold",
		what = "t.direction(10) of (1, -2, -3)",
		codec = "direction",
		params = { 10 },
		input = { 1, -2, -3 },
	},
	{
		id = "Q-direction-fold-zero",
		what = "t.direction(8) of (-0.6, 0, -0.8)",
		codec = "direction",
		params = { 8 },
		input = { -0.6, 0, -0.8 },
	},
	{
		id = "Q-direction-wide",
		what = "t.direction(16) of (0.3, -0.4, 0.5)",
		codec = "direction",
		params = { 16 },
		input = { 0.3, -0.4, 0.5 },
	},
	{
		id = "Q-rotation-trace",
		what = "t.rotation(9) of quaternion (0.1, 0.2, 0.3, sqrt 0.86): trace branch, drops w",
		codec = "rotation",
		params = { 9 },
		input = matrixOf(0.1, 0.2, 0.3, LARGE),
	},
	{
		id = "Q-rotation-r00",
		what = "t.rotation(9) of quaternion (sqrt 0.86, 0.1, -0.2, 0.3): R00 branch, drops x",
		codec = "rotation",
		params = { 9 },
		input = matrixOf(LARGE, 0.1, -0.2, 0.3),
	},
	{
		id = "Q-rotation-r11",
		what = "t.rotation(9) of quaternion (0.1, -sqrt 0.86, 0.2, 0.3): R11 branch, drops y, negated",
		codec = "rotation",
		params = { 9 },
		input = matrixOf(0.1, -LARGE, 0.2, 0.3),
	},
	{
		id = "Q-rotation-r22",
		what = "t.rotation(15) of quaternion (0.3, 0.2, sqrt 0.86, -0.1): R22 branch, drops z",
		codec = "rotation",
		params = { 15 },
		input = matrixOf(0.3, 0.2, LARGE, -0.1),
	},
	{
		id = "Q-rotation-narrow",
		what = "t.rotation(7) of quaternion (-0.5, 0.5, 0.1, sqrt 0.49): trace branch, drops w",
		codec = "rotation",
		params = { 7 },
		input = matrixOf(-0.5, 0.5, 0.1, math.sqrt(0.49)),
	},
	{
		id = "Q-color-edges",
		what = "t.color3() of (0, 0.5, 1)",
		codec = "color3",
		params = {},
		input = { 0, 0.5, 1 },
	},
	{
		id = "Q-color-steps",
		what = "t.color3() of (0.2, 0.4, 0.5/255)",
		codec = "color3",
		params = {},
		input = { 0.2, 0.4, 0.5 / 255 },
	},
}

-- The 24 axis-aligned rotations in ascending lexicographic order of their entries: counting up in
-- base 3 with digit = entry + 1 visits matrices in that order.
local axisCount = 0
for code = 0, 3 ^ 9 - 1 do
	local entries = table.create(9, 0)
	local rest = code
	for i = 9, 1, -1 do
		entries[i] = rest % 3 - 1
		rest //= 3
	end

	local isSignedPermutation = true
	for line = 0, 2 do
		local rowSum = math.abs(entries[3 * line + 1])
			+ math.abs(entries[3 * line + 2])
			+ math.abs(entries[3 * line + 3])
		local columnSum = math.abs(entries[line + 1])
			+ math.abs(entries[line + 4])
			+ math.abs(entries[line + 7])
		isSignedPermutation = isSignedPermutation and rowSum == 1 and columnSum == 1
	end

	local e = entries
	local determinant = e[1] * (e[5] * e[9] - e[6] * e[8])
		- e[2] * (e[4] * e[9] - e[6] * e[7])
		+ e[3] * (e[4] * e[8] - e[5] * e[7])
	if not isSignedPermutation or determinant ~= 1 then
		continue
	end

	table.insert(cases, {
		id = string.format("Q-rotation-axis-%02d", axisCount),
		what = `t.rotation(9) of the axis-aligned matrix \{{table.concat(entries, ", ")}}, index {axisCount}`,
		codec = "rotation",
		params = { 9 },
		input = entries,
	})
	axisCount += 1
end

return cases
