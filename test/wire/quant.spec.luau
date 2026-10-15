--!strict

local process = require("@lune/process")

local Bits = require("../../src/wire/bits")
local Check = require("../support/check")
local Golden = require("../support/golden")
local Ints = require("../../src/wire/ints")
local Prop = require("../support/prop")
local Quant = require("../../src/wire/quant")
local cases = require("./quant.cases")

type Quaternion = { x: number, y: number, z: number, w: number }

-- probes/design-3/number_steps.out: (min, max, step, steps, bits).
-- `LYNC_FULL=1` runs the random checks at full counts; the default keeps the suite fast.
local IS_FULL = process.env.LYNC_FULL == "1"
local DEFAULT_RANDOM_RUNS = 10_000

local function runsOf(fullCount: number): number
	return if IS_FULL then fullCount else math.min(fullCount, DEFAULT_RANDOM_RUNS)
end

local NUMBER_CASES = {
	{ -2048, 2048, 0.1, 40960, 16 },
	{ 0, 1, 0.1, 10, 4 },
	{ 0, 100, 0.01, 10000, 14 },
	{ -1, 1, 0.001, 2000, 11 },
	{ 0, 0.3, 0.1, 3, 2 },
	{ 0, 1, 1 / 3, 3, 2 },
	{ 0, 0.7, 0.1, 7, 3 },
	{ 0, 2.3, 0.1, 23, 5 },
	{ -512, 512, 0.05, 20480, 15 },
}

local function matrixOf(q: Quaternion): { number }
	local x, y, z, w = q.x, q.y, q.z, q.w
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

local function randomQuaternion(): Quaternion
	local u1, u2, u3 = math.random(), math.random() * 2 * math.pi, math.random() * 2 * math.pi
	local a, b = math.sqrt(1 - u1), math.sqrt(u1)
	return { x = a * math.sin(u2), y = a * math.cos(u2), z = b * math.sin(u3), w = b * math.cos(u3) }
end

local function degreesBetween(a: Quaternion, b: Quaternion): number
	local dot = math.abs(a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w)
	return math.deg(2 * math.acos(math.min(1, dot)))
end

local function roundTripped(q: Quaternion, bits: number): Quaternion
	local m = matrixOf(q)
	local flag, index, a, b, c =
		Quant.rotation(m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8], m[9], bits)
	local x, y, z, w = Quant.unrotation(flag, index, a, b, c, bits)
	return { x = x :: number, y = y, z = z, w = w }
end

local function directionError(x: number, y: number, z: number, bits: number): number
	local qx, qy = Quant.direction(x, y, z, bits)
	local dx, dy, dz = Quant.undirection(qx, qy, bits)
	local length = math.sqrt(x * x + y * y + z * z)
	local dot = (x * dx + y * dy + z * dz) / length
	return math.deg(math.acos(math.clamp(dot, -1, 1)))
end

local function randomDirection(): (number, number, number)
	local z = 2 * math.random() - 1
	local angle = 2 * math.pi * math.random()
	local radius = math.sqrt(1 - z * z)
	return radius * math.cos(angle), radius * math.sin(angle), z
end

local function axisMatrices(): { { number } }
	local matrices = {}
	for code = 0, 3 ^ 9 - 1 do
		local entries, rest = {}, code
		for i = 9, 1, -1 do
			entries[i] = rest % 3 - 1
			rest //= 3
		end

		local columns, rows = { 0, 0, 0 }, { 0, 0, 0 }
		local isSignedPermutation = true
		for i, entry in entries do
			local row, column = (i - 1) // 3 + 1, (i - 1) % 3 + 1
			rows[row] += math.abs(entry)
			columns[column] += math.abs(entry)
		end
		for i = 1, 3 do
			isSignedPermutation = isSignedPermutation and rows[i] == 1 and columns[i] == 1
		end

		local e = entries
		local determinant = e[1] * (e[5] * e[9] - e[6] * e[8])
			- e[2] * (e[4] * e[9] - e[6] * e[7])
			+ e[3] * (e[4] * e[8] - e[5] * e[7])
		if isSignedPermutation and determinant == 1 then
			table.insert(matrices, entries)
		end
	end

	return matrices
