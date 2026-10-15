--!nocheck
-- Claim 2: the tag's CPU per frame and per byte on upstream frames of the sizes decode_shapes.luau times, and what
-- the milestone pipeline spends on tags when the tag does not match (the lookahead and the pending key).
--
-- Part A, one tag per frame, frame sizes 3 B .. 16,384 B (cover 16,384, so every byte is covered):
--   M     the milestone's Tag.compute (f1fbfd7 src/transport/tag.luau: scratch copy, then HalfSipHash.hash 1-3/32)
--   Gl    the generated loop form (probes/security-costs/hsip.luau tag13)
--   Gu    the generated unrolled-x4 form (hsip.luau tag13u4)
-- Part B, the milestone's Inbound.receive on frames that do not decode (a wrong tag), per frame:
--   Rbad      reliable, wrong tag, no pending key: counts e .. e + 4 tried (5 hashes), tagMismatch fact
--   RbadP     reliable, wrong tag, a pending key (REKEY unacknowledged): 5 + 5 hashes
--   RoverP    reliable, byte bucket empty, wrong tag, pending key: overBudget fact, then the same 10 hashes
--             (v5.md §6.1 step 2: an over-budget reliable frame is still tag-checked)
--   Ubad      unreliable, wrong tag, no pending key: 3 seq extensions tried (3 hashes)
--   UbadP     unreliable, wrong tag, pending key: 6 hashes
-- failures and the pending key are reset before each frame so the state stays fixed (desync/rekey not timed).
-- Each round runs every case once, after a warm-up; 11 rounds; median and min-max ns per frame.
-- Run (from WORK_DIR): luau -O2 tag_frames.luau   and   luau -O2 --codegen tag_frames.luau

local Lync = require("./src")
local Bits = require("./src/wire/bits")
local Ints = require("./src/wire/ints")
local Run = require("./src/codec/run")
local Frame = require("./src/transport/frame")
local Tag = require("./src/transport/tag")
local Inbound = require("./src/session/inbound")
local Connection = require("./src/session/connection")
local Handshake = require("./src/session/handshake")
local Buckets = require("./src/session/buckets")
local Counters = require("./src/diag/counters")
local Console = require("./src/diag/console")
local Facts = require("./src/diag/facts")
local S = require("./hsip")

local t = Lync.types
local ROUNDS = 11
local TARGET = 0.03

local schema = Lync.schema("bench", {
	text = Lync.event({ from = "client", data = t.string(200) }),
	textu = Lync.event({ from = "client", lane = "unreliable", data = t.string(200) }),
})
local IR = schema.ir

local HUGE = { perSecond = 1e12, burst = 1e12 }
local host = {
	side = "server", now = os.clock, clock = os.clock,
	entropy32 = function() return math.random(0, 2 ^ 32 - 1) end,
	spawn = function() end, report = function(m) error("report: " .. tostring(m)) end, warn = function() end,
	players = function() return {} end,
}
local counters = Counters.new()
local console = Console.new(host)
local facts = Facts.new(host, console, counters)
local rt = {
	side = "server", host = host,
	config = {
		stateRate = 20, stateBudget = 16000, stateFloor = 0.25,
		reliableFrames = HUGE, reliableBytes = HUGE, unreliableFrames = HUGE, unreliableBytes = HUGE, elements = HUGE,
		cover = 16384, window = 30, perPlayerEvents = 16, serverEvents = 256, console = false, profile = false,
	},
	facts = facts, counters = counters, console = console,
	namespaces = {}, namespaceByIndex = {}, permutationSeed = 0, epoch = 0, stateRate = 20,
	connections = {}, knownPlayers = {}, pending = {}, mode = "automatic",
	decodeReportedAt = -math.huge, validatorThread = nil, validatorState = { isRunning = false },
	answer = function() end, control = function() end, slotByName = {}, disconnects = {},
}
local namespace = Handshake.load(rt, IR)
local player = { Name = "p1" }
local conn = Connection.new(rt, player)
local K0, K1 = 0x03020100, 0x07060504
conn.key = Connection.key(K0, K1)
conn.cover = 16384
conn.isWelcomed = true
conn.hasTagged = true
conn.welcomed[namespace.index] = true
rt.connections[player] = conn
local PENDING = Connection.key(0x11111111, 0x22222222)

local wireOf = {}
for wire, canonical in namespace.readIds do
	wireOf[IR.up[canonical + 1].definition.name] = wire - 1
end

