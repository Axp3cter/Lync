--!strict
local seedState = 12345
local function nextInt(lo: number, hi: number): number
	seedState = (seedState * 1103515245 + 12345) % 2147483648
	return lo + seedState % (hi - lo + 1)
end
-- Review probes for v5-checks.md draft 3.6. Each part prints what it shows.

-- t.number decode per v5.md §3.3: min(min + q*step, max)
local function decodeNumber(min: number, max: number, step: number, q: number): number
	return math.min(min + q * step, max)
end

print("-- A. maxTotal: S + v > cap on decoded t.number amounts (exact trigger, f64 sums)")
do
	local v = decodeNumber(0, 1, 0.1, 1) -- t.number(0, 1, 0.1), code 1
	local S = 0
	for i = 1, 3 do
		local fails = S + v > 0.3
		print(string.format("  cap 0.3, amount %.17g, S before %.17g: fails=%s", v, S, tostring(fails)))
		if not fails then S += v end
	end
	-- t.number(0, 100, 0.01): coins of 0.01 up to cap 50 (5000 codes)
	local c = decodeNumber(0, 100, 0.01, 1)
	S = 0
	local accepted = 0
	for i = 1, 5000 do
		if S + c > 50 then break end
		S += c
		accepted += 1
	end
	print(string.format("  cap 50, 5000 amounts of 0.01 (exactly the cap): accepted %d, S %.17g", accepted, S))
end

print("-- A2. maxTotal: a running total kept by add/subtract drifts from the bucket sum")
do
	local step = 0.01
	local buckets = table.create(16, 0)
	local total = 0
	local maxDrift = 0
		local k = 0
	for n = 1, 2_000_000 do
		if n % 100 == 0 then -- new bucket every 100 messages
			k += 1
			local i = k % 16 + 1
			total -= buckets[i]
			buckets[i] = 0
		end
		local i = k % 16 + 1
		local v = decodeNumber(0, 100, step, nextInt(0, 10000))
		buckets[i] += v
		total += v
		if n % 1000 == 0 then
			local exact = 0
			for j = 1, 16 do exact += buckets[j] end
			maxDrift = math.max(maxDrift, math.abs(total - exact))
		end
	end
	print(string.format("  2e6 amounts, step 0.01: largest |total - sum(buckets)| = %.3g", maxDrift))
end

print("-- B. derive/within: decoded neighbours vs 'one step' tolerance (equality passes, d > tol fails)")
do
	local function count(min: number, max: number, step: number, n: number)
		local over = 0
		local worst = 0
		for q = 0, n - 1 do
			local a = decodeNumber(min, max, step, q)
			local b = decodeNumber(min, max, step, q + 1)
			local d = math.abs(b - a)
			if not (d <= step) then over += 1; worst = math.max(worst, d - step) end
		end
		print(string.format("  t.number(%g, %g, %g): %d of %d adjacent code pairs have d > step (worst excess %.3g)", min, max, step, over, n, worst))
	end
	count(0, 600, 0.01, 60000)
	count(-1000, 1000, 0.1, 20000)
	count(0, 1, 1e-5, 100000)
end

print("-- C. t.vector3 step 1/32: diagonal neighbour distance vs sqrt(3)*step")
do
	local step = 1 / 32
	local tol = math.sqrt(3) * step
	local over = 0
	local total = 0
		local worst = 0
	for i = 1, 200000 do
		local x = nextInt(-65536, 65535) * step
		local y = nextInt(-65536, 65535) * step
		local z = nextInt(-65536, 65535) * step
		local a = vector.create(x, y, z)
		local b = vector.create(x + step, y + step, z + step)
		local d = vector.magnitude(b - a)
		total += 1
		if not (d <= tol) then over += 1; worst = math.max(worst, d - tol) end
	end
	print(string.format("  vector.magnitude of a (1,1,1)-step neighbour: %.17g; sqrt(3)*step = %.17g", vector.magnitude(vector.create(step, step, step)), tol))
	print(string.format("  %d of %d random diagonal neighbours fail tolerance sqrt(3)*step (worst excess %.3g)", over, total, worst))
	local tolDoc = 0.054
	print(string.format("  docs' rounded 0.054 studs: diagonal neighbour fails = %s", tostring(not (vector.magnitude(vector.create(step, step, step)) <= tolDoc))))
end

print("-- D. derive snap of a zero or NaN direction through the octahedral encoder (v5.md §3.3)")
do
	local function sgn(c: number): number return if c < 0 then -1 else 1 end
	local function encode(x: number, y: number, z: number, bits: number): (number, number)
		local s = math.abs(x) + math.abs(y) + math.abs(z)
		local px, py = x / s, y / s
		if z < 0 then
			px, py = (1 - math.abs(py)) * sgn(px), (1 - math.abs(px)) * sgn(py)
		end
		local m = 2 ^ bits - 1
		return math.floor((px + 1) / 2 * m + 0.5), math.floor((py + 1) / 2 * m + 0.5)
	end
	for _, v in { { 0, 0, 0 }, { 0 / 0, 1, 0 } } do
		local qx, qy = encode(v[1], v[2], v[3], 10)
		print(string.format("  r = (%g, %g, %g): codes (%s, %s); code == itself: %s (E never reaches a fixed point)",
			v[1], v[2], v[3], tostring(qx), tostring(qy), tostring(qx == qx)))
	end
end

print("-- E. monotonic keyed on the reliable tag count across a REKEY (v5.md §4.5: e = 0, client count restarts at 0)")
do
	local sKey, sVal = nil :: number?, nil :: number?
	local function eval(s: number, v: number): (boolean, number)
		if sKey == nil then sKey, sVal = s, v; return false, 0 end
		local late = if s < (sKey :: number) then 1 else 0
		local fails
		if late == 0 then fails = v < (sVal :: number) else fails = v > (sVal :: number) end
		if not fails and late == 0 then sKey, sVal = s, v end
		return fails, late
	end
	-- before the rekey: counts 0..999, seq values 0..999
	for s = 0, 999 do eval(s, s) end
	local f1, f2, stale = 0, 0, 0
	-- after the rekey: counts restart at 0; an unmodified client keeps raising its value 1000..1999
	for s = 0, 999 do local f = eval(s, 1000 + s); if f then f1 += 1 end end
	-- a stale replay of earlier values 0..999 after the rekey
	for s = 1000, 1998 do local f = eval(s - 1000, s - 1000); if not f then stale += 1 end end
	print(string.format("  after REKEY: %d of 1000 rising values fail (late = 1); %d of 999 stale values (<= stored) pass", f1, stale))
end
