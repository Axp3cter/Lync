--!nocheck
-- R31: what the inbound element bucket admits, in decode CPU and heap, for the worst shapes the
-- planner accepts (no zero-width elements, W <= 65,536), decoded by the milestone build's own
-- decoder (f1fbfd7:src, extracted next to this file by run.sh). Prints, per shape: message bytes,
-- elements charged, elements per byte, ns per element (median of ROUNDS), heap growth per element.
local Lync = require("./src")
local Bits = require("./src/wire/bits")
local Run = require("./src/codec/run")
local t = Lync.types

local ROUNDS = 7

local function plan(codec)
	return Lync.schema("p", { e = Lync.event({ from = "client", data = codec }) }).ir.byName.e.data
end

local function encode(codec, values, count)
	local w = Bits.writer()
	Run.encode(w, codec, values, count, { list = {}, index = {}, count = 0 }, "p.e:fire", values[1])
	return Bits.finish(w)
end

local function chunk()
	return { list = {}, offset = 0, count = 0, firstSeen = 0 }
end

local function median(xs)
	table.sort(xs)
	return xs[(#xs + 1) // 2]
end

local function measure(name, codec, values, count)
	local bytes = encode(codec, values, count)
	local times, heaps, charged = {}, {}, 0
	for round = 0, ROUNDS do
		collectgarbage("collect")
		local r = Bits.reader(bytes, 0, nil, 1e12)
		local out = table.create(count)
		local before = collectgarbage("count")
		local t0 = os.clock()
		local rule = Run.decode(r, codec, count, chunk(), {}, out)
		local dt = os.clock() - t0
		local after = collectgarbage("count")
		assert(rule == 0, "rule " .. rule)
		charged = 1e12 - r.budget
		if round > 0 then
			table.insert(times, dt)
			table.insert(heaps, after - before)
		end
		out = nil
	end
	local perElement = median(times) / charged * 1e9
	-- the run header's count-1 (EG-0, v5.md §4.1) is outside the payload; add its bits
	local x, len = count, 0
	while x > 0 do len += 1; x //= 2 end
	local frameBytes = buffer.len(bytes) + (2 * len - 1) / 8
	print(string.format("%-44s %6.1f B %8d elem %9.1f elem/B %8.1f ns/elem %7.1f B/elem heap %7.2f ms per 65,536",
		name, frameBytes, charged, charged / frameBytes, perElement,
		median(heaps) * 1024 / charged, perElement * 65536 / 1e6))
end

-- Scalar elements: one array of 65,535 false booleans (constant column, mode 0).
measure("array(bool, 65535), all false", plan(t.array(t.bool(), 65535)), { table.create(65535, false) }, 1)

-- A table per element: one array of 65,535 one-field records.
do
	local rows = table.create(65535)
	for i = 1, 65535 do rows[i] = { a = false } end
	measure("array({a = bool}, 65535), all false", plan(t.array({ a = t.bool() }, 65535)), { rows }, 1)
end

-- A table per message: a run of 65,535 one-field record messages (run count, not an array).
do
	local msgs = table.create(65535)
	for i = 1, 65535 do msgs[i] = { a = false } end
	measure("run of 65535 x {a = bool}, all false", plan({ a = t.bool() }), msgs, 65535)
end

-- Scalar messages: a run of 65,535 bool messages.
measure("run of 65535 x bool, all false", plan(t.bool()), table.create(65535, false), 65535)

-- Nested: 255 arrays of 255 false booleans (W = 1 + 255 x (1 + 255) = 65,281).
do
	local inner = table.create(255, false)
	local outer = table.create(255)
	for i = 1, 255 do outer[i] = table.clone(inner) end
	measure("array(array(bool, 255), 255), all false", plan(t.array(t.array(t.bool(), 255), 255)), { outer }, 1)
end

-- For scale, non-constant data: 64 messages of a 6-field record with random values.
do
	math.randomseed(1)
	local msgs = table.create(64)
	for i = 1, 64 do
		msgs[i] = { a = math.random(0, 1000), b = math.random(0, 1000), c = math.random(0, 255), d = math.random() < 0.5, e = math.random(0, 65535), f = math.random(0, 7) }
	end
	measure("run of 64 x 6-field record, random", plan({ a = t.int(0, 1000), b = t.int(0, 1000), c = t.int(0, 255), d = t.bool(), e = t.int(0, 65535), f = t.int(0, 7) }), msgs, 64)
end
