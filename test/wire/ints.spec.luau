--!strict

local Bits = require("../../src/wire/bits")
local Check = require("../support/check")
local Golden = require("../support/golden")
local Ints = require("../../src/wire/ints")
local Prop = require("../support/prop")

type Code = { value: number, k: number }

local function streamBitsOf(w: Bits.Writer): string
	local digits = table.create(w.bit) :: { string }
	for i = 0, w.bit - 1 do
		digits[i + 1] = tostring(buffer.readbits(w.buf, i, 1))
	end

	return table.concat(digits)
end

local function writerOfBits(digits: string): Bits.Writer
	local w = Bits.writer()
	for i = 1, #digits do
		Bits.write(w, 1, if string.sub(digits, i, i) == "1" then 1 else 0)
	end

	return w
end

local function randomValue(): number
	local length = math.random(0, 53)
	if length == 0 then
		return 0
	end

	local high = math.random(0, 2 ^ 26 - 1) * 2 ^ 27 + math.random(0, 2 ^ 27 - 1)
	return 2 ^ (length - 1) + high // 2 ^ (54 - length)
end

local function codesOf(size: number): { Code }
	local codes = {}
	for _ = 1, size do
		local value = if math.random() < 0.05 then Ints.MAX else randomValue()
		table.insert(codes, { value = value, k = math.random(0, 15) })
	end

	return codes
end

type Batch = { k: number, values: { number }, maxCode: number, cut: number, tail: string }

local function batchOf(size: number): Batch
	local k = math.random(0, 15)
	local values = {}
	for i = 1, math.random(1, math.min(60, size + 5)) do
		local isSmall = math.random() < 0.7
		values[i] = if isSmall then math.random(0, 2 ^ math.random(0, 12) - 1) else randomValue()
	end

	local maxCode = if math.random() < 0.3 then randomValue() else Ints.MAX
	local cut = if math.random() < 0.3 then math.random(0, 64) else 0
	local tail = string.rep("t", if math.random() < 0.5 then math.random(1, 9) else 0)
	return { k = k, values = values, maxCode = maxCode, cut = cut, tail = tail }
end

-- Reads a batch value by value with Ints.readEg, as Ints.readEgMany must.
local function readOneByOne(r: Bits.Reader, batch: Batch, out: { number }): number
	for i in batch.values do
		local value, rule = Ints.readEg(r, batch.k)
		if value == nil then
			return rule
		end

		if value > batch.maxCode then
			return 2
		end

		out[i] = value
	end

	return 0
end

local function decodedOf(digits: string, k: number): (number?, number)
	return Ints.readEg(Bits.reader(Bits.finish(writerOfBits(digits))), k)
end

