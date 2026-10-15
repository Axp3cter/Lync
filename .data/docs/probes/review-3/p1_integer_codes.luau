-- review-3 p1: draft 3's integer codes implemented literally from v5.md §4.1 and §4.3, in doubles.
-- (a) EG-k as written: v = u + 2^k, n = bit length of v, write n-1-k zeros, a one, low n-1 bits of v;
--     decode: count z zeros, r = u(z+k), return 2^(z+k) + r - 2^k.
local function bitlen(v: number): number
	local n = 0
	while v >= 1 do
		v = math.floor(v / 2)
		n += 1
	end
	return n
end
local function egEncode(u: number, k: number): { number }
	local v = u + 2 ^ k
	local n = bitlen(v)
	local out = {}
	for _ = 1, n - 1 - k do
		table.insert(out, 0)
	end
	table.insert(out, 1)
	local low = v % 2 ^ (n - 1)
	for i = 0, n - 2 do
		table.insert(out, math.floor(low / 2 ^ i) % 2)
	end
	return out
end
local function egDecode(bits: { number }, k: number): number
	local i, z = 1, 0
	while bits[i] == 0 do
		z += 1
		i += 1
	end
	i += 1
	local r = 0
	for j = 0, z + k - 1 do
		r += bits[i + j] * 2 ^ j
	end
	return 2 ^ (z + k) + r - 2 ^ k
end
print("EG-0 round trips (u, decoded, ok)")
for _, u in { 0, 1, 2, 3, 2 ^ 52, 2 ^ 53 - 1, 2 ^ 53 } do
	local d = egDecode(egEncode(u, 0), 0)
	print(string.format("  u=%.0f decoded=%.0f %s", u, d, if d == u then "ok" else "WRONG"))
end
-- t.int() at its cap: zigzag(2^52) = 2^53 is the largest code §3.3 allows.
print(string.format("t.int() v=2^52 -> zigzag %.0f -> EG-0 round trip %.0f", 2 ^ 53, egDecode(egEncode(2 ^ 53, 0), 0)))
-- (b) EG-0 bit strings for small values, written first-to-last (LSB-first stream order)
for _, u in { 0, 1, 2, 3, 4, 7 } do
	print(string.format("  EG-0(%d) = %s", u, table.concat(egEncode(u, 0))))
end
-- (c) §4.3 integer column residual for t.int(): "n = 2^53 + 1" codes, residual wrapped into
--     [-floor((n-1)/2), ceil((n-1)/2)] modulo n.
local n = 2 ^ 53 + 1
print(string.format("n = 2^53 + 1 evaluates to %.0f (%s)", n, if n == 2 ^ 53 then "NOT representable" else "ok"))
local function wrap(d: number, n: number): number
	local lo, hi = -math.floor((n - 1) / 2), math.ceil((n - 1) / 2)
	if d > hi then
		d -= n
	elseif d < lo then
		d += n
	end
	return d
end
-- code = "the value itself" (signed) or zigzag(v)? Try both readings for prev = -2^52, cur = 2^52.
local prev, cur = -(2 ^ 52), 2 ^ 52
local d = wrap(cur - prev, n)
print(string.format("value reading: residual of 2^52 after -2^52 = %.0f; decoder prev + d (mod n) = %.0f",
	d, (prev + d)))
