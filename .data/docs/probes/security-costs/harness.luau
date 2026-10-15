--!strict
-- Shared timing harness for the security-cost probes.
-- compare(title, iters, cases): cases[1] is the baseline. Each round runs every case once, in order, so drift
-- hits all of them alike; 1 warm-up round, then ROUNDS timed rounds. Prints per case: median, min and max
-- ns per iteration over the rounds, and the median and range of the per-round ratio to the baseline.
local H = {}

H.ROUNDS = 11
H.sink = 0

export type Case = { name: string, fn: (n: number) -> number }

local function median(t: { number }): number
	local c = table.clone(t)
	table.sort(c)
	return c[(#c + 1) // 2]
end

function H.compare(title: string, iters: number, cases: { Case }): { [string]: number }
	local times: { { number } } = {}
	for i = 1, #cases do
		times[i] = {}
		H.sink += cases[i].fn(math.max(1, iters // 4)) -- warm-up
	end
	for _ = 1, H.ROUNDS do
		for i, c in cases do
			local t0 = os.clock()
			H.sink += c.fn(iters)
			table.insert(times[i], (os.clock() - t0) / iters * 1e9)
		end
	end
	print(string.format("## %s (%d iters x %d rounds)", title, iters, H.ROUNDS))
	print(string.format("%-34s %10s %10s %10s %8s %8s %8s", "case", "median ns", "min", "max", "ratio", "rmin", "rmax"))
	local out: { [string]: number } = {}
	for i, c in cases do
		local ratios = {}
		for r = 1, H.ROUNDS do
			table.insert(ratios, times[i][r] / times[1][r])
		end
		table.sort(ratios)
		local t = table.clone(times[i])
		table.sort(t)
		local m = median(t)
		out[c.name] = m
		print(string.format("%-34s %10.2f %10.2f %10.2f %8.2f %8.2f %8.2f", c.name, m, t[1], t[#t], median(ratios), ratios[1], ratios[#ratios]))
	end
	return out
end

return H
