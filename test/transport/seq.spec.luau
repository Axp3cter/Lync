--!strict

--[=[
	seq.spec

	Sequence extension (v5.md §4.4): a 12-bit seq extends to the value nearest the newest, from
	2047 behind it to 2048 ahead, across wraparound, and never below 0.
]=]

-- Imports -----------------------------------------------------------------------------------------

local Check = require("../support/check")
local Prop = require("../support/prop")
local Seq = require("../../src/transport/seq")

-- Constants ---------------------------------------------------------------------------------------

const SEQ_RANGE = 4096

-- Private -----------------------------------------------------------------------------------------

-- A random integer in [0, max], for ranges past `math.random`'s 32 bits.
local function integerUpTo(max: number): number
	return math.floor(math.random() * (max + 1))
end

-- Tests -------------------------------------------------------------------------------------------

return {
	["extension recovers every value from 2047 behind the newest to 2048 ahead"] = function()
		Prop.check("seq extension", function(size: number)
			local newest = integerUpTo(2 ^ math.min(size, 40)) - 1
			local full = math.max(0, newest + math.random(-2047, 2048))
			return { newest, full }
		end, function(case: { number })
			local newest, full = case[1], case[2]
			Check.expectEqual(Seq.extend(newest, full % SEQ_RANGE), full, "extended")
		end)
	end,

	["extension crosses wraparound both ways"] = function()
		Check.expectEqual(Seq.extend(4095, 0), 4096, "forward over 4096")
		Check.expectEqual(Seq.extend(4096, 4095), 4095, "back over 4096")
		Check.expectEqual(Seq.extend(3 * SEQ_RANGE + 10, 4000), 3 * SEQ_RANGE - 96, "back a cycle")
		Check.expectEqual(Seq.extend(3 * SEQ_RANGE - 10, 20), 3 * SEQ_RANGE + 20, "ahead a cycle")
	end,

	["a value 2048 away extends ahead, 2049 away behind"] = function()
		Check.expectEqual(Seq.extend(5000, (5000 + 2048) % SEQ_RANGE), 7048, "2048 ahead")
		Check.expectEqual(Seq.extend(5000, (5000 + 2049) % SEQ_RANGE), 5000 - 2047, "2047 behind")
		Check.expectEqual(
			Seq.extend(5000, (5000 - 2048) % SEQ_RANGE),
			5000 + 2048,
			"the tie is ahead"
		)
	end,

	["extension is never negative"] = function()
		for seq12 = 0, SEQ_RANGE - 1 do
			Check.expectEqual(Seq.extend(-1, seq12), seq12, `before the first, {seq12}`)
		end
		Check.expectEqual(Seq.extend(10, 4095), 4095, "nearest non-negative")
		Check.expectEqual(Seq.extend(0, 2049), 2049, "nothing lies behind 0")
	end,
}
