--!nocheck
-- Claim 1 (and the per-frame inputs of claims 3-4): every frame of the shape set (frames_data.luau, built by
-- build_frames.luau) through the milestone server's receive path and through the generated decoder.
-- Per case, ns per frame, median (min-max) over ROUNDS rounds after a warm-up, a full GC before each timed block:
--   Fe   Inbound.receive end to end, tag accepted at e (1 hash): shape, buckets, tag, decode, step 5
--   Fe4  the same frames tagged at e + 4: 5 hashes, frameGap, decode, step 5 (the costliest accepted position)
--   D    milestone decode only: Frame.open + decodeUp (header, toc, runs, a Received table per message)
--   G    generated decode only (gen_decoders.luau), checked equal to D's values, message and element counts
-- and each frame's elements (rule 10's count) and its element signatures: per element (a message, an array element
-- or a map pair, v5.md §4.8), the node kinds outside the elements nested in it, so derive.py can price any leaf
-- weighting. Run from WORK_DIR: luau -O2 decode_cost.luau   and   luau -O2 --codegen decode_cost.luau

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
local R = require("./rbx_fast")
math.randomseed(7)
local S = require("./shapes")(Lync, R)
local IR = S.schema.ir
local C = require("./common")(M, IR)
local G = require("./gen_decoders")
local DATA = require("./frames_data")
local Frame, Tag = M.Frame, M.Tag
local rt, conn, player, namespace, counters = C.rt, C.conn, C.player, C.namespace, C.counters

local ROUNDS = 7
local TARGET = 0.02
local ONLY = ... -- optional case-name filter

local genIndex = {}
for i, name in G.names do genIndex[name] = i end
local wireToGen = {}
for wire, canonical in namespace.readIds do
	wireToGen[wire] = genIndex[IR.up[canonical + 1].definition.name]
end

