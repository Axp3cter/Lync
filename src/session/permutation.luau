--!strict

--[=[
	Permutation

	The per-server id permutation (v5.md §4.5): for each namespace and id space, both ends shuffle
	the ids with Fisher–Yates from the last index down, drawing j = xorshift32() mod (i + 1).

	xorshift32 is seeded with the server's seed XOR the low 32 bits of the schema hash XOR the
	space number (1 up, 2 down, 3 collections), replaced by 0x9E3779B9 when that is 0. A server
	seed of 0 is the identity, for tests.
]=]

-- Module ------------------------------------------------------------------------------------------

local Permutation = {}

-- Constants ---------------------------------------------------------------------------------------

--- The xorshift32 state used in place of 0, which xorshift32 never leaves.
const ZERO_STATE_REPLACEMENT = 0x9E37_79B9

-- Public ------------------------------------------------------------------------------------------

--[=[
	Builds one id space's permutation.

	@param  seed    the server's permutation seed, a u32; 0 is the identity
	@param  hashLow the low u32 of the namespace's schema hash
	@param  space   1 up, 2 down, 3 collections
	@param  count   how many ids the space has
	@return wire ids by canonical id + 1
	@return canonical ids by wire id + 1
]=]
function Permutation.build(
	seed: number,
	hashLow: number,
	space: number,
	count: number
): ({ number }, { number })
	local forward = table.create(count, 0)
	for i = 1, count do
		forward[i] = i - 1
	end

	if seed ~= 0 then
		local state = bit32.bxor(seed, hashLow, space)
		if state == 0 then
			state = ZERO_STATE_REPLACEMENT
		end

		for i = count - 1, 1, -1 do
			state = bit32.bxor(state, bit32.lshift(state, 13))
			state = bit32.bxor(state, bit32.rshift(state, 17))
			state = bit32.bxor(state, bit32.lshift(state, 5))
			local j = state % (i + 1)
			forward[i + 1], forward[j + 1] = forward[j + 1], forward[i + 1]
		end
	end

	local inverse = table.create(count, 0)
	for canonical = 0, count - 1 do
		inverse[forward[canonical + 1] + 1] = canonical
	end

	return forward, inverse
end

return table.freeze(Permutation)
