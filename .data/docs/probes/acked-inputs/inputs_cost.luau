--!optimize 2
-- `inputs` server CPU: parse one stream chunk of C copies of the busy model's `move6` input
-- (fields 10, 10, 1, 11, 2, 8 bits), first copy absolute, later copies `same:u1`, else a 6-bit mask and
-- the changed fields; every copy rebuilt into six locals, and only indices newer than the newest received
-- written to the stream's ring (a redundant copy is parsed, never stored). Compared with nothing else:
-- the per-frame fixed cost and step 5 per delivered message are v5.md section 6.1's measured figures.
-- Usage: luau -O2 [--codegen] inputs_cost.luau

local W = { 10, 10, 1, 11, 2, 8 }
local buf = buffer.create(4096)
local bitpos = 0
local acc, nacc, pos = 0, 0, 0
local function wbits(v, n)
	acc = bit32.bor(acc, bit32.lshift(v, nacc))
	local t = nacc + n
	if t >= 32 then
		buffer.writeu32(buf, pos, acc)
		pos += 4
		acc = bit32.rshift(v, 32 - nacc)
		nacc = t - 32
	else
		nacc = t
	end
end
local function flushw()
	buffer.writeu32(buf, pos, acc)
	pos += 4
	acc, nacc = 0, 0
end

local function build(C, changeEvery)
	acc, nacc, pos = 0, 0, 0
	local cur = { 500, 500, 0, 512, 1, 100 }
	for f = 1, 6 do
		wbits(cur[f], W[f])
	end
	for c = 2, C do
		if changeEvery > 0 and c % changeEvery == 0 then
			wbits(0, 1)
			wbits(0b000011, 6)
			cur[1] = (cur[1] + 7) % 1001
			cur[2] = (cur[2] + 3) % 1001
			wbits(cur[1], 10)
			wbits(cur[2], 10)
		else
			wbits(1, 1)
		end
	end
	flushw()
end

local ring = buffer.create(64 * 8 * 6)
local function readbits(n) -- n <= 24
	local byte = bit32.rshift(bitpos, 3)
	local v = bit32.extract(buffer.readu32(buf, byte), bitpos % 8, n)
	bitpos += n
	return v
end
local function parse(C, first, newest)
	bitpos = 0
	local a, b, c, d, e, f = readbits(10), readbits(10), readbits(1), readbits(11), readbits(2), readbits(8)
	local stored = 0
	for i = 1, C do
		if i > 1 then
			if readbits(1) == 0 then
				local m = readbits(6)
				if bit32.btest(m, 1) then a = readbits(10) end
				if bit32.btest(m, 2) then b = readbits(10) end
				if bit32.btest(m, 4) then c = readbits(1) end
				if bit32.btest(m, 8) then d = readbits(11) end
				if bit32.btest(m, 16) then e = readbits(2) end
				if bit32.btest(m, 32) then f = readbits(8) end
			end
		end
		local idx = first + i - 1
		if idx > newest then
			local o = (idx % 64) * 48
			buffer.writef64(ring, o, a)
			buffer.writef64(ring, o + 8, b)
			buffer.writef64(ring, o + 16, c)
			buffer.writef64(ring, o + 24, d)
			buffer.writef64(ring, o + 32, e)
			buffer.writef64(ring, o + 40, f)
			stored += 1
		end
	end
	return stored
end

local function bench(fn, reps)
	local best = math.huge
	for _ = 1, 9 do
		local t = os.clock()
		for i = 1, reps do
			fn(i)
		end
		best = math.min(best, os.clock() - t)
	end
	return best / reps
end

for _, C in { 1, 4, 9, 32 } do
	for _, ch in { 0, 3 } do
		build(C, ch)
		-- all copies redundant except the newest one
		local t1 = bench(function(i)
			parse(C, 1000, 1000 + C - 2)
		end, 20000)
		print(string.format("C=%2d %-14s chunk %3d bits: %7.1f ns per chunk, %6.1f ns per copy (1 stored)", C,
			ch == 0 and "unchanged" or "1 in 3 changed", pos * 8, t1 * 1e9, t1 * 1e9 / C))
	end
end
