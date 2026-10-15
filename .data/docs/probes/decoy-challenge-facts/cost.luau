--!strict
--!optimize 2
-- U11 and U14 run-time costs on the server (native) and, for reference, interpreted.
-- (a) reportInteraction: per-viewer decoy lookup, miss (a real key) and hit (evidence built, fact record stand-in).
-- (b) decoy rewind ring: one 24 B slot written per decoy per state tick (same slot as interest-rewind.md §11.2).
-- (c) held(seen): a frozen array of the keys a viewer held (n real + 1 decoy), against an iterator over two
--     prebuilt arrays that allocates nothing.
-- (d) challenges: token draw; the answers-field check per delivered message (nil field, value with no open
--     challenge, value with an open one); the deadline sweep per flush over open challenges.
-- Run: luau -O2 cost.luau   and   luau -O2 --codegen cost.luau   (run.sh does both)

local N = 1_000_000

local function bench(name: string, iters: number, f: (number) -> ())
	local best = math.huge
	for _ = 1, 5 do
		local t0 = os.clock()
		f(iters)
		best = math.min(best, os.clock() - t0)
	end
	print(string.format("%-58s %8.1f ns/op", name, best / iters * 1e9))
end

-- (a) ------------------------------------------------------------------------------------------------------
type DecoyEntry = { addedAt: number, removedAt: number, addTick: number, removeTick: number }
-- per viewer: key -> entry, for live decoys and those removed in the last 2 s
local viewerDecoys: { [number]: DecoyEntry } = {}
for i = 1, 4 do
	viewerDecoys[9_000_000 + i] = { addedAt = 10, removedAt = -1, addTick = 200, removeTick = -1 }
end
local factCount: { [string]: number } = {}
local sink = 0

local function reportInteraction(decoys: { [number]: DecoyEntry }, key: number, kind: number, now: number, p: number)
	local e = decoys[key]
	if e == nil then
		return
	end
	-- evidence: kind, sentAgo, removedAgo, heldAtPerceived
	local sentAgo = now - e.addedAt
	local removedAgo = if e.removedAt < 0 then -1 else now - e.removedAt
	local held = if p < 0 then -1 elseif p >= e.addTick and (e.removeTick < 0 or p < e.removeTick) then 1 else 0
	-- fact record stand-in: one key lookup and increment (v5.md §7.3 gives 20.5 ns native for the real one)
	factCount["decoyInteraction"] = (factCount["decoyInteraction"] or 0) + 1
	sink += sentAgo + removedAgo + held + kind
end

bench("(a) reportInteraction, real key (miss)", N, function(n)
	for i = 1, n do
		reportInteraction(viewerDecoys, 1000 + (i % 64), 1, 12.5, 230.4)
	end
end)
bench("(a) reportInteraction, decoy key (hit, evidence, record)", N, function(n)
	for i = 1, n do
		reportInteraction(viewerDecoys, 9_000_001 + (i % 4), 1, 12.5, 230.4)
	end
end)

-- (b) ------------------------------------------------------------------------------------------------------
local K = 27 -- maxRewind 1 s at 20 Hz (interest-rewind.md §11.7)
local ring = buffer.create(K * 24)
bench("(b) decoy ring push (24 B slot)", N, function(n)
	for i = 1, n do
		local o = (i % K) * 24
		buffer.writeu32(ring, o, i)
		buffer.writef32(ring, o + 4, 1.5)
		buffer.writef32(ring, o + 8, 2.5)
		buffer.writef32(ring, o + 12, 3.5)
		buffer.writeu32(ring, o + 16, 0x1234567)
		buffer.writeu8(ring, o + 20, 1)
	end
end)

-- (c) ------------------------------------------------------------------------------------------------------
local function makeKeys(n: number): { number }
	local t = table.create(n, 0)
	for i = 1, n do
		t[i] = 1000 + i
	end
	return t
end
local decoyKeys = { 9_000_001 }

local function heldArray(real: { number }, decoys: { number }): { number }
	local nr, nd = #real, #decoys
	local out = table.create(nr + nd, 0)
	table.move(real, 1, nr, 1, out)
	table.move(decoys, 1, nd, nr + 1, out)
	return table.freeze(out)
end

for _, n in { 64, 300 } do
	local real = makeKeys(n)
	bench(string.format("(c) held(seen) frozen array, %d real + 1 decoy", n), N // 10, function(m)
		for _ = 1, m do
			local a = heldArray(real, decoyKeys)
			sink += #a
		end
	end)
	bench(string.format("(c) game loop over held keys, %d + 1, whole loop", n), N // 10, function(m)
		for _ = 1, m do
			for _, k in real do
				sink += k
			end
			for _, k in decoyKeys do
				sink += k
			end
		end
	end)
end

-- (d) ------------------------------------------------------------------------------------------------------
math.randomseed(7)
local rand = math.random
bench("(d) token draw, math.random(0, values - 1) stand-in", N, function(n)
	for _ = 1, n do
		sink += rand(0, 9999)
	end
end)

type Open = { token: number, deadline: number, attempts: number, issuedAt: number }
local open: { [number]: Open } = {}
for p = 1, 100 do
	if p % 2 == 0 then
		open[p] = { token = 4242, deadline = 1e9, attempts = 3, issuedAt = 0 }
	end
end
local unsolicited = 0
local function answersCheck(player: number, value: number?, now: number)
	if value == nil then
		return
	end
	local c = open[player]
	if c == nil then
		unsolicited += 1 -- the fact path (unsolicitedAnswer) is a key lookup and increment
		return
	end
	if value == c.token then
		sink += now - c.issuedAt
		c.attempts = 3 -- the probe keeps the challenge open so every iteration takes this path
	else
		c.attempts -= 1
		if c.attempts == 0 then
			c.attempts = 3
		end
	end
end

bench("(d) answers check, field nil", N, function(n)
	for i = 1, n do
		answersCheck(i % 100 + 1, nil, 5)
	end
end)
bench("(d) answers check, value, no open challenge", N, function(n)
	for i = 1, n do
		answersCheck(((i % 50) * 2) + 1, 4242, 5) -- odd players have none open
	end
end)
bench("(d) answers check, value, open challenge (match)", N, function(n)
	for i = 1, n do
		answersCheck(((i % 50) + 1) * 2, 4242, 5)
	end
end)
bench("(d) answers check, value, open challenge (mismatch)", N, function(n)
	for i = 1, n do
		answersCheck(((i % 50) + 1) * 2, 17, 5)
	end
end)

local function sweep(now: number): number
	local closed = 0
	for _, c in open do
		if now >= c.deadline then
			closed += 1
		end
	end
	return closed
end
bench("(d) deadline sweep per flush, 50 open challenges", N // 10, function(n)
	for _ = 1, n do
		sink += sweep(5)
	end
end)

print("sink", sink > 0, "unsolicited", unsolicited > 0)
