--!strict
-- What telemetry samples look like for unmodified clients (research/checks-telemetry.md, T4). A model, not a
-- device measurement: frame times are drawn per case below; the network is v5.md §9's default (one-way 0.05 s +
-- uniform jitter up to 0.02 s, 5% loss on the unreliable lane); the client flush rule is v5.md §5.1 (flush at
-- PostSimulation once >= 1/60 s has accumulated since the last automatic flush; the accumulator restarts at 0).
-- Parts:
--   A. flush rate and server-side inter-arrival of consecutive frames, per frame-rate case
--   A2. the flush rate under two other readings of the flush rule
--   B. a timer-driven action in unmodified game code (fire every 0.1 s of game time), seen at the server
--   C. aim samples inside an atom window (0.5 s before, 0.25 s after), one sample per frame, with loss
--   D. late frames on the unreliable lane: aim deltas in arrival order against frame-key order
--   E. yaw instability near the poles for a direction codec step (yaw/pitch export)
-- Run: luau -O2 telemetry_samples.luau   (Luau 0.742)
math.randomseed(742)

local function gauss(): number
	local u1 = math.max(math.random(), 1e-12)
	local u2 = math.random()
	return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2)
end

local function stats(xs: { number }): (number, number, number, number, number)
	local n = #xs
	local s, s2 = 0, 0
	for _, x in xs do
		s += x
		s2 += x * x
	end
	local mean = s / n
	local sd = math.sqrt(math.max(0, s2 / n - mean * mean))
	local sorted = table.clone(xs)
	table.sort(sorted)
	local p1 = sorted[math.max(1, math.floor(n * 0.01))]
	local p99 = sorted[math.max(1, math.floor(n * 0.99))]
	return mean, sd, p1, p99, n
end

type Case = { name: string, fps: number, sd: number, spike: number }
-- sd: frame-time noise as a fraction of the frame; spike: share of frames that take twice as long
local CASES: { Case } = {
	{ name = "30 FPS (low-end mobile)", fps = 30, sd = 0.05, spike = 0.03 },
	{ name = "45 FPS (uncapped, GPU-bound)", fps = 45, sd = 0.08, spike = 0.02 },
	{ name = "60 FPS cap, steady", fps = 60, sd = 0.01, spike = 0 },
	{ name = "60 FPS cap, 3% spikes", fps = 60, sd = 0.03, spike = 0.03 },
	{ name = "120 FPS cap", fps = 120, sd = 0.03, spike = 0.01 },
	{ name = "144 FPS cap", fps = 144, sd = 0.03, spike = 0.01 },
	{ name = "240 FPS cap", fps = 240, sd = 0.05, spike = 0.01 },
}

local SECONDS = 600
local LAT, JIT, LOSS = 0.05, 0.02, 0.05

-- frame end times of one client for SECONDS seconds
local function frames(c: Case): { number }
	local out = {}
	local t = 0
	while t < SECONDS do
		local dt = (1 / c.fps) * (1 + c.sd * gauss())
		if math.random() < c.spike then
			dt *= 2
		end
		t += math.max(dt, 0.001)
		table.insert(out, t)
	end
	return out
end

-- v5.md §5.1 flush rule
local function flushes(fr: { number }): { number }
	local out = {}
	local last = 0
	for _, t in fr do
		if t - last >= 1 / 60 then
			table.insert(out, t)
			last = t
		end
	end
	return out
end

