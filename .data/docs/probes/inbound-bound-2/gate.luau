--!nocheck
-- Claim 4: the §9 inbound-bound gate as a test. Times every frame kind of the shape set through the milestone
-- server's receive path at its costliest position, divides each by a header-only reliable frame at e + 4 timed in
-- the same run (so the test does not depend on the host), and compares the ratio with the bound's for that frame:
--   (1 + mu) * (c_f + c_b * charge + 100 ns * units) / c_f,r     (prices from RESULTS.md claim 2 on the reference host)
-- It fails (raises, nonzero exit) when any shape's ratio passes the bound's, and lists each failing shape.
-- Argument: "new" (the prices and unit rule of RESULTS.md, mu chosen there) or "v36" (draft 3.6: c_f,r 2.53 µs,
-- c_b,r 20.2 ns/B, c_f,u 2.60 µs, c_b,u 10.8 ns/B, p(L) = 2,000 + 133 L per element with L the element's own leaves
-- by 3.6's rule: arrays, maps and union tags count 0). Shapes it must include (§9): header-only frames at e and
-- e + 4; failing tags on both lanes with every candidate hashed; every frame of decode_cost.luau's shape set (each
-- codec kind in row, run, constant-column and random-column form, records of 1 and 16 fields and of 128 bools,
-- records of empty arrays and maps, unions, nested records, long arrays, strings and buffers at e + 4); untagged
-- HELLO frames; long instance lists.
-- Run from WORK_DIR: luau -O2 --codegen gate.luau -a new   (or -a v36)

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
local DATA = require("./frames_data")
local Frame, Tag, Bits = M.Frame, M.Tag, M.Bits
local rt, conn, player = C.rt, C.conn, C.player

local WHICH = ... or "new"

-- Prices -----------------------------------------------------------------------------------------------------------
-- c_f,r here is the header-only reliable frame at e + 4 on the reference host; every price is used as a ratio to it.
local PRICES = {
	-- RESULTS.md claim 2 and claim 1 (native, reference host); filled from derive.out
	new = {
		cfr = 4110, cfu = 3600, cbr = 23.50, cbu = 15.30, unit = 100, mu = 0.25, p0 = 2400, p1 = 133,
		weights = {
			bool = 1, int = 1, varint = 1, number = 1, f32 = 1, f64 = 1, angle = 1, enum = 1, string = 1, buffer = 1,
			robloxEnum = 1, instance = 1, vector3 = 3, vector3f32 = 3, color3 = 3, direction = 2, rotation = 4,
			cframe = 7, optional = 1, union = 1, array = 2, map = 2, record = 0,
		},
		perElementBound = false,
	},
	v36 = {
		cfr = 2530, cfu = 2600, cbr = 20.2, cbu = 10.8, unit = 1, mu = 0, p0 = 2000, p1 = 133,
		weights = {
			bool = 1, int = 1, varint = 1, number = 1, f32 = 1, f64 = 1, angle = 1, enum = 1, string = 1, buffer = 1,
			robloxEnum = 1, instance = 1, vector3 = 3, vector3f32 = 3, color3 = 3, direction = 2, rotation = 4,
			cframe = 7, optional = 1, union = 0, array = 0, map = 0, record = 0,
		},
		perElementBound = true,
	},
}
-- the reference host's header-only reliable frame at e + 4 (RESULTS.md claim 2), the denominator of every ratio
local H_REF = 4110
local P = PRICES[WHICH]
assert(P, "gate: argument is new or v36")

local ROUNDS = 5
local TARGET = 0.01