end

local function singleRowOf(case: cases.Case): Bits.Writer
	local w = Bits.writer()
	local params, input = case.params, case.input
	if case.codec == "number" then
		local n = Quant.numberSteps(params[1], params[2], params[3]) :: number
		Bits.write(w, Ints.width(n + 1), Quant.number(input[1], params[1], params[3], n))
	elseif case.codec == "angle" then
		local n = Quant.angleSteps(params[1])
		Bits.write(w, Ints.width(n), Quant.angle(input[1], n))
	elseif case.codec == "direction" then
		local qx, qy = Quant.direction(input[1], input[2], input[3], params[1])
		Bits.write(w, params[1], qx)
		Bits.write(w, params[1], qy)
	elseif case.codec == "rotation" then
		local flag, index, a, b, c = Quant.rotation(
			input[1],
			input[2],
			input[3],
			input[4],
			input[5],
			input[6],
			input[7],
			input[8],
			input[9],
			params[1]
		)
		Bits.write(w, 1, flag)
		if flag == 1 then
			Bits.write(w, 5, index)
		else
			Bits.write(w, 2, index)
			Bits.write(w, params[1], a)
			Bits.write(w, params[1], b)
			Bits.write(w, params[1], c)
		end
	else
		for _, channel in input do
			Bits.write(w, 8, Quant.color(channel))
		end
	end

	return w
end

local function streamBitsOf(w: Bits.Writer): string
	local digits = table.create(w.bit) :: { string }
	for i = 0, w.bit - 1 do
		digits[i + 1] = tostring(buffer.readbits(w.buf, i, 1))
	end

	return table.concat(digits)
end