-- a frame of `target` bytes (tag included) of strings, with a wrong tag (the right one xor 1)
local function frameOf(lane, target)
	local name = if lane == 1 then "textu" else "text"
	local function build(lengths)
		local chunks = {}
		if #lengths > 0 then
			local w = Bits.writer()
			Bits.write(w, IR.upWidth, wireOf[name])
			Ints.writeEg(w, #lengths - 1, 0)
			local values = {}
			for i, n in lengths do values[i] = string.rep("q", n) end
			Run.encode(w, namespace.definitions[name].ir.data, values, #lengths, { list = {}, index = {}, count = 0 }, "x", "data")
			table.insert(chunks, Frame.chunk(namespace.index, 2, w, {}))
		end
		local body = Frame.up(lane, if lane == 1 then 0 else nil, nil, chunks)
		local tag = Tag.compute(conn.key, 0, lane, body, buffer.len(body), 0, conn.cover)
		return Tag.append(body, bit32.bxor(tag, 1))
	end
	local lengths = {}
	local f = build(lengths)
	while buffer.len(f) < target do
		local short = target - buffer.len(f)
		if #lengths == 0 or lengths[#lengths] == 200 then table.insert(lengths, 0) end
		lengths[#lengths] = math.min(200, lengths[#lengths] + math.max(1, short - 2))
		f = build(lengths)
		while buffer.len(f) > target and lengths[#lengths] > 0 do
			lengths[#lengths] -= 1
			f = build(lengths)
		end
		if buffer.len(f) > target then break end
	end
	return f
end

local function median(xs)
	local c = table.clone(xs)
	table.sort(c)
	return c[(#c + 1) // 2]
end

local function compare(cases, perIter)
	local passes = {}
	for i, c in cases do
		local t0 = os.clock()
		c.fn(perIter)
		local dt = os.clock() - t0
		passes[i] = math.max(1, math.ceil(TARGET / math.max(dt, 1e-6)))
		c.fn(perIter)
	end
	local times = {}
	for i = 1, #cases do times[i] = {} end
	for _ = 1, ROUNDS do
		for i, c in cases do
			collectgarbage("collect")
			local t0 = os.clock()
			for _ = 1, passes[i] do c.fn(perIter) end
			table.insert(times[i], (os.clock() - t0) / (passes[i] * perIter) * 1e9)
		end
	end
	local out = {}
	for i, c in cases do
		local ts = table.clone(times[i])
		table.sort(ts)
		out[c.name] = { median(ts), ts[1], ts[#ts] }
	end
	return out
end

local sink = 0
local function cell(x) return string.format("%9.0f (%6.0f-%6.0f)", x[1], x[2], x[3]) end

-- Part A ----------------------------------------------------------------------------------------------------------
print("## A. one tag per frame (cover 16,384)")
print(string.format("%-6s %6s | %-26s | %-26s | %-26s", "lane", "bytes", "M milestone", "Gl generated loop", "Gu generated unrolled"))
local A = {}
for _, spec in { { 1, 3 }, { 1, 16 }, { 1, 64 }, { 1, 256 }, { 1, 1000 }, { 0, 2 }, { 0, 1024 }, { 0, 4096 }, { 0, 16384 } } do
	local lane, size = spec[1], spec[2]
	local f = frameOf(lane, size)
	local len = buffer.len(f) - 2
	local key = conn.key
	local per = math.max(8, 400000 // (len + 64))
	local r = compare({
		{ name = "M", fn = function(n) local s = 0 for i = 1, n do s += Tag.compute(key, i, lane, f, len, 0, 16384) end sink += s end },
		{ name = "Gl", fn = function(n) local s = 0 for i = 1, n do s += S.tag13(K0, K1, f, len, 16384, i, lane, 0) end sink += s end },
		{ name = "Gu", fn = function(n) local s = 0 for i = 1, n do s += S.tag13u4(K0, K1, f, len, 16384, i, lane, 0) end sink += s end },
	}, per)
	A[#A + 1] = { lane = lane, bytes = buffer.len(f), r = r }
	print(string.format("%-6d %6d | %-26s | %-26s | %-26s", lane, buffer.len(f), cell(r.M), cell(r.Gl), cell(r.Gu)))
end
-- fits: fixed = smallest frame; marginal per byte = slope between the two largest frames of each lane
local function fit(name)
	local u3, u1000, r2, r1024, r16384 = A[1], A[5], A[6], A[7], A[9]
	local slope = (r16384.r[name][1] - r1024.r[name][1]) / (r16384.bytes - r1024.bytes)
	local slopeU = (u1000.r[name][1] - u3.r[name][1]) / (u1000.bytes - u3.bytes)
	print(string.format("fit %-3s fixed %6.0f ns (reliable, %d B frame), %6.0f ns (unreliable, %d B); marginal %6.2f ns/B (reliable 1024..16384), %6.2f ns/B (unreliable 3..1000)",
		name, r2.r[name][1], r2.bytes, u3.r[name][1], u3.bytes, slope, slopeU))
end
fit("M"); fit("Gl"); fit("Gu")

-- Part B ----------------------------------------------------------------------------------------------------------
print("## B. milestone Inbound.receive on frames with a wrong tag (no decode)")
print(string.format("%-6s %6s | %-26s | %-26s | %-26s", "lane", "bytes", "bad tag", "bad tag, pending key", "over byte budget, bad, pending"))
for _, spec in { { 1, 3 }, { 1, 1000 }, { 0, 2 }, { 0, 1024 }, { 0, 16384 } } do
	local lane, size = spec[1], spec[2]
	local f = frameOf(lane, size)
	local per = math.max(8, 20000 // (buffer.len(f) // 64 + 1))
	local empty = Buckets.new(0, 0, os.clock())
	local full = conn.buckets[lane * 2 + 2]
	local cases = {
		{ name = "bad", fn = function(n)
			conn.pendingKey = nil
			for _ = 1, n do conn.failures = 0; conn.count = 0; Inbound.receive(rt, player, lane, f) end
		end },
		{ name = "badP", fn = function(n)
			conn.pendingKey = PENDING
			for _ = 1, n do conn.failures = 0; conn.count = 0; Inbound.receive(rt, player, lane, f) end
			conn.pendingKey = nil
		end },
	}
	if lane == 0 then
		table.insert(cases, { name = "overP", fn = function(n)
			conn.pendingKey = PENDING
			conn.buckets[2] = empty
			for _ = 1, n do conn.failures = 0; conn.count = 0; Inbound.receive(rt, player, lane, f) end
			conn.buckets[2] = full
			conn.pendingKey = nil
		end })
	end
	local r = compare(cases, per)
	print(string.format("%-6d %6d | %-26s | %-26s | %-26s", lane, buffer.len(f), cell(r.bad), cell(r.badP), if r.overP then cell(r.overP) else "-"))
end
print("sink", sink % 7)
