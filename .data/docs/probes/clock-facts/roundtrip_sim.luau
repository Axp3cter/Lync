--!strict
-- U4: what `roundTrip` (server os.clock at the answer's decode minus os.clock at the flush that sent the ask) looks
-- like for an unmodified client, against the engine's ping, by client frame rate. Simulated; every engine timing
-- below is an assumption (marked), none is measured on Roblox.
--   server: flushes at its 60 Hz PostSimulation; the engine sends at its next network step, U(0, 1/60) s later
--           (assumption: v5.md §10 lists "whether remotes fired at PostSimulation leave in that frame" as pending);
--   network: one-way = LAT + U(0, JIT) + a stall (prob 0.015, U(0, 0.3) s, reliable retransmission);
--   client: the ask is dispatched at its next frame (period 1/fps); the handler answers after `reaction`;
--           the answer leaves at the first client PostSimulation at or after that with >= 1/60 s since the last
--           flush (v5.md §5.1), assumed in the same frame when the handler returns before PostSimulation;
--   server: decodes at its next 60 Hz step.
--   ping = 2 * LAT + JIT (the engine's "isolated network latency", assumed equal to the mean network round trip
--          without stalls and without frame waits).
-- Prints percentiles of roundTrip - ping (s) and of roundTrip / ping.
-- Run: luau -O2 roundtrip_sim.luau
local LAT, JIT = 0.05, 0.02
local SSTEP = 1 / 60
local TRIALS = 100_000
math.randomseed(23)

local function oneWay(): number
	local d = LAT + math.random() * JIT
	if math.random() < 0.015 then d += math.random() * 0.3 end
	return d
end
local function nextTick(t: number, period: number, phase: number): number
	return phase + math.ceil((t - phase) / period) * period
end
local function q(xs: { number }, p: number): number
	return xs[math.max(1, math.min(#xs, math.floor(p * #xs + 0.5)))]
end
local function lognormal(median: number, sigma: number): number
	local u1, u2 = math.random(), math.random()
	local z = math.sqrt(-2 * math.log(1 - u1)) * math.cos(2 * math.pi * u2)
	return median * math.exp(sigma * z)
end

local ping = 2 * LAT + JIT
local function trial(fps: number, reaction: number): number
	local cstep = 1 / fps
	local cphase = math.random() * cstep
	local flushEvery = math.max(1, math.ceil((1 / 60) / cstep - 1e-9)) -- client frames per flush
	local flushPhase = math.random(0, flushEvery - 1)
	local tFlush = 0
	local sent = tFlush + math.random() * SSTEP
	local arrive = sent + oneWay()
	local dispatch = nextTick(arrive, cstep, cphase)
	local ready = dispatch + reaction
	-- first client frame at or after `ready` that is a flush frame
	local frame = math.ceil((ready - cphase) / cstep - 1e-9)
	while (frame - flushPhase) % flushEvery ~= 0 do frame += 1 end
	local leave = cphase + frame * cstep
	local land = leave + oneWay()
	local decode = math.ceil(land / SSTEP) * SSTEP
	return decode - tFlush
end

print(string.format("ping (assumed) = %.3f s; LAT %.3f, JIT %.3f; %d trials per line", ping, LAT, JIT, TRIALS))
print(string.format("%-36s %8s %8s %8s %8s %8s   %s", "case", "min", "p1", "p50", "p99", "max", "roundTrip/ping p1 / p50"))
for _, case in {
	{ "automatic answer, 30 fps", 30, 0 },
	{ "automatic answer, 60 fps", 60, 0 },
	{ "automatic answer, 144 fps", 144, 0 },
	{ "automatic answer, 240 fps", 240, 0 },
	{ "answer after 1 frame (yield), 60 fps", 60, 1 / 60 },
	{ "human, median 0.35 s, 60 fps", 60, -1 },
	{ "human, median 0.35 s, 30 fps", 30, -1 },
} do
	local name, fps, reaction = case[1] :: string, case[2] :: number, case[3] :: number
	local xs, rs = table.create(TRIALS, 0), table.create(TRIALS, 0)
	for i = 1, TRIALS do
		local r = reaction
		if r < 0 then r = lognormal(0.35, 0.35) end
		local rt = trial(fps, r)
		xs[i] = rt - ping
		rs[i] = rt / ping
	end
	table.sort(xs)
	table.sort(rs)
	print(string.format("%-36s %8.3f %8.3f %8.3f %8.3f %8.3f   %.2f / %.2f", name, xs[1], q(xs, 0.01), q(xs, 0.5), q(xs, 0.99), xs[#xs], q(rs, 0.01), q(rs, 0.5)))
end
