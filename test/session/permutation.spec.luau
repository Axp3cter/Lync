--!strict

--[=[
	permutation.spec

	The per-server id permutation (v5.md §4.5): a bijection with its inverse for every seed,
	hash, space and count; seed 0 is the identity; a zero xorshift state is replaced; and the
	spaces of one namespace are shuffled apart. The fixed vector for seed 0x12345678 is in the
	golden index (`golden.spec`).
]=]

-- Imports -----------------------------------------------------------------------------------------

local Check = require("../support/check")
local Permutation = require("../../src/session/permutation")
local Prop = require("../support/prop")

-- Constants ---------------------------------------------------------------------------------------

const U32 = 2 ^ 32 - 1

-- Private -----------------------------------------------------------------------------------------

-- A random integer in [0, max], for ranges past `math.random`'s 32 bits.
local function integerUpTo(max: number): number
	return math.floor(math.random() * (max + 1))
end

-- Tests -------------------------------------------------------------------------------------------

return {
	["a permutation is a bijection on 0 to count - 1, and inverse undoes it"] = function()
		Prop.check("permutation", function(size: number)
			return {
				integerUpTo(U32),
				integerUpTo(U32),
				math.random(1, 3),
				math.random(0, 3 * size),
			}
		end, function(case: { number })
			local count = case[4]
			local forward, inverse = Permutation.build(case[1], case[2], case[3], count)
			Check.expectEqual({ #forward, #inverse }, { count, count }, "lengths")

			local seen = {}
			for canonical = 0, count - 1 do
				local wireId = forward[canonical + 1]
				Check.expect(
					wireId >= 0 and wireId < count and not seen[wireId],
					`wire id {wireId}`
				)
				seen[wireId] = true
				Check.expectEqual(inverse[wireId + 1], canonical, `inverse of {wireId}`)
			end
		end)
	end,

	["seed 0 is the identity for any hash and space"] = function()
		Prop.check("identity", function(size: number)
			return { integerUpTo(U32), math.random(1, 3), math.random(0, 3 * size) }
		end, function(case: { number })
			local forward, inverse = Permutation.build(0, case[1], case[2], case[3])
			local identity = {}
			for i = 1, case[3] do
				identity[i] = i - 1
			end
			Check.expectEqual(forward, identity, "forward")
			Check.expectEqual(inverse, identity, "inverse")
		end)
	end,

	["a zero xorshift state is replaced by 0x9E3779B9"] = function()
		local hashLow, space = 0x0bad_f00d, 2
		local zeroing = bit32.bxor(hashLow, space)
		local replacing = bit32.bxor(0x9E37_79B9, hashLow, space)
		Check.expectEqual(
			{ Permutation.build(zeroing, hashLow, space, 40) },
			{ Permutation.build(replacing, hashLow, space, 40) },
			"permutations"
		)
	end,

	["the seed, the hash and the space each change the permutation"] = function()
		local forward = Permutation.build(0x1234_5678, 0x158b_86ab, 1, 32)
		Check.expect(Permutation.build(0x1234_5679, 0x158b_86ab, 1, 32) ~= forward, "a table each")
		Check.expect(
			table.concat(Permutation.build(0x1234_5679, 0x158b_86ab, 1, 32), ",")
				~= table.concat(forward, ","),
			"seed"
		)
		Check.expect(
			table.concat(Permutation.build(0x1234_5678, 0x158b_86aa, 1, 32), ",")
				~= table.concat(forward, ","),
			"hash"
		)
		Check.expect(
			table.concat(Permutation.build(0x1234_5678, 0x158b_86ab, 2, 32), ",")
				~= table.concat(forward, ","),
			"space"
		)
	end,
}
