--!nocheck
-- Claim 2: c_f and c_b per lane at every accepted position and with every candidate hashed, the instance-list walk,
-- and the untagged HELLO path, on the milestone server's receive path (Inbound.receive), ns per frame, median
-- (min-max) over ROUNDS rounds. Every key state has no pending key (v5.md §4.5 now hashes at most 5 and 3 times at
-- any key state; the milestone hashes twice that with a pending key, noted in RESULTS.md).
--   A  reliable: a t.string(15900) or t.buffer(15900) event of 0-15,900 B, tag accepted at e, e+1 .. e+4 (1-5
--      hashes, then the decode), and failing (5 hashes, no decode)
--   B  unreliable: a t.string(955) event of 0-955 B, the replay window's newest at 10,000 so all three extensions
--      are hashed: accepted at the first (1 hash), refused as replayed at the second (2), accepted at the third (3),
--      failing (3)
--   C  the instance-list walk: frames whose list has 0-16,384 entries, refused at the byte bucket (unreliable: the
--      milestone hashes nothing; reliable: it hashes 5 times, a milestone deviation from §6.1), refused at the frame
--      bucket, and Inbound._instanceCountOf alone
--   D  HELLO rows: untagged frames before the first tagged one (decoded, then 5 hashes when not canonical), valid
--      untagged HELLO frames, and tagged frames carrying HELLO control rows; Handshake.untagged alone
-- Run from WORK_DIR: luau -O2 tag_cost.luau   and   luau -O2 --codegen tag_cost.luau

local Lync = require("./src")
local M = {
	Bits = require("./src/wire/bits"), Ints = require("./src/wire/ints"), Run = require("./src/codec/run"),
	Frame = require("./src/transport/frame"), Tag = require("./src/transport/tag"),
	Connection = require("./src/session/connection"), Handshake = require("./src/session/handshake"),
	Counters = require("./src/diag/counters"), Console = require("./src/diag/console"),
	Facts = require("./src/diag/facts"), Column = require("./src/wire/column"),
}
local Inbound = require("./src/session/inbound")
local Replay = require("./src/session/replay")
local Buckets = require("./src/session/buckets")
local Control = require("./src/transport/control")
local State = require("./src/session/state")
local R = require("./rbx_fast")
math.randomseed(7)
local S = require("./shapes")(Lync, R)
local IR = S.schema.ir
local C = require("./common")(M, IR)
local Frame, Tag, Bits, Handshake = M.Frame, M.Tag, M.Bits, M.Handshake
local rt, conn, player = C.rt, C.conn, C.player

local ROUNDS = 7
local TARGET = 0.02
local BATCH = 64