return {
	["reproduces the milestone 1 quantizer vectors"] = function()
		for _, case in cases do
			local entry = Golden.entry(case.id)
			Check.expectEqual(entry.milestone, 1, case.id)
			Check.expectEqual(streamBitsOf(singleRowOf(case)), entry.bits, case.id)
		end
	end,
	["keeps t.number's error within step / 2 on the number_steps cases"] = function()
		for _, case in NUMBER_CASES do
			local min, max, step, steps, bits = case[1], case[2], case[3], case[4], case[5]
			local n = Quant.numberSteps(min, max, step) :: number
			Check.expectEqual(n, steps, `steps of {min}, {max}, {step}`)
			Check.expectEqual(math.ceil(math.log(n + 1, 2)), bits)
			Check.expectEqual(Quant.number(max, min, step, n), n, "max codes as n")
			Check.expectEqual(Quant.number(min, min, step, n), 0, "min codes as 0")

			for i = 0, 2000 do
				local v = if i == 0 then max else min + (max - min) * math.random()
				local q = Quant.number(v, min, step, n)
				Check.expect(q >= 0 and q <= n, `code {q} of {v} must be in [0, {n}]`)
				local error = math.abs(Quant.unnumber(q, min, step, max) - v)
				Check.expect(error <= step / 2 * (1 + 1e-9), `error {error} of {v} for step {step}`)
			end
		end
	end,

	["decodes every t.number grid code to a value that re-encodes to it"] = function()
		for _, case in NUMBER_CASES do
			local min, max, step = case[1], case[2], case[3]
			local n = Quant.numberSteps(min, max, step) :: number
			for q = 0, n do
				local v = Quant.unnumber(q, min, step, max)
				Check.expect(
					v >= min and v <= max,
					`code {q} of ({min}, {max}, {step}) decodes to {v}`
				)
				Check.expectEqual(
					Quant.number(v, min, step, n),
					q,
					`code {q} of ({min}, {max}, {step})`
				)
			end
		end
	end,

	["decodes every t.angle grid code to an angle that re-encodes to it"] = function()
		for _, step in { math.rad(1), 2 * math.pi / 1000, 2 * math.pi / 256, 0.3 } do
			local n = Quant.angleSteps(step)
			for q = 0, n - 1 do
				Check.expectEqual(Quant.angle(Quant.unangle(q, n), n), q, `code {q} of {n} steps`)
			end
		end
	end,

	-- A decoded direction is a Vector3, stored in f32, so these decode through real Vector3s.
	["finds exactly 511 non-canonical direction codes at 8 bits, and encodes only canonical ones"] = function()
		local nonCanonicalCount = 0
		for qx = 0, 255 do
			for qy = 0, 255 do
				local decoded = Vector3.new(Quant.undirection(qx, qy, 8))
				local encodedX, encodedY = Quant.direction(decoded.X, decoded.Y, decoded.Z, 8)
				local isCanonical = Quant.directionIsCanonical(qx, qy, 8)
				local isKept = encodedX == qx and encodedY == qy
				Check.expectEqual(
					isKept,
					isCanonical,
					`({qx}, {qy}) is kept exactly when canonical`
				)
				Check.expect(
					Quant.directionIsCanonical(encodedX, encodedY, 8),
					`E({qx}, {qy}) is canonical`
				)
				if not isCanonical then
					nonCanonicalCount += 1
				end
			end
		end
		Check.expectEqual(nonCanonicalCount, 511)
		Check.expect(not Quant.directionIsCanonical(0, 0, 8), "(0, 0) folds onto (255, 255)")
		Check.expect(Quant.directionIsCanonical(255, 255, 8), "(255, 255) is the canonical member")
	end,

	["encodes random directions to canonical codes that decode and re-encode to themselves"] = function()
		for _, case in
			{
				{ bits = 8, count = runsOf(100_000) },
				{ bits = 10, count = runsOf(1_000_000) },
				{ bits = 12, count = runsOf(1_000_000) },
				{ bits = 16, count = runsOf(1_000_000) },
			}
		do
			local bits = case.bits
			for _ = 1, case.count do
				local direction = Vector3.new(randomDirection())
				local qx, qy = Quant.direction(direction.X, direction.Y, direction.Z, bits)
				Check.expect(Quant.directionIsCanonical(qx, qy, bits), `{direction} at {bits} bits`)

				local decoded = Vector3.new(Quant.undirection(qx, qy, bits))
				local againX, againY = Quant.direction(decoded.X, decoded.Y, decoded.Z, bits)
				Check.expect(
					againX == qx and againY == qy,
					`({qx}, {qy}) at {bits} bits re-encodes to itself`
				)
			end
		end
	end,

	["keeps exactly the canonical codes among random codes at 16 bits"] = function()
		local maxCode = 2 ^ 16 - 1
		for _ = 1, runsOf(100_000) do
			local qx, qy = math.random(0, maxCode), math.random(0, maxCode)
			local decoded = Vector3.new(Quant.undirection(qx, qy, 16))
			local encodedX, encodedY = Quant.direction(decoded.X, decoded.Y, decoded.Z, 16)
			local isKept = encodedX == qx and encodedY == qy
			Check.expectEqual(isKept, Quant.directionIsCanonical(qx, qy, 16), `({qx}, {qy})`)
			Check.expect(
				Quant.directionIsCanonical(encodedX, encodedY, 16),
				`E({qx}, {qy}) is canonical`
			)
		end
	end,

	["refuses steps that do not divide the range"] = function()
		Check.expectEqual(Quant.numberSteps(0, 1, 0.3), nil)
		Check.expectEqual(Quant.numberSteps(0, 1, 0.35), nil)
		Check.expectEqual(Quant.numberSteps(0, 0.3, 0.1), 3)
	end,

	["counts t.angle's steps per turn"] = function()
		Check.expectEqual(Quant.angleSteps(math.rad(1)), 360)
		Check.expectEqual(Quant.angleSteps(2 * math.pi / 1000), 1000)
		Check.expectEqual(Quant.angleSteps(2 * math.pi / 256), 256)
		Check.expectEqual(Quant.angleSteps(0.3), 21)
	end,

	["round-trips angles to within half a step"] = function()
		Prop.check("angle round trip", function(size: number): { number }
			return { math.random(1, 4096), (math.random() - 0.5) * size * 4 * math.pi }
		end, function(case: { number })
			local n, v = case[1], case[2]
			local q = Quant.angle(v, n)
			Check.expect(q >= 0 and q < n and q == math.floor(q), `code {q} must be in [0, {n})`)
			local difference = math.abs(Quant.unangle(q, n) - v % (2 * math.pi))
			local circular = math.min(difference, 2 * math.pi - difference)
			Check.expect(circular <= math.pi / n * (1 + 1e-9), `error {circular} for n {n}`)
			Check.expectEqual(Quant.angle(Quant.unangle(q, n), n), q, "decoded angle recodes")
		end)
		Check.expectEqual(Quant.angle(2 * math.pi - 1e-12, 360), 0)
		Check.expectEqual(Quant.angle(-1e-12, 360), 0)
		Check.expectEqual(Quant.angle(math.pi, 1000), 500)
	end,

	-- v5.md §3.3 gives 0.23° (10 bits), 0.057° (12) and 0.45° (smallest-three, 9 bits): the maxima
	-- of 20,000 random samples (compression §4.4, §4.5). Searching for the worst case finds
	-- 0.2369°, 0.05924° and 0.5187°, so these tests bound by those; reported to the lead.
	["keeps octahedral error within 0.237° at 10 bits and 0.0593° at 12"] = function()
		for _, limit in { { bits = 10, degrees = 0.237 }, { bits = 12, degrees = 0.0593 } } do
			local worst = 0
			for _ = 1, 50_000 do
				local x, y, z = randomDirection()
				local scale = 10 ^ math.random(-3, 3)
				worst = math.max(worst, directionError(x * scale, y * scale, z * scale, limit.bits))
			end
			Check.expect(worst <= limit.degrees, `{limit.bits} bits: worst {worst}°`)
		end
	end,

	["codes the axes and the fold of z < 0"] = function()
		Check.expectEqual({ Quant.direction(0, 0, 1, 11) }, { 1024, 1024 }, "G8's aim")
		Check.expectEqual({ Quant.direction(0, 0, -1, 10) }, { 1023, 1023 }, "sgn(0) is +1")
		Check.expectEqual({ Quant.direction(1, 0, 0, 10) }, { 1023, 512 })
		Check.expectEqual({ Quant.direction(0, -1, 0, 10) }, { 512, 0 })
		for _, axis in
			{ { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } }
		do
			Check.expect(
				directionError(axis[1], axis[2], axis[3], 16) < 0.01,
				"axis decodes near itself"
			)
		end
	end,

	["keeps smallest-three error within 0.519° at 9 bits"] = function()
		local worst = 0
		for _ = 1, 50_000 do
			local q = randomQuaternion()
			worst = math.max(worst, degreesBetween(q, roundTripped(q, 9)))
		end
		Check.expect(worst <= 0.519, `worst {worst}°`)
	end,

	["takes every quaternion branch and drops the largest component"] = function()
		local half = math.sqrt(0.5)
		local cases = {
			{ q = { x = 0.1, y = 0.2, z = 0.3, w = math.sqrt(0.86) }, dropped = 3 },
			{ q = { x = math.sqrt(0.86), y = 0.1, z = -0.2, w = 0.3 }, dropped = 0 },
			{ q = { x = 0.1, y = -math.sqrt(0.86), z = 0.2, w = 0.3 }, dropped = 1 },
			{ q = { x = 0.3, y = 0.2, z = math.sqrt(0.86), w = -0.1 }, dropped = 2 },
			{ q = { x = half, y = 0, z = 0, w = half }, dropped = 0 },
			{ q = { x = 0.5, y = 0.5, z = 0.5, w = 0.5 }, dropped = 0 },
		}
		for i, case in cases do
			local m = matrixOf(case.q)
			local flag, index =
				Quant.rotation(m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8], m[9], 12)
			if i < 5 then
				Check.expectEqual({ flag, index }, { 0, case.dropped }, `case {i}`)
			end
			Check.expect(
				degreesBetween(case.q, roundTripped(case.q, 12)) < 0.06,
				`case {i} round trip`
			)
		end
	end,

	["refuses kept components whose squares sum past 1"] = function()
		local x = Quant.unrotation(0, 3, 511, 511, 511, 9)
		Check.expectEqual(x, nil)
		Check.expect(Quant.unrotation(0, 3, 256, 256, 256, 9) ~= nil, "zero components decode")
	end,

	["lists the 24 axis matrices in lexicographic order and round-trips each exactly"] = function()
		local expected = axisMatrices()
		Check.expectEqual(#expected, 24)
		Check.expectEqual(Quant.AXIS, expected)
		for i, m in Quant.AXIS do
			local coded =
				{ Quant.rotation(m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8], m[9], 9) }
			Check.expectEqual(coded, { 1, i - 1, 0, 0, 0 }, `axis {i}`)

			local nudge = 0.9e-6
			local nudged = {
				Quant.rotation(
					m[1] - nudge,
					m[2] + nudge,
					m[3],
					m[4],
					m[5],
					m[6],
					m[7],
					m[8],
					m[9],
					9
				),
			}
			Check.expectEqual(nudged, { 1, i - 1, 0, 0, 0 }, `axis {i} within 1e-6`)

			local x, y, z, w = Quant.unrotation(1, i - 1, 0, 0, 0, 9)
			local decoded = matrixOf({ x = x :: number, y = y, z = z, w = w })
			for j = 1, 9 do
				Check.expectEqual(math.round(decoded[j]), m[j], `axis {i} entry {j}`)
				Check.expect(math.abs(decoded[j] - m[j]) < 1e-12, `axis {i} entry {j} exact`)
			end
		end
	end,

	["agrees with Roblox's CFrame quaternion convention"] = function()
		-- Lune's CFrame holds f32 entries, so this checks the convention (a mismatch moves entries by
		-- up to 2), not the precision.
		for _ = 1, 1000 do
			local cf = CFrame.Angles(math.random() * 7, math.random() * 7, math.random() * 7)
			local entries = { select(4, cf:GetComponents()) }
			local flag, index, a, b, c = Quant.rotation(
				entries[1],
				entries[2],
				entries[3],
				entries[4],
				entries[5],
				entries[6],
				entries[7],
				entries[8],
				entries[9],
				15
			)
			local x, y, z, w = Quant.unrotation(flag, index, a, b, c, 15)
			local decoded = { select(4, CFrame.new(0, 0, 0, x :: number, y, z, w):GetComponents()) }
			for j = 1, 9 do
				Check.expect(
					math.abs(decoded[j] - entries[j]) < 1e-3,
					`entry {j}: {decoded[j]} vs {entries[j]}`
				)
			end
		end
	end,

	["re-encodes every colour code to itself"] = function()
		for q = 0, 255 do
			Check.expectEqual(Quant.color(Quant.uncolor(q)), q)
		end
		for _ = 1, 10_000 do
			local c = math.random()
			Check.expect(
				math.abs(Quant.uncolor(Quant.color(c)) - c) <= 0.5 / 255 + 1e-12,
				`channel {c}`
			)
		end
		Check.expectEqual(Quant.color(0.5), 128)
		Check.expectEqual(Quant.color(1), 255)
	end,
}
