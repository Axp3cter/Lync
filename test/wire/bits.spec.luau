--!strict

local Bits = require("../../src/wire/bits")
local Check = require("../support/check")
local Prop = require("../support/prop")

type Field = { width: number, value: number, tail: string? }

local function random53(): number
	return math.random(0, 2 ^ 26 - 1) * 2 ^ 27 + math.random(0, 2 ^ 27 - 1)
end

local function fieldsOf(size: number): { Field }
	local fields = {}
	for _ = 1, size do
		local width = math.random(0, 53)
		local value = random53() // 2 ^ (53 - width)
		local tail = if math.random() < 0.2 then string.rep("x", math.random(0, 5)) else nil
		table.insert(fields, { width = width, value = value, tail = tail })
	end

	return fields
end

local function writtenOf(fields: { Field }): Bits.Writer
	local w = Bits.writer()
	for _, field in fields do
		Bits.write(w, field.width, field.value)
		if field.tail ~= nil then
			Bits.writeTail(w, field.tail)
		end
	end

	return w
end

return {
	["round-trips fields of random widths 0 to 53 with tail values"] = function()
		Prop.check("bits round trip", fieldsOf, function(fields: { Field })
			local r = Bits.reader(Bits.finish(writtenOf(fields)))
			for i, field in fields do
				Check.expectEqual(Bits.read(r, field.width), field.value, `field {i}`)
				if field.tail ~= nil then
					Check.expectEqual(Bits.readTail(r, #field.tail, false), field.tail, `tail {i}`)
				end
			end
			Check.expect(Bits.meets(r), "bits and tail must meet")
		end)
	end,

	["orders bits least significant first (v5 §4.1)"] = function()
		local w = Bits.writer()
		Bits.write(w, 3, 0b101)
		Bits.write(w, 6, 0b110011)
		Check.expectBytes(Bits.finish(w), "9d 01")
	end,

	["writes 53-bit fields as low bits first"] = function()
		local w = Bits.writer()
		Bits.write(w, 1, 1)
		Bits.write(w, 53, 2 ^ 53 - 1)
		Check.expectBytes(Bits.finish(w), "ff ff ff ff ff ff 3f")
	end,

	["splits a writer into its aligned bits and its reversed tail"] = function()
		local w = Bits.writer()
		Bits.write(w, 5, 0b10110)
		Bits.writeTail(w, "ab")
		Bits.writeTail(w, buffer.fromstring("c"))
		Bits.writeTail(w, "de")
		local bitSection, tailSegment = Bits.parts(w)
		Check.expectBytes(bitSection, "16")
		Check.expectEqual(buffer.tostring(tailSegment), "decab")
		Check.expectBytes(Bits.finish(w), "16 64 65 63 61 62")

		local r = Bits.reader(Bits.finish(w))
		Check.expectEqual(Bits.read(r, 5), 0b10110)
		Check.expectEqual(Bits.readTail(r, 2, false), "ab")
		Check.expectEqual(Bits.readTail(r, 1, true), buffer.fromstring("c"))
		Check.expectEqual(Bits.readTail(r, 2, false), "de")
		Check.expect(Bits.meets(r), "bits and tail must meet")
	end,

	["undoes writes when reset to a mark"] = function()
		local w = Bits.writer()
		Bits.write(w, 7, 0b1010101)
		local markBit = w.bit
		local markTail = #w.tail
		for _ = 1, 100 do
			Bits.write(w, 53, 2 ^ 53 - 1)
		end
		Bits.writeTail(w, "junk")
		w.bit = markBit
		table.remove(w.tail, markTail + 1)
		w.tailBytes = 0
		Check.expectBytes(Bits.finish(w), "55")

		Bits.write(w, 3, 0)
		Check.expectBytes(Bits.finish(w), "55 00")
	end,

	["aligns with zero bits"] = function()
		local w = Bits.writer()
		Bits.write(w, 3, 0b111)
		Bits.align(w)
		Check.expectEqual(w.bit, 8)
		Bits.align(w)
		Check.expectEqual(w.bit, 8)
		Bits.write(w, 1, 1)
		Check.expectBytes(Bits.finish(w), "07 01")
	end,

	["refuses reads past the tail cursor"] = function()
		local r = Bits.reader(buffer.fromstring("\xff\xff\xff"), 0, 2)
		Check.expectEqual(Bits.read(r, 10), 0x3ff)
		Check.expectEqual(Bits.read(r, 7), nil)
		Check.expectEqual(Bits.read(r, 6), 0x3f)
		Check.expectEqual(Bits.read(r, 0), 0)
		Check.expectEqual(Bits.read(r, 1), nil)
	end,

	["refuses a tail value that overlaps the bits read"] = function()
		local r = Bits.reader(buffer.fromstring("\x01ab"))
		Check.expectEqual(Bits.read(r, 1), 1)
		Check.expectEqual(Bits.readTail(r, 3, false), nil)
		Check.expectEqual(Bits.readTail(r, 2, false), "ab")
		Check.expectEqual(Bits.readTail(r, 0, false), "")
		Check.expectEqual(Bits.readTail(r, 1, false), nil)
		Check.expect(Bits.meets(r), "bits and tail must meet")
	end,

	["reports non-zero padding"] = function()
		local r = Bits.reader(buffer.fromstring("\x03\x00"))
		Check.expectEqual(Bits.read(r, 1), 1)
		Check.expect(not Bits.meets(r), "a padding bit is 1")
		Check.expect(not Bits.readAlign(r), "a padding bit is 1")
		Check.expectEqual(r.bit, 8)
		Check.expect(Bits.readAlign(r), "already aligned")
		Check.expectEqual(Bits.read(r, 8), 0)
		Check.expect(Bits.meets(r), "bits and tail must meet")
	end,

	["reports bits and tail that do not meet"] = function()
		local r = Bits.reader(buffer.fromstring("\x01\x00"))
		Check.expectEqual(Bits.read(r, 1), 1)
		Check.expect(not Bits.meets(r), "a whole byte lies between bits and tail")
	end,

	["reads from a start byte to a stop byte"] = function()
		local r = Bits.reader(buffer.fromstring("\xaa\x05\x06\xbb"), 1, 3)
		Check.expectEqual(Bits.read(r, 16), 0x0605)
		Check.expect(Bits.meets(r), "bits must end at the stop byte")
	end,

	["charges elements until the budget runs out"] = function()
		local r = Bits.reader(buffer.create(1), nil, nil, 10)
		Check.expectEqual(r.budget, 10)
		Check.expect(Bits.charge(r, 4), "4 of 10")
		Check.expect(Bits.charge(r, 6), "exactly the budget leaves 0")
		Check.expectEqual(r.budget, 0)
		Check.expect(Bits.charge(r, 0), "a zero count at 0 still fits")
		Check.expect(not Bits.charge(r, 1), "one past the budget")
		Check.expect(not Bits.charge(r, 0), "a spent budget stays spent")

		local zero = Bits.reader(buffer.create(1), 0, 1, 0)
		Check.expect(not Bits.charge(zero, 1), "a zero budget refuses one element")
	end,

	["never runs out of the default budget"] = function()
		local r = Bits.reader(buffer.create(1))
		Check.expectEqual(r.budget, math.huge)
		for _ = 1, 1000 do
			Check.expect(Bits.charge(r, 2 ^ 53), "the default allowance is unlimited")
		end
		Check.expectEqual(r.budget, math.huge)
	end,
}
