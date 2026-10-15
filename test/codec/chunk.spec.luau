--!strict

--[=[
	chunk.spec

	A chunk's instances and its decode budget (m1-plan.md §6.2, §7.3 C1, C2, C4, C5):
	- decoding reads the chunk's entries by offset and count, so lists with holes decode alike,
	  and unreplicated instances are misses, not refusals;
	- encoding is read-only on the instance list, so an instance that was not collected raises
	  `internal` and writes nothing;
	- a raise or a refusal leaves the writer and the instance list as they were;
	- every run, array and map count is charged to the reader's budget before allocation (rule 10).
]=]

-- Imports -----------------------------------------------------------------------------------------

local Bits = require("../../src/wire/bits")
local Check = require("../support/check")
local Column = require("../../src/wire/column")
local Frame = require("../support/frame")
local Gen = require("../support/gen")
local Ir = require("../../src/plan/ir")
local Lync = require("../../src")
local Rows = require("../../src/codec/rows")
local Run = require("../../src/codec/run")

-- Constants ---------------------------------------------------------------------------------------

const SUBJECT = "arena.test:fire"
const BUDGET = 65_536
const MAX_REFUSAL_SECONDS = 0.001
const MAX_REFUSAL_KILOBYTES = 1024

local t = Lync.types

-- Private -----------------------------------------------------------------------------------------

local function newInstances(): Rows.Instances
	return { list = {}, index = {}, count = 0 }
end

local function threeInstances(): (Ir.Codec, { Instance })
	local codec = Gen.plan({ a = t.instance(), b = t.instance(), c = t.instance() })
	local parts = { Instance.new("Part"), Instance.new("Part"), Instance.new("Part") }

	return codec, parts
end

local function snapshotOf(w: Bits.Writer): string
	return `{w.bit} {#w.tail} {w.tailBytes} {buffer.tostring(Bits.finish(w))}`
end

-- Builds a payload bit by bit.
local function payloadOf(build: (w: Bits.Writer) -> ()): buffer
	local w = Bits.writer()
	build(w)

	return Bits.finish(w)
end

-- Decodes with a budget, and returns the rule, the seconds taken and the heap's growth in KB.
local function measuredDecode(
	bytes: buffer,
	codec: Ir.Codec,
	count: number
): (number, number, number)
	local heapBefore = collectgarbage("count")
	local start = os.clock()
	local decoded = Frame.decodeRun(bytes, codec, count, {}, 0, BUDGET)
	local seconds = os.clock() - start

	return decoded.rule, seconds, collectgarbage("count") - heapBefore
end

-- Tests -------------------------------------------------------------------------------------------

