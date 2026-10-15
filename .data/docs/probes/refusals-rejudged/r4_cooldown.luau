--!strict
-- R35 `cooldown`: what v5.md §5.4's server `limit` bucket admits when a game writes a cooldown of s seconds as
-- limit = { perSecond = 1/s, burst = 1 }. Bucket rules from §5.4: starts full; tokens = min(capacity, tokens +
-- rate * elapsed) on each use; capacity = burst + 2 s * perSecond; a message needs 1 token (overLimit below 1).
-- Also: `within` with a planar reference equals the planar distance exactly.
local function admit(s: number, times: { number }): { boolean }
	local rate, cap = 1 / s, 1 + 2 / s
	local tokens, last = cap, 0
	local out = {}
	for i, t in times do
		tokens = math.min(cap, tokens + rate * (t - last))
		last = t
		if tokens >= 1 then tokens -= 1; out[i] = true else out[i] = false end
	end
	return out
end
for _, s in { 0.5, 1, 2, 5, 10, 30 } do
	-- burst after idle: messages every 1 ms until one is refused
	local times = {}
	for i = 1, 200 do times[i] = 1000 + i * 0.001 end
	local r = admit(s, times)
	local n = 0
	while n < #r and r[n + 1] do n += 1 end
	-- smallest gap admitted after one message, steady state: message at 0 (full bucket), then probe gaps
	local gap = 0
	for g = 0, 60, 0.001 do
		local ok = admit(s, { 1000, 1000 + g })
		if ok[2] then gap = g; break end
	end
	print(string.format("cooldown %5.1f s: admitted at once after idle %d (1 + 2/s = %.2f); second message admitted after %.3f s (s - 2 = %.1f)",
		s, n, 1 + 2 / s, gap, math.max(0, s - 2)))
end
local v = vector.create(3.25, 17.5, -8.125)
local r = vector.create(1, 2, 3)
local planarRef = vector.create(r.x, v.y, r.z)
local a = vector.magnitude(v - planarRef)
local b = vector.magnitude(vector.create(v.x - r.x, 0, v.z - r.z)) -- planar distance in the same f32 vector math
local c = math.sqrt((v.x - r.x) ^ 2 + (v.z - r.z) ^ 2) -- f64, for scale
print("within with reference (r.x, v.y, r.z):", a, "planar distance (vector, f32):", b, "equal:", a == b, "f64:", c)
-- the same over 10^6 random pairs
local same = 0
for i = 1, 1_000_000 do
	local p = vector.create(math.random() * 4096 - 2048, math.random() * 512, math.random() * 4096 - 2048)
	local q = vector.create(math.random() * 4096 - 2048, math.random() * 512, math.random() * 4096 - 2048)
	if vector.magnitude(p - vector.create(q.x, p.y, q.z)) == vector.magnitude(vector.create(p.x - q.x, 0, p.z - q.z)) then same += 1 end
end
print("random pairs with equal planar distance by both forms:", same, "of 1000000")
