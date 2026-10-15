-- Design draft 3: the t.number step-count rule (§3.3) against review-2 n1's failing cases.
-- steps = round(r) when |r - round(r)| <= 1e-9 * max(1, r), else floor(r), with r = (max - min) / step.
-- Encode: q = min(floor((v - min) / step + 0.5), steps). Checks every v = min + i*step and max itself.
local function steps(min: number, max: number, step: number): number
	local r = (max - min) / step
	local n = math.round(r)
	return if math.abs(r - n) <= 1e-9 * math.max(1, r) then n else math.floor(r)
end
local cases = {
	{ -2048, 2048, 0.1 }, { 0, 1, 0.1 }, { 0, 100, 0.01 }, { -1, 1, 0.001 }, { 0, 0.3, 0.1 },
	{ 0, 1, 1 / 3 }, { 0, 0.7, 0.1 }, { 0, 2.3, 0.1 }, { -512, 512, 0.05 }, { 0, 1, 0.3 },
}
for _, c in cases do
	local min, max, step = c[1], c[2], c[3]
	local n = steps(min, max, step)
	local worst = 0
	for i = 0, n do
		local v = math.min(min + i * step, max)
		local q = math.min(math.floor((v - min) / step + 0.5), n)
		worst = math.max(worst, math.abs(min + q * step - v))
	end
	local qmax = math.min(math.floor((max - min) / step + 0.5), n)
	print(string.format("t.number(%g, %g, %g): steps %d, bits %d, q(max) %d, max error at grid points %.3g",
		min, max, step, n, math.ceil(math.log(n + 1, 2)), qmax, worst))
end