local function median(xs)
	local c = table.clone(xs)
	table.sort(c)
	return c[(#c + 1) // 2]
end

local function timeIt(prepare, fn, batch)
	local function pass()
		prepare()
		for i = 1, batch do fn(i) end
	end
	local t0 = os.clock()
	pass()
	local passes = math.max(1, math.ceil(TARGET / math.max(os.clock() - t0, 1e-6)))
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

-- units of one decoded frame, by the element rule ----------------------------------------------------------------
local function walk(c, v, e, elems)
	local k = c.kind
	if k == "record" then
		e.record = (e.record or 0) + 1
		for _, f in c.fields do walk(f.codec, v[f.name], e, elems) end
	elseif k == "optional" then
		e.optional = (e.optional or 0) + 1
		if v ~= nil then walk(c.inner, v, e, elems) end
	elseif k == "union" then
		e.union = (e.union or 0) + 1
		local variant = c.variants[c.byName[v.kind] + 1]
		for _, f in variant.record.fields do walk(f.codec, v[f.name], e, elems) end
	elseif k == "array" then
		e.array = (e.array or 0) + 1
		for _, item in v do
			local ne = {}
			walk(c.inner, item, ne, elems)
			table.insert(elems, ne)
		end
	elseif k == "map" then
		e.map = (e.map or 0) + 1
		for key, val in v do
			local ne = {}
			walk(c.key, key, ne, elems)
			walk(c.value, val, ne, elems)
			table.insert(elems, ne)
		end
	else
		e[k] = (e[k] or 0) + 1
	end
end
local function priceOfElement(e)
	local L = 0
	for k, n in e do L += (P.weights[k] or 0) * n end
	local p = P.p0 + P.p1 * L
	if P.perElementBound then
		return p -- draft 3.6: p(L) ns per element
	end
	return math.ceil(p / 100 - 1e-9) * P.unit -- units x 100 ns
end
local function elementCost(received)
	local total = 0
	for _, msg in received do
		local elems = {}
		local e = {}
		local codec = msg.definition.ir.data
		if codec ~= nil then
			if codec.kind == "record" then
				for _, f in codec.fields do walk(f.codec, msg.value[f.name], e, elems) end
			else
				walk(codec, msg.value, e, elems)
			end
		end
		table.insert(elems, e)
		for _, el in elems do total += priceOfElement(el) end
	end
	return total
end

-- shapes ------------------------------------------------------------------------------------------------------------
local function fromHex(h)
	local b = buffer.create(#h // 2)
	for i = 0, #h // 2 - 1 do buffer.writeu8(b, i, tonumber(string.sub(h, 2 * i + 1, 2 * i + 2), 16)) end
	return b
end
local function resetConn()
	conn.count = 0
	conn.window = Replay.new()
	conn.failures = 0
	conn.pendingKey = nil
	conn.hasTagged = true
end
local function tagAt(body, count, lane, ic)
	return Tag.compute(conn.key, count, lane, body, buffer.len(body), ic or 0, conn.cover)
end
-- reliable frames at e + 4 from the expected count (16-bit tag collisions handled as a sender would)
local function framesE4(body, ic, n)
	local frames, expect = {}, 0
	for i = 1, n do
		local tag = tagAt(body, expect + 4, 0, ic)
		local at = expect + 4
		for k = expect, expect + 3 do
			if tagAt(body, k, 0, ic) == tag then at = k break end
		end
		frames[i] = Tag.append(body, tag)
		expect = at + 1
	end
	return frames
end

local results = {}
local H -- this run's header-only reliable frame at e + 4
local function check(name, ns, boundNs)
	-- boundNs is in reference-host ns; the test compares ratios to the header-only frame
	local ratio = ns / H
	local limit = (1 + P.mu) * boundNs / H_REF
	table.insert(results, { name = name, ratio = ratio, limit = limit })
end

local BATCH = 32
do
	local body = Frame.up(0, nil, nil, {})
	local frames = framesE4(body, 0, BATCH)
	H = timeIt(resetConn, function(i) Inbound.receive(rt, player, 0, frames[i]) end, BATCH)
	local framesE = {}
	for i = 1, BATCH do framesE[i] = Tag.append(body, tagAt(body, i - 1, 0)) end
	local he = timeIt(resetConn, function(i) Inbound.receive(rt, player, 0, framesE[i]) end, BATCH)
	check("header only e", he, P.cfr + P.cbr * 3)
	check("header only e+4", H, P.cfr + P.cbr * 3)
end

-- every frame of the shape set at e + 4
for _, case in DATA do
	local body = fromHex(case.body)
	local list = {}
	for i = 1, case.instances do list[i] = R.newInstance() end
	local probe = Tag.append(body, tagAt(body, 0, 0, case.instances))
	local r = Frame.open(probe, false, 0)
	local d = Inbound._decodingOf(rt, conn, 0, list, case.instances)
	r.budget = 1e12
	assert(Inbound._decodeUp(r, d) == 0, case.name)
	local elements = elementCost(d.received)
	local bytes = buffer.len(probe)
	local batch = math.clamp(2 ^ 18 // bytes, 1, BATCH)
	local frames = framesE4(body, case.instances, batch)
	local ns = timeIt(resetConn, function(i) Inbound.receive(rt, player, 0, frames[i], list) end, batch)
	check(case.name .. " e+4", ns, P.cfr + P.cbr * (bytes + 8 * case.instances) + elements)
end

-- failing tags, every candidate hashed
for _, len in { 0, 1024, 15900 } do
	local body = Frame.up(0, nil, nil, if len == 0 then {} else { C.chunkOf("big_a", { string.rep("x", len) }, 1) })
	local cands = {}
	for k = 0, 4 do cands[tagAt(body, k, 0)] = true end
	local frames = {}
	for i = 1, BATCH do
		local count = 100000 + i
		while cands[tagAt(body, count, 0)] do count += BATCH end
		frames[i] = Tag.append(body, tagAt(body, count, 0))
	end
	local ns = timeIt(resetConn, function(i) conn.failures = 0 Inbound.receive(rt, player, 0, frames[i]) end, BATCH)
	check(string.format("reliable failing B=%d", buffer.len(frames[1])), ns, P.cfr + P.cbr * buffer.len(frames[1]))
end
for _, len in { 0, 955 } do
	local frames = {}
	for i = 1, BATCH do
		local body = Frame.up(1, 10001 % 4096, nil, if len == 0 then {} else { C.chunkOf("ustr_a", { string.rep("y", len) }, 1) })
		frames[i] = Tag.append(body, tagAt(body, 300000 + i, 1))
	end
	local ns = timeIt(function() resetConn() conn.window.newest = 10000 end, function(i)
		conn.failures = 0
		Inbound.receive(rt, player, 1, frames[i])
	end, BATCH)
	check(string.format("unreliable failing B=%d", buffer.len(frames[1])), ns, P.cfu + P.cbu * buffer.len(frames[1]))
	-- accepted at the third extension (3 hashes, then the decode)
	local framesC3 = {}
	for i = 0, BATCH - 1 do
		local newest = 10000 + i * 4097
		local body = Frame.up(1, (newest + 1) % 4096, nil, if len == 0 then {} else { C.chunkOf("ustr_a", { string.rep("y", len) }, 1) })
		framesC3[i + 1] = Tag.append(body, tagAt(body, newest + 1 + 4096, 1))
	end
	local nsC3 = timeIt(function() resetConn() conn.window.newest = 10000 end, function(i)
		Inbound.receive(rt, player, 1, framesC3[i])
	end, BATCH)
	local units = if len == 0 then 0 else priceOfElement({ string = 1 })
	check(string.format("unreliable third extension B=%d", buffer.len(framesC3[1])), nsC3, P.cfu + P.cbu * buffer.len(framesC3[1]) + units)
end

-- untagged HELLO frames before the first tagged one (not canonical, so the milestone then hashes 5 times)
do
	local rows = {}
	while true do
		rows[#rows + 1] = { version = State.VERSION, seed = State.BUILD_SEED, hashLow = IR.hashLow, hashHigh = IR.hashHigh, name = "bench" }
		local w = Bits.writer()
		Control.write(w, Control.HELLO, rows)
		if buffer.len((Frame.up(0, nil, nil, { Frame.chunk(0, 2, w, {}) }))) > 16383 then
			rows[#rows] = nil
			break
		end
	end
	local w = Bits.writer()
	Control.write(w, Control.HELLO, rows)
	local valid = Frame.up(0, nil, nil, { Frame.chunk(0, 2, w, {}) })
	local bad = buffer.create(buffer.len(valid) + 1)
	buffer.copy(bad, 0, valid)
	local helloUnits = #rows * priceOfElement({ int = 4, string = 1 })
	for _, case in { { "untagged HELLO frame, not canonical", bad }, { "untagged HELLO frame, valid", valid } } do
		local ns = timeIt(function() end, function()
			resetConn()
			conn.hasTagged = false
			table.clear(conn.hashByName)
			table.clear(conn.waiting)
			conn.failures = 0
			Inbound.receive(rt, player, 0, case[2])
		end, 8)
		check(string.format("%s rows=%d B=%d", case[1], #rows, buffer.len(case[2])), ns, P.cfr + P.cbr * buffer.len(case[2]) + helloUnits)
	end
end

-- long instance lists, refused at the byte bucket after the walk
do
	local INSTANCE = R.newInstance()
	for _, n in { 4096, 16384 } do
		local list = table.create(n, INSTANCE)
		local body = Frame.up(1, 1, nil, {})
		local frame = Tag.append(body, tagAt(body, 1000, 1, n))
		local ns = timeIt(function()
			resetConn()
			conn.buckets[4] = Buckets.new(0, 1, os.clock())
		end, function() Inbound.receive(rt, player, 1, frame, list) end, BATCH)
		conn.buckets[4] = Buckets.new(C.HUGE.perSecond, C.HUGE.burst, os.clock())
		-- the walk stops at the bucket's tokens in §6.1; this build walks the whole list, so the bound charges it all
		check(string.format("instance list n=%d refused at the byte bucket", n), ns, P.cfu + P.cbu * (buffer.len(frame) + 8 * n))
	end
end

-- verdict -------------------------------------------------------------------------------------------------------------
local failed = {}
print(string.format("gate %s: header-only reliable frame at e + 4 in this run %.0f ns (reference %d ns); mu %.2f", WHICH, H, H_REF, P.mu))
for _, r in results do
	local ok = r.ratio <= r.limit
	print(string.format("%-4s %-60s ratio %8.3f  limit %8.3f", if ok then "ok" else "FAIL", r.name, r.ratio, r.limit))
	if not ok then table.insert(failed, r.name) end
end
print(string.format("%d shapes, %d over the bound", #results, #failed))
if #failed > 0 then
	error(string.format("inbound bound exceeded by %d shape(s): %s", #failed, table.concat(failed, "; ")), 0)
end