print("-- A. consecutive frames: client flush interval and server inter-arrival (unreliable lane, 5% loss)")
print(string.format("%-30s %7s %12s %12s %22s", "case", "Hz", "client ms", "server ms", "server p1..p99 ms"))
local flushSets: { [string]: { number } } = {}
for _, c in CASES do
	local fl = flushes(frames(c))
	flushSets[c.name] = fl
	local ci = {}
	for i = 2, #fl do
		table.insert(ci, (fl[i] - fl[i - 1]) * 1000)
	end
	local arr = {}
	for _, t in fl do
		if math.random() >= LOSS then
			table.insert(arr, t + LAT + JIT * math.random())
		end
	end
	table.sort(arr)
	local si = {}
	for i = 2, #arr do
		table.insert(si, (arr[i] - arr[i - 1]) * 1000)
	end
	local cm, csd = stats(ci)
	local sm, ssd, sp1, sp99 = stats(si)
	print(string.format("%-30s %7.1f %5.2f ± %4.2f %5.2f ± %5.2f %9.2f .. %7.2f", c.name, #fl / SECONDS, cm, csd, sm, ssd, sp1, sp99))
end

print("")
print("-- A2. the same frames under two other readings of the flush rule (flush rate in Hz)")
print("--     carry: accumulator -= 1/60 at each flush, capped at 1/60 so it never sends two in a row")
print("--     slack: flush when >= 0.9/60 s has passed since the last flush")
print(string.format("%-30s %10s %10s %10s", "case", "reset", "carry", "slack"))
for _, c in CASES do
	local fr = frames(c)
	local reset = #flushes(fr)
	local carry, acc, prev = 0, 0, 0
	local slack, last = 0, 0
	for _, t in fr do
		acc = math.min(acc + (t - prev), 2 / 60)
		prev = t
		if acc >= 1 / 60 then
			carry += 1
			acc = math.min(acc - 1 / 60, 1 / 60)
		end
		if t - last >= 0.9 / 60 then
			slack += 1
			last = t
		end
	end
	print(string.format("%-30s %10.1f %10.1f %10.1f", c.name, reset / SECONDS, carry / SECONDS, slack / SECONDS))
end

print("")
print("-- B. game code firing every 0.1 s of game time (if now - last >= 0.1), reliable lane, seen at the server")
print(string.format("%-30s %14s %14s %26s", "case", "client ms", "server ms", "distinct client intervals"))
for _, c in CASES do
	local fr = frames(c)
	local fl = flushes(fr)
	-- the action fires in the frame where the timer elapses; it leaves with the next flush at or after that frame
	local fires = {}
	local last = -1
	for _, t in fr do
		if t - last >= 0.1 then
			table.insert(fires, t)
			last = t
		end
	end
	local sends = {}
	local j = 1
	for _, t in fires do
		while j <= #fl and fl[j] < t - 1e-12 do
			j += 1
		end
		if j <= #fl then
			table.insert(sends, fl[j])
		end
	end
	local ci, si = {}, {}
	local prevArr = 0
	local arrs = {}
	for _, t in sends do
		local a = math.max(prevArr, t + LAT + JIT * math.random()) -- reliable: in order
		prevArr = a
		table.insert(arrs, a)
	end
	local distinct: { [number]: number } = {}
	for i = 2, #sends do
		local d = (sends[i] - sends[i - 1]) * 1000
		table.insert(ci, d)
		local key = math.floor(d + 0.5)
		distinct[key] = (distinct[key] or 0) + 1
		table.insert(si, (arrs[i] - arrs[i - 1]) * 1000)
	end
	local keys = {}
	for k, n in distinct do
		if n / #ci >= 0.02 then
			table.insert(keys, k)
		end
	end
	table.sort(keys)
	local shown = {}
	for _, k in keys do
		table.insert(shown, string.format("%d", k))
	end
	local cm, csd = stats(ci)
	local sm, ssd = stats(si)
	print(string.format("%-30s %6.1f ± %5.2f %6.1f ± %5.2f   %s", c.name, cm, csd, sm, ssd, table.concat(shown, " ")))
end

print("")
print("-- C. aim samples per atom window [t - 0.5 s, t + 0.25 s], one sample per frame, unreliable lane")
print(string.format("%-30s %8s %8s %8s %16s", "case", "min", "mean", "max", "largest gap ms"))
for _, c in CASES do
	local fl = flushSets[c.name]
	local arr = {}
	for _, t in fl do
		if math.random() >= LOSS then
			table.insert(arr, t + LAT + JIT * math.random())
		end
	end
	table.sort(arr)
	local mn, mx, sum, n = math.huge, 0, 0, 0
	local gap = 0
	for i = 2, #arr do
		gap = math.max(gap, arr[i] - arr[i - 1])
	end
	-- 2000 triggers at random times, counted by arrival time
	local lo = 1
	for k = 1, 2000 do
		local t = 10 + (SECONDS - 20) * k / 2000
		while lo <= #arr and arr[lo] < t - 0.5 do
			lo += 1
		end
		local hi = lo
		while hi <= #arr and arr[hi] <= t + 0.25 do
			hi += 1
		end
		local cnt = hi - lo
		mn = math.min(mn, cnt)
		mx = math.max(mx, cnt)
		sum += cnt
		n += 1
	end
	print(string.format("%-30s %8d %8.1f %8d %16.1f", c.name, mn, sum / n, mx, gap * 1000))
end

print("")
print("-- D. late frames: aim turning at a steady 90 deg/s, 60 FPS steady, unreliable, jitter 0.02 s and 0.05 s")
for _, jit in { 0.02, 0.05 } do
	local fl = flushSets["60 FPS cap, steady"]
	type Arr = { at: number, key: number, yaw: number }
	local arr: { Arr } = {}
	for k, t in fl do
		if math.random() >= LOSS then
			table.insert(arr, { at = t + LAT + jit * math.random(), key = k, yaw = 90 * t })
		end
	end
	table.sort(arr, function(a: Arr, b: Arr): boolean
		return a.at < b.at
	end)
	local backwards, worst = 0, 0
	for i = 2, #arr do
		local d = arr[i].yaw - arr[i - 1].yaw
		if d < 0 then
			backwards += 1
			worst = math.min(worst, d)
		end
	end
	print(string.format("jitter %.2f s: %d of %d deltas in arrival order are negative (%.2f%%), worst %.2f deg; 0 in key order",
		jit, backwards, #arr - 1, 100 * backwards / (#arr - 1), worst))
end

print("")
print("-- E. yaw change caused by one direction step of 0.2369 deg (t.direction(10) worst error), by pitch")
for _, pitch in { 0, 45, 80, 89, 89.9 } do
	-- worst case: the step is sideways (perpendicular to the meridian) at that pitch
	local r = math.rad(pitch)
	local horiz = math.cos(r)
	local stepYaw = math.deg(2 * math.asin(math.min(1, math.sin(math.rad(0.2369) / 2) / math.max(horiz, 1e-12))))
	print(string.format("pitch %5.1f deg: yaw moves by up to %7.3f deg", pitch, stepYaw))
end