local function fromHex(h)
	local b = buffer.create(#h // 2)
	for i = 0, #h // 2 - 1 do
		buffer.writeu8(b, i, tonumber(string.sub(h, 2 * i + 1, 2 * i + 2), 16))
	end
	return b
end

local function median(xs)
	local c = table.clone(xs)
	table.sort(c)
	return c[(#c + 1) // 2], c[1], c[#c]
end

local function deepEqual(a, b)
	if type(a) ~= "table" or type(b) ~= "table" then
		return a == b
	end
	for k, v in a do if not deepEqual(v, b[k]) then return false end end
	for k in b do if a[k] == nil then return false end end
	return true
end

-- element signatures of one message's value
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
local function sigString(e)
	local parts = {}
	for k, n in e do table.insert(parts, k .. "=" .. n) end
	table.sort(parts)
	return table.concat(parts, ",")
end
local function signaturesOf(received)
	local elems = {}
	for _, msg in received do
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
	end
	local hist = {}
	for _, e in elems do
		local s = sigString(e)
		hist[s] = (hist[s] or 0) + 1
	end
	local parts = {}
	for s, n in hist do table.insert(parts, s .. "*" .. n) end
	table.sort(parts)
	return table.concat(parts, ";"), #elems
end

local function decodeMilestone(frame, list, ic)
	local r = Frame.open(frame, false, 0)
	local d = Inbound._decodingOf(rt, conn, 0, list, ic)
	r.budget = 1e12
	local rule = Inbound._decodeUp(r, d)
	return rule, d, 1e12 - r.budget
end

local function timeIt(fn, batch)
	local t0 = os.clock()
	fn()
	local dt = os.clock() - t0
	local passes = math.max(1, math.ceil(TARGET / math.max(dt, 1e-6)))
	for _ = 1, math.min(passes, 3) do fn() end
	local ts = {}
	for _ = 1, ROUNDS do
		collectgarbage("collect")
		local t1 = os.clock()
		for _ = 1, passes do fn() end
		table.insert(ts, (os.clock() - t1) / (passes * batch) * 1e9)
	end
	return median(ts)
end

local cases = table.clone(DATA)
table.insert(cases, 1, { name = "header only", kind = "header", n = 0, form = "header", msgs = 0, instances = 0, body = nil })

for _, case in cases do
	if ONLY and not string.find(case.name, ONLY, 1, true) then
		continue
	end
	local body = if case.body then fromHex(case.body) else Frame.up(0, nil, nil, {})
	local len = buffer.len(body)
	local list = {}
	for i = 1, case.instances do list[i] = R.newInstance() end
	local ic = case.instances
	local function tagged(count)
		return Tag.append(body, Tag.compute(conn.key, count, 0, body, len, ic, conn.cover))
	end
	local probe = tagged(0)
	local bytes = buffer.len(probe)

	-- correctness: milestone decode, generated decode
	local rule, d, elements = decodeMilestone(probe, list, ic)
	assert(rule == 0, case.name .. ": milestone rule " .. rule)
	local msgs = #d.received
	local grule, gn, gel = G.decodeUp(probe, 0, wireToGen, IR.upWidth, 1e12, list, ic)
	assert(grule == 0, case.name .. ": generated rule " .. grule)
	assert(gn == msgs and gel == elements, case.name .. ": generated count " .. gn .. "/" .. gel .. " vs " .. msgs .. "/" .. elements)
	for i = 1, msgs do
		assert(deepEqual(G.values[i], d.received[i].value), case.name .. ": value " .. i .. " differs")
	end
	local sig, sigElements = signaturesOf(d.received)
	assert(sigElements == elements or (msgs == 0 and elements == 0), case.name .. ": signature elements " .. sigElements .. " vs " .. elements)

	local t0 = os.clock()
	decodeMilestone(probe, list, ic)
	local one = os.clock() - t0
	local batch = math.clamp(math.min(2 ^ 20 // bytes, math.floor(0.01 / math.max(one, 1e-7))), 1, 256)
	-- frames at e (count c), and at e + 4 from the count the server will expect: the milestone's tag is 16 bits, so a
	-- frame's e + 4 tag can equal one at e .. e + 3 (2^-16 each); the server then accepts it there, and the next
	-- frame is tagged from that count, as a sender would
	local framesE, framesE4 = {}, {}
	local expectE4 = 0
	for c = 0, batch - 1 do
		framesE[c + 1] = tagged(c)
		local tag = Tag.compute(conn.key, expectE4 + 4, 0, body, len, ic, conn.cover)
		local at = expectE4 + 4
		for k = expectE4, expectE4 + 3 do
			if Tag.compute(conn.key, k, 0, body, len, ic, conn.cover) == tag then
				at = k
				break
			end
		end
		framesE4[c + 1] = Tag.append(body, tag)
		expectE4 = at + 1
	end
	local slot = msgs > 0 and d.received[1].definition.receivedSlot
	local function reset()
		conn.count = 0
		conn.window = Replay.new()
		conn.failures = 0
	end
	local function receiveAll(frames)
		return function()
			reset()
			for i = 1, batch do Inbound.receive(rt, player, 0, frames[i], list) end
		end
	end
	-- every frame accepted at both positions
	for _, frames in { framesE, framesE4 } do
		reset()
		local before = if slot then counters.totals[slot] else 0
		local framesBefore = conn.count
		receiveAll(frames)()
		assert(conn.count == (if frames == framesE then batch else expectE4), case.name .. ": receive refused frames")
		if slot then
			local firstDef = d.received[1].definition
			local expected = 0
			for _, m in d.received do if m.definition == firstDef then expected += 1 end end
			assert(counters.totals[slot] - before == expected * batch, case.name .. ": messages not delivered")
		end
	end

	local fe, fe1, fe2 = timeIt(receiveAll(framesE), batch)
	local f4, f41, f42 = timeIt(receiveAll(framesE4), batch)
	local dm, dm1, dm2 = timeIt(function() for _ = 1, batch do decodeMilestone(framesE[1], list, ic) end end, batch)
	local gm, gm1, gm2 = timeIt(function()
		for _ = 1, batch do G.decodeUp(framesE[1], 0, wireToGen, IR.upWidth, 1e12, list, ic) end
	end, batch)
	print(string.format("CASE %s | B=%d msgs=%d el=%d inst=%d | Fe=%.0f %.0f %.0f | Fe4=%.0f %.0f %.0f | D=%.0f %.0f %.0f | G=%.0f %.0f %.0f | sig=%s",
		case.name, bytes, msgs, elements, ic, fe, fe1, fe2, f4, f41, f42, dm, dm1, dm2, gm, gm1, gm2, sig))
end
