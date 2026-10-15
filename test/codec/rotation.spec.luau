--!strict

--[=[
	rotation.spec

	`t.rotation` canonical codes (v5.md §3.3, decision "quantizers are idempotent"): with E(q) the
	codes of the f32 CFrame that q decodes to, a code is canonical when E(q) = q, or when
	E(E(q)) = q and q is the lower of the 2-cycle. Decoders refuse other codes (rule 6), and the
	encoder returns the canonical code its iteration reaches.

	These are samples. `test/codec/rotation_full.luau` runs every code at 7 and 8 bits, 10^7 random
	rotations at 9 to 15 bits, and the worst-case error search.
]=]

-- Imports -----------------------------------------------------------------------------------------

local fs = require("@lune/fs")

local Bits = require("../../src/wire/bits")
local Check = require("../support/check")
local Fail = require("../../src/diag/fail")
local Frame = require("../support/frame")
local Gen = require("../support/gen")
local Leaves = require("../../src/codec/leaves")
local Lync = require("../../src")
local Quant = require("../../src/wire/quant")
local Rows = require("../../src/codec/rows")

-- Constants ---------------------------------------------------------------------------------------

const SOURCE = debug.info(1, "s")
const INTERNAL_BODY = "[Lync] internal: t.rotation encode must reach a fixed point or a 2-cycle of "
	.. "encode(decode(q)) within 4 steps; report this as a Lync bug"

--- A 2-cycle at 7 bits: each code decodes to a CFrame that encodes to the other.
const CYCLE_LOWER = { 0, 0, 119, 20, 58 }
const CYCLE_UPPER = { 0, 1, 119, 20, 58 }

const LEAVES_SOURCE = "src/codec/leaves.luau"
const SAMPLE_STRIDE = 9
const RANDOM_ROTATIONS = 20_000

--- The worst error found by search at 9 bits, in degrees (`rotation_full.luau error` and `ties`).
const MAX_ERROR_9_BITS = 0.7256

local t = Lync.types

-- Private -----------------------------------------------------------------------------------------

local function decoded(codes: { number }, bits: number): CFrame?
	return Leaves.rotationOf(codes[1], codes[2], codes[3], codes[4], codes[5], bits, 0, 0, 0)
end

local function isCanonical(codes: { number }, bits: number): boolean
	return Leaves.canonicalRotation(codes[1], codes[2], codes[3], codes[4], codes[5], bits, 0, 0, 0)
		~= nil
end

-- The encoder's iteration with a lower step limit: a copy of `Leaves.rotationCodes`' loop and
-- raise, since the step limit is not a parameter there.
local function encodedWithin(value: CFrame, bits: number, maxSteps: number): { number }
	local _, _, _, r00, r01, r02, r10, r11, r12, r20, r21, r22 = value:GetComponents()
	local previous: { number }? = nil
	local current = { Quant.rotation(r00, r01, r02, r10, r11, r12, r20, r21, r22, bits) }
	for _ = 1, maxSteps do
		local reencoded = encoded(decoded(current, bits) :: CFrame, bits)
		if table.concat(reencoded, ",") == table.concat(current, ",") then
			return current
		end

		if previous ~= nil and table.concat(reencoded, ",") == table.concat(previous, ",") then
			return current
		end

		previous, current = current, reencoded
	end

	return Fail.caller(
		"internal",
		"t.rotation encode",
		"reach a fixed point or a 2-cycle of encode(decode(q)) within 4 steps",
		Fail.NONE,
		"report this as a Lync bug"
	)
end

local function encoded(value: CFrame, bits: number): { number }
	return { Leaves.rotationCodes(value, bits) }
end

local function rowOf(codes: { number }, bits: number): buffer
	local w = Bits.writer()
	Bits.write(w, 1, codes[1])
	if codes[1] == 1 then
		Bits.write(w, 5, codes[2])
	else
		Bits.write(w, 2, codes[2])
		for i = 3, 5 do
			Bits.write(w, bits, codes[i])
		end
	end

	return Bits.finish(w)
end

local function randomRotation(): CFrame
	local u1, u2, u3 = math.random(), math.random() * 2 * math.pi, math.random() * 2 * math.pi
	local a, b = math.sqrt(1 - u1), math.sqrt(u1)

	return CFrame.new(
		0,
		0,
		0,
		a * math.sin(u2),
		a * math.cos(u2),
		b * math.sin(u3),
		b * math.cos(u3)
	)
end

