--!nocheck
-- Claim 4: the §9 inbound-bound gate as a test. Times every frame kind of the shape set through the milestone
-- server's receive path at its costliest position, divides each by a header-only reliable frame at e + 4 timed in
-- the same run (so the test does not depend on the host), and compares the ratio with the bound's for that frame:
--   (1 + mu) * (c_f + c_b * charge + 100 ns * units) / c_f,r     (prices from RESULTS.md claim 2 on the reference host)
-- It fails (raises, nonzero exit) when any shape's ratio passes the bound's, and lists each failing shape.
-- Argument: "new" (v5.md §7.5's prices, unit rule and mu) or "v36" (draft 3.6: c_f,r 2.53 µs,
-- c_b,r 20.2 ns/B, c_f,u 2.60 µs, c_b,u 10.8 ns/B, p(L) = 2,000 + 133 L per element with L the element's own leaves
-- by 3.6's rule: arrays, maps and union tags count 0). Shapes it must include (§9): header-only frames at e and
-- e + 4; failing tags on both lanes with every candidate hashed; every frame of decode_cost.luau's shape set (each
-- codec kind in row, run, constant-column and random-column form, records of 1 and 16 fields and of 128 bools,
-- records of empty arrays and maps, unions, nested records, long arrays, strings and buffers at e + 4); untagged
-- HELLO frames; long instance lists.
-- Run from WORK_DIR: luau -O2 --codegen gate.luau -a new [mu]   (or -a v36)

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

local WHICH, MU = ...
WHICH = WHICH or "new"

-- Prices -----------------------------------------------------------------------------------------------------------
-- c_f,r here is the header-only reliable frame at e + 4 on the reference host; every price is used as a ratio to it.
local PRICES = {
	-- v5.md §7.5 (draft 3.6, final pass): RESULTS.md claim 2's prices at their highest run median (c_f,r 4,280 ns,
	-- c_f,u 4,950 ns, c_b,r 29.99 ns/B and c_b,u 19.36 ns/B, the walk included), claim 1's unit rule, and mu 0.10.
	-- The earlier medians (3938, 3338, 23.04, 13.28; mu 0.25) are RESULTS.md's own gate runs (gate.out).
	new = {
		cfr = 4280, cfu = 4950, cbr = 29.99, cbu = 19.36, unit = 100, mu = 0.10, p0 = 2500, p1 = 133,
		weights = {
			bool = 1, int = 2, varint = 3, number = 2, f32 = 2, f64 = 3, angle = 2, enum = 1, string = 3, buffer = 3,
			robloxEnum = 3, instance = 3, vector3 = 3, vector3f32 = 4, color3 = 3, direction = 4, rotation = 8,
			cframe = 14, optional = 1, union = 2, array = 2, map = 2, record = 2,
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
-- the denominator of every ratio: this gate's own header-only reliable frame at e + 4 on the reference host (median
-- of its sweeps' denominators there, 3,561-3,597 ns; tag_cost.luau's harness measures the same frame at 3,938 ns,
-- which is c_f,r). Calibrating it with the gate's own harness keeps the harness difference out of the ratios.
local H_REF = 3590
local P = PRICES[WHICH]
assert(P, "gate: argument is new or v36")
if MU ~= nil then
	P.mu = assert(tonumber(MU), "gate: second argument is mu")
end

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

-- One sweep times every shape once; the gate runs RUNS sweeps and compares each shape's median ratio over them.
-- Each sweep's denominator is the median of the header-only frame at e + 4 timed before every 32nd shape.
local RUNS = 3
local results = {} -- name -> { ratios = { ... }, limit }
local order = {}
local headerTimes = {}
local headerFrames
local function timeHeader()
	table.insert(headerTimes, timeIt(resetConn, function(i) Inbound.receive(rt, player, 0, headerFrames[i]) end, #headerFrames))
end
local pending = {} -- this sweep's { name, ns, boundNs }
local function check(name, ns, boundNs)
	-- boundNs is in reference-host ns; the test compares ratios to the header-only frame
	table.insert(pending, { name, ns, boundNs })
	if #pending % 32 == 0 then
		timeHeader()
	end
end

local BATCH = 32
local function sweep()
table.clear(headerTimes)
table.clear(pending)
do
	local body = Frame.up(0, nil, nil, {})
	headerFrames = framesE4(body, 0, BATCH)
	timeHeader()
	local framesE = {}
	for i = 1, BATCH do framesE[i] = Tag.append(body, tagAt(body, i - 1, 0)) end
	local he = timeIt(resetConn, function(i) Inbound.receive(rt, player, 0, framesE[i]) end, BATCH)
	check("header only e", he, P.cfr + P.cbr * 3)
	local h4 = timeIt(resetConn, function(i) Inbound.receive(rt, player, 0, headerFrames[i]) end, BATCH)
	check("header only e+4", h4, P.cfr + P.cbr * 3)
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

timeHeader()
local H = median(headerTimes)
for _, r in pending do
	local name, ns, boundNs = r[1], r[2], r[3]
	local entry = results[name]
	if entry == nil then
		entry = { ratios = {}, limit = (1 + P.mu) * boundNs / H_REF, at0 = boundNs / H_REF }
		results[name] = entry
		table.insert(order, name)
	end
	table.insert(entry.ratios, ns / H)
end
return H
end

-- verdict -------------------------------------------------------------------------------------------------------------
local hs = {}
for run = 1, RUNS do
	hs[run] = sweep()
end
local failed = {}
print(string.format("gate %s: %d sweeps; header-only reliable frame at e + 4 per sweep %s ns (reference %d ns); mu %.2f",
	WHICH, RUNS, table.concat((function() local t = {} for i, h in hs do t[i] = string.format("%.0f", h) end return t end)(), ", "), H_REF, P.mu))
local over = { [0] = 0, [10] = 0, [25] = 0 }
local worstAt0, worstName = 0, ""
for _, name in order do
	local r = results[name]
	local ratio = median(r.ratios)
	local ok = ratio <= r.limit
	print(string.format("%-4s %-60s ratio %8.3f  limit %8.3f", if ok then "ok" else "FAIL", name, ratio, r.limit))
	if not ok then table.insert(failed, name) end
	local at0 = ratio / r.at0
	if at0 > worstAt0 then worstAt0, worstName = at0, name end
	for mu, _ in over do
		if at0 > 1 + mu / 100 then over[mu] += 1 end
	end
end
print(string.format("%d shapes, %d over the bound at mu %.2f; highest ratio / bound at mu 0: %.3f (%s); over at mu 0 / 0.10 / 0.25: %d / %d / %d",
	#order, #failed, P.mu, worstAt0, worstName, over[0], over[10], over[25]))
if #failed > 0 then
	error(string.format("inbound bound exceeded by %d shape(s): %s", #failed, table.concat(failed, "; ")), 0)
end
