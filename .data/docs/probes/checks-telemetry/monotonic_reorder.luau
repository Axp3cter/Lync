--!strict
-- Does `monotonic` fire for an unmodified client on the unreliable lane?
-- Model (v5.md §9 `Net.DEFAULT`): one unreliable frame per 1/60 s, each carrying one message whose field is the
-- frame's own index (a sequence the client never decreases); latency 0.05 s plus uniform jitter [0, jitter);
-- independent loss 5%; frames 64 or more seqs behind the newest received are dropped by the replay window
-- (v5.md §4.5). The server handles arrivals in arrival order.
-- Rule "naive": compare with the last accepted value. Rule "seq": keep (lastSeq, lastValue) of the newest-seq
-- frame; a frame with seq >= lastSeq must have v >= lastValue and replaces it; an older (late) frame must have
-- v <= lastValue and changes nothing.
-- Run: luau -O2 monotonic_reorder.luau
local FRAMES = 1_000_000
local DT = 1 / 60

local function run(jitter: number, loss: number, seed: number)
	local rng = Random.new(seed)
	local arrivals: { { at: number, seq: number } } = {}
	for s = 0, FRAMES - 1 do
		if rng:NextNumber() >= loss then
			table.insert(arrivals, { at = s * DT + 0.05 + rng:NextNumber() * jitter, seq = s })
		end
	end
	table.sort(arrivals, function(a, b)
		return a.at < b.at
	end)
	local newest = -1
	local naiveLast, naiveFail = -math.huge, 0
	local seqLast, seqValue, seqFail = -1, -math.huge, 0
	local late, windowDrops = 0, 0
	for _, a in arrivals do
		if a.seq <= newest - 64 then
			windowDrops += 1
			continue
		end
		newest = math.max(newest, a.seq)
		local v = a.seq -- the field's value: nondecreasing in send order
		if v >= naiveLast then
			naiveLast = v
		else
			naiveFail += 1
		end
		if a.seq >= seqLast then
			if v >= seqValue then
				seqLast, seqValue = a.seq, v
			else
				seqFail += 1
			end
		else
			late += 1
			if v > seqValue then
				seqFail += 1
			end
		end
	end
	print(string.format(
		"jitter %.3f s loss %.2f: %d frames delivered, %d late (%.3f%%), window drops %d; naive failures %d (%.3f%% of frames), seq-aware failures %d",
		jitter, loss, #arrivals - windowDrops, late, 100 * late / #arrivals, windowDrops, naiveFail,
		100 * naiveFail / #arrivals, seqFail
	))
end

-- Random is a Roblox global; the CLI has none, so a small xorshift stand-in is used there.
if (_G :: any).Random == nil then
	local Rand = {}
	Rand.__index = Rand
	function Rand.new(seed: number)
		return setmetatable({ s = seed }, Rand)
	end
	function Rand.NextNumber(self: any): number
		local x = self.s
		x = bit32.bxor(x, bit32.lshift(x, 13))
		x = bit32.bxor(x, bit32.rshift(x, 17))
		x = bit32.bxor(x, bit32.lshift(x, 5))
		self.s = x
		return x / 4294967296
	end
	Random = Rand :: any
end

run(0.02, 0.05, 12345) -- v5.md §9 default network
run(0.02, 0.05, 777)
run(0.05, 0.05, 12345) -- a jittery mobile link (assumed, unmeasured on Roblox)
run(0.0, 0.05, 12345) -- no jitter: no reordering
