--!strict
-- Shared timing harness: best of `runs` batches of `n` calls, minus an empty loop of the same n.
local B = {}

local function time(n: number, fn: () -> ()): number
	local t0 = os.clock()
	for _ = 1, n do
		fn()
	end
	return os.clock() - t0
end

local function empty() end

function B.ns(n: number, fn: () -> (), runs: number?): number
	local best = math.huge
	local base = math.huge
	for _ = 1, runs or 7 do
		best = math.min(best, time(n, fn))
		base = math.min(base, time(n, empty))
	end
	return (best - base) / n * 1e9
end

function B.report(name: string, n: number, fn: () -> (), runs: number?)
	print(string.format("%-44s %9.1f ns", name, B.ns(n, fn, runs)))
end

return B
