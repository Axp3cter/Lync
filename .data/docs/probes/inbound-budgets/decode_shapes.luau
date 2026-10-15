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
local G = require("./gen_decoders")

local t = Lync.types
local ROUNDS = 11
local TARGET = 0.03 -- seconds per case per round

-- Schema ----------------------------------------------------------------------------------------------------------

local move6 = { a = t.int(0, 1000), b = t.int(0, 1000), c = t.bool(), d = t.number(0, 1, 1 / 1024), e = t.enum({ "x", "y", "z" }), f = t.int(0, 255) }
local bools = {}
for i = 1, 32 do bools[string.format("b%02d", i)] = t.bool() end

local schema = Lync.schema("bench", {
	move6 = Lync.event({ from = "client", lane = "unreliable", data = move6 }),
	move6r = Lync.event({ from = "client", data = move6 }),
	sm = Lync.event({ from = "client", data = { item = t.enum({ "sword", "bow", "staff" }), name = t.string(32), qty = t.int(1, 99), slot = t.optional(t.int(0, 15)) } }),
	bools32 = Lync.event({ from = "client", data = bools }),
	ping1 = Lync.event({ from = "client" }),
	ping2 = Lync.event({ from = "client" }),
	text = Lync.event({ from = "client", data = t.string(200) }),
	arrBool = Lync.event({ from = "client", data = t.array(t.bool(), 65535) }),
	arrRec = Lync.event({ from = "client", data = t.array({ a = t.bool() }, 65535) }),
})
local IR = schema.ir
local GEN_INDEX = { move6 = 1, move6r = 2, sm = 3, bools32 = 4, ping1 = 5, ping2 = 6 }

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
		local tag = Tag.compute(conn.key, c, lane, body, buffer.len(body), 0, conn.cover)
		out[c + 1] = Tag.append(body, tag)
	end
	return out
end

math.randomseed(7)
local function randomMove6()
	return { a = math.random(0, 1000), b = math.random(0, 1000), c = math.random() < 0.5, d = math.random(0, 1024) / 1024, e = ({ "x", "y", "z" })[math.random(1, 3)], f = math.random(0, 255) }
end
local LETTERS = "abcdefghijklmnopqrstuvwxyz"
local function randomName(n)
	local s = table.create(n)
	for i = 1, n do local k = math.random(1, 26); s[i] = string.sub(LETTERS, k, k) end
	return table.concat(s)
end
local function randomSm()
	return { item = ({ "sword", "bow", "staff" })[math.random(1, 3)], name = randomName(8), qty = math.random(1, 99), slot = if math.random() < 0.5 then math.random(0, 15) else nil }
end
local function boolsOf(random)
	local v = {}
	for i = 1, 32 do v[string.format("b%02d", i)] = if random then math.random() < 0.5 else false end
	return v
end
local function listOf(n, make)
	local v = table.create(n)
	for i = 1, n do v[i] = make(i) end
	return v
end

-- the largest count whose single-run frame fits `limit` bytes (frame including the 2-byte tag)
local function fill(lane, name, make, limit)
	local lo, hi = 1, 1
	local pool = listOf(70000, make)
	local function size(n) return buffer.len(framesOf(lane, { { name, pool, n } }, 1)[1]) end
	while size(hi) <= limit do lo = hi; hi *= 2 end
	while hi - lo > 1 do
		local mid = (lo + hi) // 2
		if size(mid) <= limit then lo = mid else hi = mid end
	end
	return pool, lo
end

-- Timing ----------------------------------------------------------------------------------------------------------