return {
	["reproduces G1 (v5 §4.10)"] = function()
		local cases = {
			{ value = 0, k = 0, bits = "1" },
			{ value = 1, k = 0, bits = "010" },
			{ value = 2, k = 0, bits = "011" },
			{ value = 3, k = 0, bits = "00100" },
			{ value = 7, k = 0, bits = "0001000" },
			{ value = 5, k = 2, bits = "01010" },
		}
		local all = Bits.writer()
		for _, case in cases do
			local w = Bits.writer()
			Ints.writeEg(w, case.value, case.k)
			Check.expectEqual(streamBitsOf(w), case.bits, `EG-{case.k} of {case.value}`)
			Check.expectEqual(Ints.egBits(case.value, case.k), #case.bits)
			Ints.writeEg(all, case.value, case.k)
		end
		Check.expectEqual(streamBitsOf(all), Golden.entry("G1").bits)

		local r = Bits.reader(Bits.finish(all))
		for _, case in cases do
			Check.expectEqual({ Ints.readEg(r, case.k) }, { case.value, 0 })
		end
	end,

	["reproduces both halves of G9 (v5 §4.10)"] = function()
		local cases = {
			{ id = "G9a", value = -(2 ^ 52), bits = 107 },
			{ id = "G9b", value = 2 ^ 52 - 1, bits = 105 },
		}
		for _, case in cases do
			local w = Bits.writer()
			Ints.writeEg(w, Ints.zigzag(case.value), 0)
			Check.expectEqual(w.bit, case.bits, case.id)
			local expected = Golden.bytes(Golden.entry(case.id))
			Check.expectEqual(Bits.finish(w), expected, case.id)

			local r = Bits.reader(expected)
			local z, rule = Ints.readEg(r, 0)
			Check.expectEqual(rule, 0, case.id)
			Check.expectEqual(Ints.unzigzag(z :: number), case.value, case.id)
		end
	end,

	["round-trips EG-k for k 0 to 15 and values up to MAX"] = function()
		Prop.check("EG-k round trip", codesOf, function(codes: { Code })
			local w = Bits.writer()
			local totalBits = 0
			for _, code in codes do
				Ints.writeEg(w, code.value, code.k)
				totalBits += Ints.egBits(code.value, code.k)
			end
			Check.expectEqual(w.bit, totalBits, "bits written")

			local r = Bits.reader(Bits.finish(w))
			for i, code in codes do
				Check.expectEqual({ Ints.readEg(r, code.k) }, { code.value, 0 }, `code {i}`)
			end
			Check.expect(Bits.meets(r), "bits must end at the last code")
		end)
	end,

	["reads many EG-k codes as reading each one does, the fallback included"] = function()
		Prop.check("readEgMany", batchOf, function(batch: Batch)
			local w = Bits.writer()
			for _, value in batch.values do
				Ints.writeEg(w, value, batch.k)
			end
			Bits.writeTail(w, batch.tail)
			local bytes = Bits.finish(w)
			local stopByte = math.max(0, buffer.len(bytes) - #batch.tail - batch.cut // 8)

			local single = Bits.reader(bytes, 0, stopByte)
			local singleOut = {}
			local singleRule = readOneByOne(single, batch, singleOut)

			local many = Bits.reader(bytes, 0, stopByte)
			local manyOut = {}
			local manyRule =
				Ints.readEgMany(many, batch.k, #batch.values, manyOut, 1, batch.maxCode)
			Check.expectEqual(manyRule, singleRule, "rule")
			Check.expectEqual(manyOut, singleOut, "values")
			if manyRule == 0 then
				Check.expectEqual(many.bit, single.bit, "cursor")
				Check.expectEqual(manyOut, batch.values, "decoded")
			end
		end, { runs = 2000 })
	end,

	["reads many EG-k codes from an offset into out"] = function()
		local w = Bits.writer()
		for value = 0, 99 do
			Ints.writeEg(w, value * 37, 3)
		end
		local out = { -1, -1 }
		local r = Bits.reader(Bits.finish(w))
		Check.expectEqual(Ints.readEgMany(r, 3, 100, out, 3, Ints.MAX), 0)
		Check.expectEqual(out[1], -1)
		Check.expectEqual(out[2], -1)
		for value = 0, 99 do
			Check.expectEqual(out[value + 3], value * 37)
		end
		Check.expect(Bits.meets(r), "the codes end the bits")
	end,

	["decodes codes that end at the buffer's last bit"] = function()
		for value = 0, 300 do
			for k = 0, 3 do
				local w = Bits.writer()
				Ints.writeEg(w, value, k)
				Check.expectEqual({ decodedOf(streamBitsOf(w), k) }, { value, 0 }, `{value}`)
			end
		end
	end,

	["refuses z > 53"] = function()
		Check.expectEqual(
			{ decodedOf(string.rep("0", 54) .. "1" .. string.rep("0", 54), 0) },
			{ nil, 2 }
		)
		Check.expectEqual({ decodedOf(string.rep("0", 60), 0) }, { nil, 2 })
	end,

	["refuses values above MAX"] = function()
		local maxBits = string.rep("0", 53) .. "1" .. string.rep("0", 53)
		Check.expectEqual({ decodedOf(maxBits, 0) }, { Ints.MAX, 0 })

		local pastMax = string.rep("0", 53) .. "1" .. "1" .. string.rep("0", 52)
		Check.expectEqual({ decodedOf(pastMax, 0) }, { nil, 2 })

		local w = Bits.writer()
		Ints.writeEg(w, 2 ^ 52 - 1, 0)
		Bits.write(w, 2, 0b11)
		Check.expectEqual({ decodedOf(streamBitsOf(w), 2) }, { nil, 2 })
	end,

	["refuses codes cut short"] = function()
		for _, code in
			{ { value = 123_456_789, k = 5 }, { value = Ints.MAX, k = 0 }, { value = 6, k = 0 } }
		do
			local w = Bits.writer()
			Ints.writeEg(w, code.value, code.k)
			local whole = Bits.finish(w)
			for stopByte = 0, buffer.len(whole) - 1 do
				if stopByte * 8 >= w.bit then
					continue
				end

				local r = Bits.reader(whole, 0, stopByte)
				Check.expectEqual(
					{ Ints.readEg(r, code.k) },
					{ nil, 4 },
					`{code.value} cut at byte {stopByte}`
				)
			end
		end

		Check.expectEqual({ Ints.readEg(Bits.reader(buffer.fromstring("\0")), 0) }, { nil, 4 })
	end,

	["measures bit lengths and widths"] = function()
		Check.expectEqual(Ints.bitLength(0), 0)
		Check.expectEqual(Ints.bitLength(1), 1)
		Check.expectEqual(Ints.bitLength(2 ^ 32 - 1), 32)
		Check.expectEqual(Ints.bitLength(2 ^ 32), 33)
		Check.expectEqual(Ints.bitLength(Ints.MAX), 53)
		Check.expectEqual(Ints.bitLength(2 ^ 53), 54)
		Check.expectEqual(Ints.width(1), 0)
		Check.expectEqual(Ints.width(2), 1)
		Check.expectEqual(Ints.width(3), 2)
		Check.expectEqual(Ints.width(4), 2)
		Check.expectEqual(Ints.width(5), 3)
		Check.expectEqual(Ints.width(2 ^ 53), 53)
		Check.expectEqual(Ints.MAX, 2 ^ 53 - 1)
	end,

	["zigzags the t.int() range exactly"] = function()
		Check.expectEqual(Ints.zigzag(0), 0)
		Check.expectEqual(Ints.zigzag(-1), 1)
		Check.expectEqual(Ints.zigzag(1), 2)
		Check.expectEqual(Ints.zigzag(-(2 ^ 52)), 2 ^ 53 - 1)
		Check.expectEqual(Ints.zigzag(2 ^ 52 - 1), 2 ^ 53 - 2)
		for _, v in { 0, -1, 1, -(2 ^ 52), 2 ^ 52 - 1, -12345, 67890 } do
			Check.expectEqual(Ints.unzigzag(Ints.zigzag(v)), v)
		end
	end,
}