local function checkCode(codes: { number }, bits: number)
	local value = decoded(codes, bits)
	local label = `{bits} bits, {table.concat(codes, ",")}`
	if value == nil then
		Check.expect(not isCanonical(codes, bits), `{label}: does not decode but is accepted`)
		return
	end

	local output = encoded(value, bits)
	Check.expect(
		isCanonical(output, bits),
		`{label}: encodes to non-canonical {table.concat(output, ",")}`
	)
	if isCanonical(codes, bits) then
		Check.expectEqual(output, codes, `{label}: accepted, re-encoded`)
	end
end

-- Tests -------------------------------------------------------------------------------------------

return {
	["internal: the encoder's step limit raises the registered message"] = function()
		local ok, message = pcall(encodedWithin, CFrame.Angles(0.1, 0.2, 0.3), 9, 0)
		Check.expect(not ok, "a step limit of 0 must raise")
		local source, body = string.match(message, "^(.-):%d+: (.*)$")
		Check.expectEqual(source, SOURCE, "position")
		Check.expectEqual(body, INTERNAL_BODY, "message")

		-- The copy raises with the encoder's own arguments.
		local source = fs.readFile(LEAVES_SOURCE)
		for _, argument in
			{ '"t.rotation encode"', "{MAX_ROTATION_STEPS} steps`", "const MAX_ROTATION_STEPS = 4" }
		do
			Check.expect(
				string.find(source, argument, 1, true) ~= nil,
				`leaves.luau must hold {argument}`
			)
		end
	end,

	["a 2-cycle's lower code is canonical and its upper code is rule 6"] = function()
		Check.expectEqual(
			encoded(decoded(CYCLE_LOWER, 7) :: CFrame, 7),
			CYCLE_LOWER,
			"lower's decoding"
		)
		Check.expectEqual(
			encoded(decoded(CYCLE_UPPER, 7) :: CFrame, 7),
			CYCLE_LOWER,
			"upper's decoding"
		)
		Check.expect(isCanonical(CYCLE_LOWER, 7), "the lower code must be canonical")
		Check.expect(not isCanonical(CYCLE_UPPER, 7), "the upper code must not be canonical")

		local codec = Gen.plan(t.rotation(7))
		for _, case in { { codes = CYCLE_LOWER, rule = 0 }, { codes = CYCLE_UPPER, rule = 6 } } do
			local _, rule = Rows.read(
				Bits.reader(rowOf(case.codes, 7)),
				codec,
				Rows.beginChunk({}, 0, 0),
				1,
				{}
			)
			Check.expectEqual(rule, case.rule, `row of {table.concat(case.codes, ",")}`)
		end

		local values = table.create(4, decoded(CYCLE_UPPER, 7))
		local block = Frame.decodeRun(Frame.encodeRun(codec, values, #values), codec, #values, {})
		Check.expectEqual(block.rule, 0, "block")
		Check.expectEqual(block.values[1], decoded(CYCLE_LOWER, 7), "block value")
	end,

	["every axis code is canonical"] = function()
		for bits = 7, 15 do
			for index = 0, 23 do
				Check.expect(isCanonical({ 1, index, 0, 0, 0 }, bits), `{bits} bits, axis {index}`)
			end
		end
	end,

	["sampled codes at 7 and 8 bits are refused or re-encode to themselves"] = function()
		for _, bits in { 7, 8 } do
			local maxCode = 2 ^ bits - 1
			for dropped = 0, 3 do
				for a = dropped, maxCode, SAMPLE_STRIDE do
					for b = 0, maxCode, SAMPLE_STRIDE do
						for c = bits, maxCode, SAMPLE_STRIDE do
							checkCode({ 0, dropped, a, b, c }, bits)
						end
					end
				end
			end
		end
	end,

	["random rotations at 9 to 15 bits encode canonically"] = function()
		math.randomseed(915)
		for i = 1, RANDOM_ROTATIONS do
			local bits = 9 + i % 7
			local output = encoded(randomRotation(), bits)
			Check.expect(isCanonical(output, bits), `{bits} bits: {table.concat(output, ",")}`)
			Check.expectEqual(encoded(decoded(output, bits) :: CFrame, bits), output, `{bits} bits`)
		end
	end,

	["random rotations at 9 bits stay within the worst error found"] = function()
		math.randomseed(9)
		for _ = 1, RANDOM_ROTATIONS do
			local value = randomRotation()
			local flag, index, a, b, c = Leaves.rotationCodes(value, 9)
			local x, y, z, w = Quant.unrotation(flag :: number, index, a, b, c, 9)
			local rotated = CFrame.new(0, 0, 0, x :: number, y, z, w)
			local _, angle = value:ToObjectSpace(rotated):ToAxisAngle()
			Check.expect(math.deg(angle) <= MAX_ERROR_9_BITS, `error {math.deg(angle)}°`)
		end
	end,
}
