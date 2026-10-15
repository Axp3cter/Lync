--!strict

local Check = require("../support/check")
local HalfSipHash = require("../../src/wire/halfsiphash")
local vectors = require("./halfsiphash.vectors")

local function keyOf(): buffer
	local key = buffer.create(8)
	for i = 0, 7 do
		buffer.writeu8(key, i, i)
	end

	return key
end

local function messageOf(length: number, offset: number): buffer
	local message = buffer.create(offset + length + 3)
	for i = 0, length - 1 do
		buffer.writeu8(message, offset + i, i)
	end

	return message
end

local function outputOf(low: number, high: number, outBytes: number): buffer
	local output = buffer.create(outBytes)
	buffer.writeu32(output, 0, low)
	if outBytes == 8 then
		buffer.writeu32(output, 4, high)
	end

	return output
end

return {
	["matches the 64 reference vectors with a 4-byte output"] = function()
		local key = keyOf()
		for i, expected in vectors.four do
			local low, high = HalfSipHash.hash(key, messageOf(i - 1, 0), 0, i - 1, 2, 4, 4)
			Check.expectEqual(high, 0, `vector {i} high`)
			Check.expectBytes(outputOf(low, high, 4), expected)
		end
	end,

	["matches the 64 reference vectors with an 8-byte output"] = function()
		local key = keyOf()
		for i, expected in vectors.eight do
			local low, high = HalfSipHash.hash(key, messageOf(i - 1, 0), 0, i - 1, 2, 4, 8)
			Check.expectBytes(outputOf(low, high, 8), expected)
		end
	end,

	["hashes from an offset"] = function()
		local key = keyOf()
		for i, expected in vectors.eight do
			local low, high = HalfSipHash.hash(key, messageOf(i - 1, 5), 5, i - 1, 2, 4, 8)
			Check.expectBytes(outputOf(low, high, 8), expected)
		end
	end,

	["defaults the initialisation constants to the reference's"] = function()
		local key = keyOf()
		local message = messageOf(13, 0)
		local low, high = HalfSipHash.hash(key, message, 0, 13, 1, 3, 8)
		local lowGiven, highGiven =
			HalfSipHash.hash(key, message, 0, 13, 1, 3, 8, 0x6c796765, 0x74656462)
		Check.expectEqual({ lowGiven, highGiven }, { low, high })

		local lowOther = HalfSipHash.hash(key, message, 0, 13, 1, 3, 4, 1, 2)
		Check.expect(lowOther ~= low, "other constants must change the hash")
	end,

	["gives G6's schema hash"] = function()
		local serialization = buffer.create(37)
		local hex =
			"01 05 00 61 72 65 6e 61 01 00 04 00 63 68 61 74 01 01 01 01 08 00 00 00 00 00 \z
			00 69 40 00 00 00 00 00 00 00 00"
		local i = 0
		for pair in string.gmatch(hex, "%x%x") do
			buffer.writeu8(serialization, i, assert(tonumber(pair, 16), "hex pair"))
			i += 1
		end

		local low, high = HalfSipHash.hash(buffer.create(8), serialization, 0, 37, 2, 4, 8)
		Check.expectBytes(outputOf(low, high, 8), "ab 86 8b 15 cd 9c 16 40")
	end,
}
