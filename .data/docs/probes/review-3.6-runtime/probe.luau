--!nocheck
-- Claim 1: server decode CPU per inbound byte, by payload shape, on the milestone build (f1fbfd7:src, exported
-- next to this file by run.sh, with inbound.luau's local decodeUp/decodingOf/process exposed by run.sh's sed) and
-- on a generated decoder (gen_decoders.luau, from gen.py) over the same frames.
--
-- Frames are built with the milestone's own encoder pieces (Run.encode, Frame.up, Tag.compute, Tag.append) for a
-- server runtime assembled here (no Roblox host: os.clock, no listeners, no validators). Per frame, cases:
--   D   milestone decode: Frame.open + decodeUp (header, toc, every run, a Received table per message)
--   DP  D + process (v5.md §6.1 step 5 with no limit/validator/listener: counters, unresolved, limit, deliver)
--   F   Inbound.receive end to end: shape, frame and byte buckets, tag matched at the expected count, D, process
--   G   generated decode (header, toc, runs, values into flat arrays; tag not checked)
-- Each round runs every case once over the same batch of frames, after a warm-up; 11 rounds; median and min-max
-- ns per frame. Run (from WORK_DIR): luau -O2 decode_shapes.luau   and   luau -O2 --codegen decode_shapes.luau

local Lync = require("./src")
local Bits = require("./src/wire/bits")
local Ints = require("./src/wire/ints")
local Run = require("./src/codec/run")
local Frame = require("./src/transport/frame")
local Tag = require("./src/transport/tag")
local Inbound = require("./src/session/inbound")
local Connection = require("./src/session/connection")
local Handshake = require("./src/session/handshake")
local Replay = require("./src/session/replay")
local Counters = require("./src/diag/counters")
local Console = require("./src/diag/console")
local Facts = require("./src/diag/facts")

local t = Lync.types
local ROUNDS = 11
local TARGET = 0.04 -- seconds per case per round


local fieldsA = {}
for i = 1, 64 do fieldsA[string.format("a%02d", i)] = t.array(t.bool(), 255) end
local fieldsM = {}
for i = 1, 32 do fieldsM[string.format("m%02d", i)] = t.map(t.int(0, 255), t.bool(), 255) end
local schema = Lync.schema("bench", {
	arr64 = Lync.event({ from = "client", data = fieldsA }),
	map32 = Lync.event({ from = "client", data = fieldsM }),
	big = Lync.event({ from = "client", data = t.string(15900) }),
	bigbuf = Lync.event({ from = "client", data = t.buffer(15900) }),
	ping1 = Lync.event({ from = "client" }),
})
local IR = schema.ir
local GEN_INDEX = {}
-- Server runtime --------------------------------------------------------------------------------------------------