local function median(xs)
	local c = table.clone(xs)
	table.sort(c)
	return c[(#c + 1) // 2], c[1], c[#c]
end

-- times fn(i) for i = 1..batch, `prepare()` once before each pass (not timed separately; it is the state reset)
local function timeIt(prepare, fn, batch)
	local function pass()
		prepare()
		for i = 1, batch do fn(i) end
	end
	local t0 = os.clock()
	pass()
	local dt = os.clock() - t0
	local passes = math.max(1, math.ceil(TARGET / math.max(dt, 1e-6)))
	for _ = 1, math.min(passes, 3) do pass() end
	local ts = {}
	for _ = 1, ROUNDS do
		collectgarbage("collect")
		local t1 = os.clock()
		for _ = 1, passes do pass() end
		table.insert(ts, (os.clock() - t1) / (passes * batch) * 1e9)
	end
	return median(ts)
end

local function report(fmt, ...)
	local args = table.pack(...)
	local m, lo, hi = args[args.n - 2], args[args.n - 1], args[args.n]
	print(string.format(fmt, table.unpack(args, 1, args.n - 3)) .. string.format(" F=%.0f %.0f %.0f", m, lo, hi))
end

local function resetConn()
	conn.count = 0
	conn.window = Replay.new()
	conn.failures = 0
	conn.pendingKey = nil
	conn.hasTagged = true
end
local HUGE = C.HUGE
local function setBuckets(lane, frameTokens, byteTokens)
	local now = os.clock()
	conn.buckets[lane * 2 + 1] = Buckets.new(if frameTokens then 0 else HUGE.perSecond, frameTokens or HUGE.burst, now)
	conn.buckets[lane * 2 + 2] = Buckets.new(if byteTokens then 0 else HUGE.perSecond, byteTokens or HUGE.burst, now)
end

local function bodyOf(lane, seq12, name, value)
	local chunks = if name then { C.chunkOf(name, { value }, 1) } else {}
	return (Frame.up(lane, seq12, nil, chunks))
end
local function tagged(body, count, lane, ic)
	return Tag.append(body, Tag.compute(conn.key, count, lane, body, buffer.len(body), ic or 0, conn.cover))
end

-- A. reliable lane ------------------------------------------------------------------------------------------------
print("## A reliable")
for _, kind in { "string", "buffer" } do
	for _, len in { 0, 64, 1024, 4096, 15900 } do
		local name = if len == 0 then nil elseif kind == "string" then "big_a" else "bigbuf_a"
		if len == 0 and kind == "buffer" then continue end
		local value = if kind == "string" then string.rep("x", len) else buffer.fromstring(string.rep("x", len))
		local body = bodyOf(0, nil, name, value)
		for position = 0, 5 do
			-- position 0..4: accepted at e + position; 5: failing every candidate
			-- the milestone's 16-bit tag can collide with an earlier candidate's (2^-16 each): frames are tagged from the
			-- count the server will expect, as a sender would, and a failing frame's tag avoids every candidate's
			local len0 = buffer.len(body)
			local function tagAt(count) return Tag.compute(conn.key, count, 0, body, len0, 0, conn.cover) end
			local frames = {}
			local expect = 0
			local candidates = {}
			for k = 0, 4 do candidates[tagAt(k)] = true end
			for i = 0, BATCH - 1 do
				if position == 5 then
					local count = 100000 + i
					while candidates[tagAt(count)] do count += BATCH end
					frames[i + 1] = Tag.append(body, tagAt(count))
				else
					local tag = tagAt(expect + position)
					local at = expect + position
					for k = expect, expect + position - 1 do
						if tagAt(k) == tag then at = k break end
					end
					frames[i + 1] = Tag.append(body, tag)
					expect = at + 1
				end
			end
			local bytes = buffer.len(frames[1])
			-- check acceptance
			resetConn()
			for i = 1, BATCH do Inbound.receive(rt, player, 0, frames[i]) end
			assert(conn.count == expect, "reliable position " .. position)
			report("TAG lane=r kind=%s B=%d pos=%s hashes=%d", kind, bytes, if position == 5 then "fail" else "e+" .. position,
				if position == 5 then 5 else position + 1,
				timeIt(resetConn, function(i)
					conn.failures = 0
					Inbound.receive(rt, player, 0, frames[i])
				end, BATCH))
		end
	end
end

-- B. unreliable lane ----------------------------------------------------------------------------------------------
print("## B unreliable")
local NEWEST = 10000
for _, len in { 0, 64, 256, 955 } do
	local name = if len == 0 then nil else "ustr_a"
	local value = string.rep("y", len)
	for _, position in { "c1", "c2", "c3", "fail" } do
		local frames = {}
		for i = 0, BATCH - 1 do
			local newest, tagSeq
			if position == "c1" then
				newest = NEWEST + i
				tagSeq = newest + 1
			elseif position == "c2" then
				newest = NEWEST
				tagSeq = NEWEST + 1 - 4096
			elseif position == "c3" then
				newest = NEWEST + i * 4097
				tagSeq = newest + 1 + 4096
			else
				newest = NEWEST
				tagSeq = 300000 + i
			end
			local body = bodyOf(1, (newest + 1) % 4096, name, value)
			frames[i + 1] = tagged(body, tagSeq, 1)
		end
		local bytes = buffer.len(frames[1])
		local function prepare()
			resetConn()
			conn.window.newest = NEWEST
		end
		prepare()
		local accepted = 0
		for i = 1, BATCH do
			local before = conn.window.newest
			Inbound.receive(rt, player, 1, frames[i])
			if conn.window.newest ~= before then accepted += 1 end
		end
		-- a 16-bit tag collision with an earlier candidate (2^-16 each) moves a frame to that candidate: allow 2
		local want = if position == "c1" or position == "c3" then BATCH else 0
		assert(math.abs(accepted - want) <= 2, "unreliable " .. position .. " accepted " .. accepted)
		report("TAG lane=u kind=string B=%d pos=%s hashes=%d", bytes, position,
			if position == "c1" then 1 elseif position == "c2" then 2 else 3,
			timeIt(prepare, function(i)
				conn.failures = 0
				Inbound.receive(rt, player, 1, frames[i])
			end, BATCH))
	end
end

-- C. instance-list walk -------------------------------------------------------------------------------------------
print("## C walk")
local INSTANCE = R.newInstance()
for _, n in { 0, 16, 256, 4096, 16384 } do
	local list = table.create(n, INSTANCE)
	for _, lane in { 1, 0 } do
		local body = bodyOf(lane, if lane == 1 then 1 else nil, nil, nil)
		local frame = tagged(body, 1000, lane, n)
		-- refused at the byte bucket
		report("WALK refused=bytes lane=%d entries=%d", lane, n, timeIt(function()
			resetConn()
			setBuckets(lane, nil, 1)
		end, function()
			Inbound.receive(rt, player, lane, frame, list)
		end, BATCH))
		-- refused at the frame bucket
		report("WALK refused=frames lane=%d entries=%d", lane, n, timeIt(function()
			resetConn()
			setBuckets(lane, 0, nil)
		end, function()
			Inbound.receive(rt, player, lane, frame, list)
		end, BATCH))
		setBuckets(lane, nil, nil)
	end
	report("WALK alone entries=%d", n, timeIt(function() end, function()
		Inbound._instanceCountOf(2, buffer.create(1), list)
	end, BATCH))
end

-- D. HELLO rows ---------------------------------------------------------------------------------------------------
print("## D hello")
local function helloOf(name)
	return { version = State.VERSION, seed = State.BUILD_SEED, hashLow = IR.hashLow, hashHigh = IR.hashHigh, name = name }
end
local function helloBody(rows)
	local w = Bits.writer()
	Control.write(w, Control.HELLO, rows)
	return (Frame.up(0, nil, nil, { Frame.chunk(0, 2, w, {}) }))
end
-- the most rows of `name` that fit an untagged reliable frame
local function fillHellos(name, limit)
	local rows = {}
	local n = 0
	while true do
		rows[n + 1] = helloOf(name)
		if buffer.len(helloBody(rows)) > limit then
			rows[n + 1] = nil
			return rows
		end
		n += 1
	end
end
local savedHasTagged = conn.hasTagged
for _, count in { 1, 64, 0 } do
	local rows
	if count == 0 then
		rows = fillHellos("bench", 16384 - 1)
	else
		rows = {}
		for i = 1, count do rows[i] = helloOf("bench") end
	end
	local valid = helloBody(rows)
	local bad = buffer.create(buffer.len(valid) + 1) -- one byte more: the tail no longer meets the bits
	buffer.copy(bad, 0, valid)
	local k = #rows
	-- Handshake.untagged alone
	assert(Handshake.untagged(valid) ~= nil and Handshake.untagged(bad) == nil, "untagged decode")
	report("HELLO untagged-decode valid rows=%d B=%d", k, buffer.len(valid), timeIt(function() end, function()
		Handshake.untagged(valid)
	end, BATCH))
	report("HELLO untagged-decode bad rows=%d B=%d", k, buffer.len(bad), timeIt(function() end, function()
		Handshake.untagged(bad)
	end, BATCH))
	local function prepareUntagged()
		resetConn()
		conn.hasTagged = false
		table.clear(conn.hashByName)
		table.clear(conn.waiting)
	end
	-- a non-canonical untagged frame before the first tagged one: decoded, then 5 failing hashes
	report("HELLO receive untagged-bad hasTagged=false rows=%d B=%d", k, buffer.len(bad), timeIt(prepareUntagged, function()
		conn.failures = 0
		Inbound.receive(rt, player, 0, bad)
	end, BATCH))
	-- the same frame once a tagged frame was accepted: 5 failing hashes only
	report("HELLO receive untagged-bad hasTagged=true rows=%d B=%d", k, buffer.len(bad), timeIt(resetConn, function()
		conn.failures = 0
		Inbound.receive(rt, player, 0, bad)
	end, BATCH))
	-- a valid untagged frame: every HELLO handled (the first answered, the rest repeatedHello)
	report("HELLO receive untagged-valid rows=%d B=%d", k, buffer.len(valid), timeIt(prepareUntagged, function()
		table.clear(conn.hashByName)
		Inbound.receive(rt, player, 0, valid)
	end, BATCH))
	-- tagged frames carrying the same HELLO rows as a control chunk, accepted at e + 4
	if buffer.len(valid) + 2 <= 16384 then
		local frames = {}
		for i = 0, BATCH - 1 do frames[i + 1] = tagged(valid, 5 * i + 4, 0) end
		report("HELLO receive tagged-e4 rows=%d B=%d", k, buffer.len(frames[1]), timeIt(function()
			resetConn()
			table.clear(conn.hashByName)
		end, function(i)
			table.clear(conn.hashByName)
			Inbound.receive(rt, player, 0, frames[i])
		end, BATCH))
	end
end
conn.hasTagged = savedHasTagged
