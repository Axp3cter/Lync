-- review-2 n1: numeric edges of the §3.3 single-row codecs, run on the Luau VM (doubles).
-- (a) t.int(): "any integer with |v| <= 2^53", zigzag then Exp-Golomb. Is the zigzag value exact?
local function zigzag(v: number): number
	return if v >= 0 then 2 * v else -2 * v - 1
end
local function unzigzag(z: number): number
	return if z % 2 == 0 then z / 2 else -(z + 1) / 2
end
for _, v in { 2 ^ 52, -(2 ^ 52), 2 ^ 52 + 1, -(2 ^ 52 + 1), 2 ^ 53 - 1, -(2 ^ 53 - 1), -(2 ^ 53) } do
	local back = unzigzag(zigzag(v))
	print(string.format("t.int() v=%.0f zigzag=%.0f roundtrip=%.0f %s", v, zigzag(v), back, if back == v then "ok" else "WRONG"))
end
-- (b) t.number(min, max, step): steps = floor((max - min)/step); q = floor((v - min)/step + 0.5).
-- Is q ever past the last step for an in-range v (rule 3 would refuse an honest value)?
local cases = {
	{ -2048, 2048, 0.1 }, { 0, 1, 0.1 }, { 0, 100, 0.01 }, { -1, 1, 0.001 }, { 0, 0.3, 0.1 }, { 0, 1, 1 / 3 },
	{ 0, 0.7, 0.1 }, { 0, 2.3, 0.1 }, { -512, 512, 0.05 },
}
for _, c in cases do
	local min, max, step = c[1], c[2], c[3]
	local steps = math.floor((max - min) / step)
	local q = math.floor((max - min) / step + 0.5)
	print(string.format("t.number(%g, %g, %g): last step %d, q(max) %d %s; decode(q(max)) = %.17g",
		min, max, step, steps, q, if q > steps then "PAST LAST STEP -> refused by rule 3" else "ok", min + math.min(q, steps) * step))
end