local HUGE = { perSecond = 1e12, burst = 1e12 }
local host = {
	side = "server",
	now = os.clock,
	clock = os.clock,
	entropy32 = function() return math.random(0, 2 ^ 32 - 1) end,
	spawn = function() end,
	report = function(m) error("report: " .. tostring(m)) end,
	warn = function() end,
	players = function() return {} end,
}
local counters = Counters.new()
local console = Console.new(host)
local facts = Facts.new(host, console, counters)
local rt = {
	side = "server",
	host = host,
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
conn.key = Connection.key(0x03020100, 0x07060504)
conn.cover = 16384
conn.isWelcomed = true
conn.hasTagged = true
conn.welcomed[namespace.index] = true
rt.connections[player] = conn
rt.knownPlayers[player] = true

-- wire ids: the client sends upForward[canonical + 1]; the server's readIds is its inverse
local wireOf = {}
local wireToGen = {}
for wire, canonical in namespace.readIds do
	local entry = IR.up[canonical + 1]
	wireOf[entry.definition.name] = wire - 1
	wireToGen[wire] = GEN_INDEX[entry.definition.name]
end

-- Frames ----------------------------------------------------------------------------------------------------------

local function chunkOf(name, values, count)
	local w = Bits.writer()
	Bits.write(w, IR.upWidth, wireOf[name])
	Ints.writeEg(w, count - 1, 0)
	local codec = namespace.definitions[name].ir.data
	if codec ~= nil then
		Run.encode(w, codec, values, count, { list = {}, index = {}, count = 0 }, "bench." .. name .. ":fire", "data")
	end
	return Frame.chunk(namespace.index, 2, w, {})
end

-- runs: { { name, values, count } }; returns `copies` tagged frames with counts (reliable) or seqs (unreliable)
-- 0 .. copies - 1
local function framesOf(lane, runs, copies)
	local chunks = {}
	for _, run in runs do table.insert(chunks, chunkOf(run[1], run[2], run[3])) end
	local out = {}
	for c = 0, copies - 1 do
		local body = Frame.up(lane, if lane == 1 then c else nil, nil, chunks)
		local tc = if GAP == "wrong" then c + 1000 elseif GAP and lane == 0 then 5 * c + 4 else c
		local tag = Tag.compute(conn.key, tc, lane, body, buffer.len(body), 0, conn.cover)
		out[c + 1] = Tag.append(body, tag)
	end
	return out
end


GAP = false
local function median(xs) local c = table.clone(xs) table.sort(c) return c[(#c + 1) // 2] end
local function emptyA() local v = {} for i = 1, 64 do v[string.format("a%02d", i)] = {} end return v end
local function emptyM() local v = {} for i = 1, 32 do v[string.format("m%02d", i)] = {} end return v end
local function listOf(n, make) local v = table.create(n) for i = 1, n do v[i] = make(i) end return v end
local bigs = string.rep("x", 15900)
local SH = {
	{ "header only reliable", 0, {} },
	{ "arr64 x1 (64 empty arrays)", 0, { { "arr64", { emptyA() }, 1 } } },
	{ "arr64 x2", 0, { { "arr64", listOf(2, emptyA), 2 } } },
	{ "arr64 x256 constant", 0, { { "arr64", listOf(256, emptyA), 256 } } },
	{ "map32 x1 (32 empty maps)", 0, { { "map32", { emptyM() }, 1 } } },
	{ "map32 x256 constant", 0, { { "map32", listOf(256, emptyM), 256 } } },
	{ "string 15900 B x1", 0, { { "big", { bigs }, 1 } } },
	{ "buffer 15900 B x1", 0, { { "bigbuf", { buffer.fromstring(bigs) }, 1 } } },
}
local results = {}
for _, gap in { false, true, "wrong" } do
	GAP = gap
	for _, s in SH do
		local lane = s[2]
		local batch = 200
		local frames = framesOf(lane, s[3], batch)
		local bytes = buffer.len(frames[1])
		local r0 = Frame.open(frames[1], false, lane); local d0 = Inbound._decodingOf(rt, conn, lane, {}, 0); r0.budget = 1e12; local rule0 = Inbound._decodeUp(r0, d0); local els = 1e12 - r0.budget
		local function run()
			conn.count = 0; conn.window = Replay.new(); conn.failures = 0
			for i = 1, batch do Inbound.receive(rt, player, lane, frames[i]) end
		end
		-- acceptance check
		local slot = s[3][1] and namespace.definitions[s[3][1][1]].receivedSlot
		if slot and gap ~= "wrong" then
			local before = counters.totals[slot]
			run()
			assert(counters.totals[slot] - before == s[3][1][3] * batch, s[1] .. " refused")
		end
		for _ = 1, 3 do run() end
		local ts = {}
		for _ = 1, 11 do
			collectgarbage("collect")
			local t0 = os.clock()
			for _ = 1, 5 do run() end
			table.insert(ts, (os.clock() - t0) / (5 * batch) * 1e9)
		end
		table.sort(ts)
		print(string.format("%-34s gap=%-5s B=%6d el=%5d rule=%d F=%10.0f ns (%0.f-%0.f)", s[1], tostring(gap), bytes, els, rule0, median(ts), ts[1], ts[#ts]))
	end
end