return {
	["instance lists with holes decode alike, by the chunk's count"] = function()
		local codec, parts = threeInstances()
		local p, q, r = parts[1], parts[2], parts[3]
		local bytes, list = Frame.encodeRun(codec, { { a = p, b = q, c = r } }, 1)
		Check.expectEqual(list, { p, q, r }, "the collected list")

		local assigned: { Instance? } = {}
		assigned[1] = p
		assigned[3] = r
		local trailing: { Instance? } = {}
		trailing[1] = p
		trailing[2] = q
		local cases: { { list: { Instance? }, value: { [string]: Instance? }, misses: { any } } } =
			{
				{ list = { p, q, r }, value = { a = p, b = q, c = r }, misses = {} },
				{
					list = { p, nil, r },
					value = { a = p, c = r },
					misses = { { row = 1, what = 2, value = 1 } },
				},
				{
					list = assigned,
					value = { a = p, c = r },
					misses = { { row = 1, what = 2, value = 1 } },
				},
				{
					list = trailing,
					value = { a = p, b = q },
					misses = { { row = 1, what = 2, value = 2 } },
				},
			}
		for i, case in cases do
			local decoded = Frame.decodeRun(bytes, codec, 1, case.list, 3)
			Check.expectEqual(decoded.rule, 0, `list {i}: rule`)
			Check.expectEqual(decoded.misses, case.misses, `list {i}: misses`)
			Check.expectEqual(decoded.values[1], case.value, `list {i}: value`)
		end
	end,

	["a chunk reads its entries from its offset in the frame's array"] = function()
		local codec, parts = threeInstances()
		local p, q, r = parts[1], parts[2], parts[3]
		local bytes = Frame.encodeRun(codec, { { a = p, b = q, c = r } }, 1)
		local frameList = { Instance.new("Model"), Instance.new("Model"), p, q, r }

		local reader = Bits.reader(bytes)
		local chunk = Rows.beginChunk(frameList, 2, 3)
		local out = {}
		Check.expectEqual(Run.decode(reader, codec, 1, chunk, {}, out), 0, "rule")
		Check.expectEqual(Rows.endChunk(chunk), 0, "rule 9")
		Check.expectEqual(out[1], { a = p, b = q, c = r }, "value")
	end,

	["a wrong class and an unknown Roblox enum value are misses of their row"] = function()
		local codec = Gen.plan({ part = t.instance("BasePart"), material = t.enum(Enum.Material) })
		local model = Instance.new("Model")
		-- Fields in name order, material then part; EG-0 "010" is zigzag(-1), and no Material has
		-- the value -1.
		local bytes = payloadOf(function(w)
			Bits.write(w, 3, 0b010)
			Bits.write(w, 1, 0)
			Bits.write(w, 3, 0b010)
			Bits.write(w, 1, 1)
		end)
		local decoded = Frame.decodeRun(bytes, codec, 2, { Instance.new("Part"), model })
		Check.expectEqual(decoded.rule, 0, "rule")
		Check.expectEqual(decoded.misses, {
			{ row = 1, what = 1, value = -1 },
			{ row = 2, what = 1, value = -1 },
			{ row = 2, what = 3, value = 1 },
		}, "misses")
	end,

	["internal: encoding an instance that was not collected writes nothing"] = function()
		local codec, parts = threeInstances()
		local value = { a = parts[1], b = parts[2], c = parts[3] }
		local w = Bits.writer()
		Bits.write(w, 5, 21)
		local before = snapshotOf(w)
		local instances = newInstances()
		Check.expectThrow(function()
			Rows.encodeValue(w, codec, value, instances, SUBJECT, "data")
		end, { code = "internal" })
		Check.expectEqual(snapshotOf(w), before, "the writer")
		Check.expectEqual(instances, newInstances(), "the instances")
	end,

	["a raise from game code leaves the writer as it was and is rethrown unchanged"] = function()
		local codec = Gen.plan({
			a = t.int(0, 255),
			b = t.convert(t.int(0, 9), function(value: any): any
				return value
			end, function(value: any): any
				if value == "boom" then
					error({ reason = "game code error" })
				end
				return value
			end),
		})
		local w = Bits.writer()
		local ok, raised = pcall(
			Rows.encodeValue,
			w,
			codec,
			{ a = 7, b = "boom" },
			newInstances(),
			SUBJECT,
			"data"
		)
		Check.expect(not ok, "the encode must raise")
		Check.expectEqual(raised, { reason = "game code error" }, "the raise")
		Check.expectEqual(w.bit, 0, "the writer's bit")
	end,

	["a refused message takes its instances back, so the next one passes rule 9"] = function()
		local codec = Gen.plan({ a = t.instance(), z = t.int(0, 3) })
		local p, q = Instance.new("Part"), Instance.new("Model")
		local instances = newInstances()
		local w = Bits.writer()

		local first = { a = p, z = 9 }
		Rows.collect(codec, first, instances)
		Check.expectThrow(function()
			Rows.encodeValue(w, codec, first, instances, SUBJECT, "data")
		end, { code = "valueRefused", path = "data.z" })
		Check.expectEqual(instances, newInstances(), "the instances after the refusal")

		local second = { a = q, z = 1 }
		Rows.collect(codec, second, instances)
		Rows.encodeValue(w, codec, second, instances, SUBJECT, "data")
		local decoded = Frame.decodeRun(Bits.finish(w), codec, 1, instances.list)
		Check.expectEqual(decoded.rule, 0, "rule")
		Check.expectEqual(decoded.values[1], second, "value")
	end,

	["a full array of a zero-cost column is rule 10 past the budget"] = function()
		local codec = Gen.plan(t.array(t.bool(), 65535))
		local message = Frame.encodeRun(codec, { table.create(65535, false) }, 1)
		Check.expectEqual(buffer.len(message), 3, "a 3-byte message")
		Check.expectEqual(Frame.decodeRun(message, codec, 1, {}).rule, 0, "one message, no budget")
		Check.expectEqual(
			Frame.decodeRun(message, codec, 1, {}, 0, BUDGET).rule,
			0,
			"within the budget"
		)

		-- A 16,384 B frame holds 5,461 such messages; as one run they are a count column and a
		-- constant bool column, which mode 0 codes in 2 bits.
		local messageCount = 5461
		local bytes = payloadOf(function(w)
			Column.write(w, table.create(messageCount, 65535), 1, messageCount, 65536)
			Bits.write(w, 2, 0)
		end)
		local rule, seconds, kilobytes = measuredDecode(bytes, codec, messageCount)
		Check.expectEqual(rule, 10, "rule")
		Check.expect(seconds < MAX_REFUSAL_SECONDS, `refused in {seconds * 1000} ms`)
		Check.expect(kilobytes < MAX_REFUSAL_KILOBYTES, `heap grew {kilobytes} KB`)
	end,

	["nested arrays of empty records are rule 10 before any element is built"] = function()
		-- The planner refuses this codec (`zeroWidthElement`); a decoder must still survive it.
		local element: Ir.Codec = { kind = "record", fields = {} }
		local inner: Ir.Codec = { kind = "array", inner = element, max = 65535, width = 16 }
		local codec: Ir.Codec = { kind = "array", inner = inner, max = 64, width = 7 }
		local bytes = payloadOf(function(w)
			Bits.write(w, 7, 64)
			Column.write(w, table.create(64, 65535), 1, 64, 65536)
		end)

		local rule, seconds, kilobytes = measuredDecode(bytes, codec, 1)
		Check.expectEqual(rule, 10, "rule")
		Check.expect(seconds < MAX_REFUSAL_SECONDS, `refused in {seconds * 1000} ms`)
		Check.expect(kilobytes < MAX_REFUSAL_KILOBYTES, `heap grew {kilobytes} KB`)
	end,
}