local function median(xs)
	local c = table.clone(xs)
	table.sort(c)
	return c[(#c + 1) // 2]
end

local function decodeMilestone(frame, lane)
	local r = Frame.open(frame, false, lane)
	local d = Inbound._decodingOf(rt, conn, lane, {}, 0)
	r.budget = 1e12
	local rule = Inbound._decodeUp(r, d)
	return rule, d, 1e12 - r.budget
end

local SHAPES = {}
local function shape(name, lane, runs, note)
	table.insert(SHAPES, { name = name, lane = lane, runs = runs, note = note })
end

shape("empty unreliable frame (header only)", 1, {}, "fixed cost")
shape("empty reliable frame (header only)", 0, {}, "fixed cost")
shape("busy input: 1 move6, unreliable", 1, { { "move6", { randomMove6() }, 1 } }, "busy")
shape("busy action: 1 sm (8-byte name), reliable", 0, { { "sm", { randomSm() }, 1 } }, "busy")
do
	local pool, n = fill(1, "move6", randomMove6, 1000)
	shape(string.format("move6 x %d random, unreliable 1000 B", n), 1, { { "move6", pool, n } }, "dense")
	local poolR, nR = fill(0, "move6r", randomMove6, 16384)
	shape(string.format("move6 x %d random, reliable 16 KB", nR), 0, { { "move6r", poolR, nR } }, "dense")
	local poolB, nB = fill(0, "bools32", function() return boolsOf(true) end, 16384)
	shape(string.format("bools32 x %d random, reliable 16 KB", nB), 0, { { "bools32", poolB, nB } }, "dense 1-bit")
	local poolT, nT = fill(0, "text", function() return randomName(200) end, 16384)
	shape(string.format("text (200 B strings) x %d, reliable 16 KB", nT), 0, { { "text", poolT, nT } }, "strings")
end
shape("bools32 x 4096 all false (constant columns)", 0, { { "bools32", listOf(4096, function() return boolsOf(false) end), 4096 } }, "element-bound")
do
	local runs = {}
	for i = 1, 4096 do table.insert(runs, { if i % 2 == 1 then "ping1" else "ping2", {}, 1 }) end
	shape("4096 one-message runs, ping1/ping2 alternating", 0, runs, "element-bound")
end
shape("array(bool, 65535) all false (R31 row 1)", 0, { { "arrBool", { table.create(65535, false) }, 1 } }, "amplification")
shape("array({a = bool}, 65535) all false (R31 row 2)", 0, { { "arrRec", { listOf(65535, function() return { a = false } end) }, 1 } }, "amplification")

local function deepEqual(a, b)
	if type(a) ~= "table" or type(b) ~= "table" then return a == b end
	for k, v in a do if not deepEqual(v, b[k]) then return false end end
	for k in b do if a[k] == nil then return false end end
	return true
end

print(string.format("%-50s %4s %6s %6s %7s | %-24s | %-24s | %-24s | %-24s | %8s %8s %8s %8s",
	"frame", "lane", "bytes", "msgs", "elems", "D ns/frame (min-max)", "DP", "F", "G", "F ns/B", "G ns/B", "F ns/el", "G ns/el"))

local results = {}
for _, s in SHAPES do
	local lane = s.lane
	local probe = framesOf(lane, s.runs, 1)[1]
	local bytes = buffer.len(probe)
	-- correctness: milestone decode, generated decode, full receive
	local rule, d, elements = decodeMilestone(probe, lane)
	assert(rule == 0, s.name .. ": milestone rule " .. rule)
	local msgs = #d.received
	local hasGen = true
	for _, run in s.runs do if GEN_INDEX[run[1]] == nil then hasGen = false end end
	if hasGen then
		local grule, gn, gel = G.decodeUp(probe, lane, wireToGen, IR.upWidth, 1e12)
		assert(grule == 0, s.name .. ": generated rule " .. grule)
		assert(gn == msgs and gel == elements, s.name .. ": generated count " .. gn .. "/" .. gel)
		for i = 1, msgs do
			assert(deepEqual(G.values[i], d.received[i].value), s.name .. ": value " .. i .. " differs")
		end
	end

	local batch = math.clamp(math.ceil(2 ^ 18 / bytes), 8, 1000)
	local frames = framesOf(lane, s.runs, batch)
	local slot = namespace.definitions[s.runs[1] and s.runs[1][1] or "ping1"].receivedSlot
	local function resetConn()
		conn.count = 0
		conn.window = Replay.new()
		conn.failures = 0
	end
	-- check F accepts every frame of the batch
	if #s.runs > 0 then
		resetConn()
		local before = counters.totals[slot]
		for i = 1, batch do Inbound.receive(rt, player, lane, frames[i]) end
		local expected = 0
		for _, run in s.runs do if run[1] == s.runs[1][1] then expected += run[3] end end
		assert(counters.totals[slot] - before == expected * batch, s.name .. ": full receive refused frames")
	end

	local cases = {
		{ name = "D", fn = function()
			for i = 1, batch do decodeMilestone(frames[1], lane) end
		end },
		{ name = "DP", fn = function()
			for i = 1, batch do
				local _, dd = decodeMilestone(frames[1], lane)
				Inbound._process(rt, conn, dd)
			end
		end },
		{ name = "F", fn = function()
			resetConn()
			for i = 1, batch do Inbound.receive(rt, player, lane, frames[i]) end
		end },
	}
	if hasGen then
		table.insert(cases, { name = "G", fn = function()
			for i = 1, batch do G.decodeUp(frames[1], lane, wireToGen, IR.upWidth, 1e12) end
		end })
	end

	-- calibrate passes per round, warm up, then rounds
	local passes = {}
	for i, c in cases do
		local t0 = os.clock()
		c.fn()
		local dt = os.clock() - t0
		passes[i] = math.max(1, math.ceil(TARGET / math.max(dt, 1e-6)))
		for _ = 1, math.min(passes[i], 3) do c.fn() end
	end
	local times = {}
	for i = 1, #cases do times[i] = {} end
	for _ = 1, ROUNDS do
		for i, c in cases do
			local t0 = os.clock()
			for _ = 1, passes[i] do c.fn() end
			table.insert(times[i], (os.clock() - t0) / (passes[i] * batch) * 1e9)
		end
	end
	local cells = {}
	local med = {}
	for i, c in cases do
		local ts = table.clone(times[i])
		table.sort(ts)
		med[c.name] = median(ts)
		cells[c.name] = string.format("%9.0f (%7.0f-%7.0f)", median(ts), ts[1], ts[#ts])
	end
	local function per(x, n) return if x and n > 0 then string.format("%8.2f", x / n) else string.format("%8s", "-") end
	print(string.format("%-50s %4d %6d %6d %7d | %-24s | %-24s | %-24s | %-24s | %s %s %s %s",
		s.name, lane, bytes, msgs, elements, cells.D, cells.DP, cells.F, cells.G or "-",
		per(med.F, bytes), per(med.G, bytes), per(med.F, elements), per(med.G, elements)))
end
