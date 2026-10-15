--!strict
-- Cost of searching the 32-bit permutation seed when one (canonical id, wire id) pair is known:
-- Fisher-Yates from the last index down puts j = xorshift32(seed) mod n at canonical id n-1 after one step,
-- so a candidate is rejected after one xorshift step with probability (n-1)/n. Times candidates per second.
local bxor, lshift, rshift = bit32.bxor, bit32.lshift, bit32.rshift
local n = 200
local function search(from: number, count: number, want: number): number
	local hits = 0
	for s = from, from + count - 1 do
		local x = s
		x = bxor(x, lshift(x, 13)); x = bxor(x, rshift(x, 17)); x = bxor(x, lshift(x, 5))
		if x % n == want then hits += 1 end
	end
	return hits
end
local N = 2 ^ 24
local t0 = os.clock()
local hits = search(1, N, 17)
local dt = os.clock() - t0
print(string.format("candidates %d, hits %d (expect %.0f), %.2f ns per candidate, full 2^32 space %.1f s", N, hits, N / n, dt / N * 1e9, dt / N * 2 ^ 32))
