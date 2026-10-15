--!strict

--[=[
	mutation.spec

	Mutated payloads (m1-plan.md §3, unit C): flipped padding bits, truncation, an appended byte,
	map keys out of order, instance lists that break rule 9, and codes past their maximum each
	decode to the expected v5.md §4.8 rule. Random mutations of random payloads never raise.
]=]

-- Imports -----------------------------------------------------------------------------------------

local Bits = require("../../src/wire/bits")
local Check = require("../support/check")
local Column = require("../../src/wire/column")
local Columns = require("../../src/codec/columns")
local Gen = require("../support/gen")
local Ints = require("../../src/wire/ints")
local Ir = require("../../src/plan/ir")
local Lync = require("../../src")
local Prop = require("../support/prop")
local Rows = require("../../src/codec/rows")
local Run = require("../../src/codec/run")

-- Constants ---------------------------------------------------------------------------------------

const SUBJECT = "gen.e:fire"

local t = Lync.types

-- Private -----------------------------------------------------------------------------------------

local function newInstances(): Rows.Instances
	return { list = {}, index = {} }
end

local function encode(codec: Ir.Codec, values: { any }): (buffer, { Instance })
	local instances = newInstances()
	Run.collect(codec, values, #values, instances)
	local w = Bits.writer()
	Run.encode(w, codec, values, #values, instances, SUBJECT)

	return Bits.finish(w), instances.list
end

-- Decodes a payload that fills its buffer, as a frame's last chunk does: the rule, or 4 when
-- the bits and the tail do not meet.
local function ruleOf(bytes: buffer, codec: Ir.Codec, count: number, list: { Instance? }): number
	local r = Bits.reader(bytes)
	local rule = Run.decode(r, codec, count, list, {})
	if rule ~= 0 then
		return rule
	end

	return if Bits.meets(r) then 0 else 4
end

local function withBit(bytes: buffer, bit: number): buffer
	local copy = buffer.create(buffer.len(bytes))
	buffer.copy(copy, 0, bytes)
	local byte = bit // 8
	buffer.writeu8(copy, byte, bit32.bxor(buffer.readu8(copy, byte), bit32.lshift(1, bit % 8)))

	return copy
end

local function resized(bytes: buffer, length: number): buffer
	local copy = buffer.create(length)
	buffer.copy(copy, 0, bytes, 0, math.min(length, buffer.len(bytes)))

	return copy
end

local function strikes(count: number): (Ir.Codec, { any })
	local codec = Gen.plan({ target = t.int(1, 2 ^ 40), aim = t.direction(11) })
	local values = {}
	for i = 1, count do
		values[i] = { target = i, aim = Vector3.xAxis }
	end

	return codec, values
end

-- Builds a payload bit by bit.
local function payloadOf(build: (w: Bits.Writer) -> ()): buffer
	local w = Bits.writer()
	build(w)

	return Bits.finish(w)
end

-- Tests -------------------------------------------------------------------------------------------

return {
	["flipping each padding bit is rule 4"] = function()
		for _, count in { 1, Column.MIN_ROWS } do
			local codec, values = strikes(count)
			local w = Bits.writer()
			Run.encode(w, codec, values, count, newInstances(), SUBJECT)
			local usedBits = w.bit
			local bytes = Bits.finish(w)
			Check.expect(usedBits % 8 ~= 0, "the payload must end inside a byte")
			Check.expectEqual(ruleOf(bytes, codec, count, {}), 0, "unmutated")

			for bit = usedBits, buffer.len(bytes) * 8 - 1 do
				Check.expectEqual(ruleOf(withBit(bytes, bit), codec, count, {}), 4, `bit {bit}`)
			end
		end
	end,

	["truncating a payload is rule 4"] = function()
		local chat = Gen.plan(t.string(200))
		local bytes = encode(chat, { "gg" })
		Check.expectEqual(ruleOf(resized(bytes, buffer.len(bytes) - 1), chat, 1, {}), 4, "chat")

		for _, count in { 1, Column.MIN_ROWS } do
			local codec, values = strikes(count)
			local strikeBytes = encode(codec, values)
			for length = 0, buffer.len(strikeBytes) - 1 do
				local truncated = resized(strikeBytes, length)
				Check.expectEqual(
					ruleOf(truncated, codec, count, {}),
					4,
					`{count} rows, {length} B`
				)
			end
		end
	end,

	["appending a byte is rule 4"] = function()
		local chat = Gen.plan(t.string(200))
		local bytes = encode(chat, { "gg" })
		Check.expectEqual(ruleOf(resized(bytes, buffer.len(bytes) + 1), chat, 1, {}), 4, "chat")

		for _, count in { 1, Column.MIN_ROWS } do
			local codec, values = strikes(count)
			local strikeBytes = encode(codec, values)
			local appended = resized(strikeBytes, buffer.len(strikeBytes) + 1)
			Check.expectEqual(ruleOf(appended, codec, count, {}), 4, `{count} rows`)
		end
	end,

	["map keys out of order or repeated are rule 5"] = function()
		local codec = Gen.plan(t.map(t.int(0, 9), t.bool(), 8))
		local keyCodec = Gen.plan(t.int(0, 9))
		local valueCodec = Gen.plan(t.bool())
		local function rowsOf(keys: { number }): buffer
			return payloadOf(function(w)
				Bits.write(w, 4, #keys)
				for _, key in keys do
					Bits.write(w, 4, key)
					Bits.write(w, 1, 1)
				end
			end)
		end
		local function blockOf(keys: { number }): buffer
			return payloadOf(function(w)
				Bits.write(w, 4, #keys)
				Columns.write(w, keyCodec, keys, 1, #keys, newInstances())
				Columns.write(w, valueCodec, table.create(#keys, true), 1, #keys, newInstances())
			end)
		end

		Check.expectEqual(ruleOf(rowsOf({ 3, 5 }), codec, 1, {}), 0, "ascending")
		Check.expectEqual(ruleOf(rowsOf({ 5, 3 }), codec, 1, {}), 5, "descending")
		Check.expectEqual(ruleOf(rowsOf({ 4, 4 }), codec, 1, {}), 5, "repeated")

		local ascending = {}
		for i = 1, Column.MIN_ROWS do
			ascending[i] = i
		end
		local swapped = table.clone(ascending)
		swapped[1], swapped[2] = swapped[2], swapped[1]
		local repeated = table.clone(ascending)
		repeated[2] = repeated[1]
		Check.expectEqual(ruleOf(blockOf(ascending), codec, 1, {}), 0, "block, ascending")
		Check.expectEqual(ruleOf(blockOf(swapped), codec, 1, {}), 5, "block, out of order")
		Check.expectEqual(ruleOf(blockOf(repeated), codec, 1, {}), 5, "block, repeated")

		local stringCodec = Gen.plan(t.map(t.string(2), t.bool(), 4))
		local stringRows = payloadOf(function(w)
			Bits.write(w, 3, 2)
			for _, key in { "b", "a" } do
				Bits.write(w, 2, 1)
				Bits.writeTail(w, key)
				Bits.write(w, 1, 0)
			end
		end)
		Check.expectEqual(ruleOf(stringRows, stringCodec, 1, {}), 5, "string keys")

		local enumCodec = Gen.plan(t.map(t.enum({ "z", "a" }), t.bool(), 2))
		local enumRows = payloadOf(function(w)
			Bits.write(w, 2, 2)
			Bits.write(w, 1, 1)
			Bits.write(w, 1, 0)
			Bits.write(w, 1, 0)
			Bits.write(w, 1, 0)
		end)
		Check.expectEqual(ruleOf(enumRows, enumCodec, 1, {}), 5, "enum keys by index")
	end,

	["instance lists breaking rule 9"] = function()
		local codec = Gen.plan(t.instance())
		local p, q, r = Instance.new("Part"), Instance.new("Part"), Instance.new("Part")
		local function indices(width: number, list: { number }): buffer
			return payloadOf(function(w)
				for _, index in list do
					Bits.write(w, width, index)
				end
			end)
		end

		-- Two single rows, each an index u(ceil(log2 c)).
		Check.expect(Column.MIN_ROWS > 2, "two messages must be single rows")
		Check.expectEqual(ruleOf(indices(1, { 0, 1 }), codec, 2, { p, q }), 0, "in order")
		Check.expectEqual(ruleOf(indices(0, { 0, 0 }), codec, 2, { p }), 0, "repeated reference")
		Check.expectEqual(ruleOf(indices(1, { 0, 1 }), codec, 2, { p, p }), 9, "duplicated")
		Check.expectEqual(ruleOf(indices(2, { 0, 1 }), codec, 2, { p, q, r }), 9, "unreferenced")
		Check.expectEqual(ruleOf(indices(1, { 1, 0 }), codec, 2, { p, q }), 9, "out of order")
		Check.expectEqual(ruleOf(indices(2, { 0, 3 }), codec, 2, { p, q, r }), 2, "past the list")
		Check.expectEqual(ruleOf(indices(0, { 0 }), codec, 1, {}), 2, "an empty list")

		local blockCodec = Gen.plan(t.array(t.instance(), 9))
		local values = { { p, q, p, q } }
		local bytes, list = encode(blockCodec, values)
		Check.expectEqual(list, { p, q }, "listed in order of first reference")
		Check.expectEqual(ruleOf(bytes, blockCodec, 1, { p, q }), 0, "block")
		Check.expectEqual(ruleOf(bytes, blockCodec, 1, { q, q }), 9, "block, duplicated")
	end,

	["codes past their maximum"] = function()
		local function check(codecValue: any, build: (w: Bits.Writer) -> (), rule: number)
			local codec = Gen.plan(codecValue)
			Check.expectEqual(ruleOf(payloadOf(build), codec, 1, {}), rule, codec.kind)
		end

		check(t.enum({ "a", "b", "c" }), function(w)
			Bits.write(w, 2, 3)
		end, 2)
		check(t.int(0, 100), function(w)
			Bits.write(w, 7, 101)
		end, 3)
		check(t.number(0, 1.25, 0.25), function(w)
			Bits.write(w, 3, 6)
		end, 2)
		check(t.angle(2 * math.pi / 3), function(w)
			Bits.write(w, 2, 3)
		end, 2)
		check(t.string(4), function(w)
			Bits.write(w, 3, 5)
		end, 2)
		check(t.array(t.bool(), 4), function(w)
			Bits.write(w, 3, 5)
		end, 2)
		check(t.map(t.int(0, 3), t.bool(), 2), function(w)
			Bits.write(w, 2, 3)
		end, 2)
		check(t.union({ a = {}, b = {}, c = {} }), function(w)
			Bits.write(w, 2, 3)
		end, 2)
		check(t.rotation(9), function(w)
			Bits.write(w, 1, 1)
			Bits.write(w, 5, 24)
		end, 2)
		check(t.rotation(9), function(w)
			Bits.write(w, 1, 0)
			Bits.write(w, 2, 3)
			for _ = 1, 3 do
				Bits.write(w, 9, 511)
			end
		end, 6)
		check(t.f32(), function(w)
			Bits.write(w, 32, 0x7FC0_0000)
		end, 3)
		check(t.f64(), function(w)
			Bits.write(w, 32, 0)
			Bits.write(w, 32, 0x7FF0_0000)
		end, 3)
		check(t.vector3f32(), function(w)
			Bits.write(w, 32, 0)
			Bits.write(w, 32, 0x7F80_0000)
			Bits.write(w, 32, 0)
		end, 3)
		check(t.int(), function(w)
			Bits.write(w, 53, 0)
			Bits.write(w, 1, 0)
			Bits.write(w, 1, 1)
			Bits.write(w, 53, 0)
			Bits.write(w, 1, 0)
		end, 2)

		local blockCodec = Gen.plan(t.array(t.enum({ "a", "b", "c" }), 9))
		local block = payloadOf(function(w)
			Bits.write(w, 4, Column.MIN_ROWS)
			-- Frame of reference with base 3 and width 0: every zigzagged residual is 3, past n - 1.
			Bits.write(w, 2, 3)
			Ints.writeEg(w, 3, 0)
			Bits.write(w, 6, 0)
		end)
		Check.expectEqual(ruleOf(block, blockCodec, 1, {}), 2, "a residual past the interval")
	end,

	["random mutations never raise"] = function()
		local pool = { Instance.new("Part"), Instance.new("Model"), Instance.new("Part") }
		Prop.check("mutated payload", function(size: number)
			local planned = Gen.plannedCodec(3, size)

			local count = math.random(1, 2 * Column.MIN_ROWS + 1)
			local style = Gen.style(pool)
			local values = {}
			for i = 1, count do
				values[i] = Gen.value(planned, size // 8 + 1, style)
			end
			local bytes, list = encode(planned, values)

			local length = buffer.len(bytes)
			local roll = math.random(1, 3)
			if roll == 1 and length > 0 then
				bytes = resized(bytes, math.random(0, length - 1))
			elseif roll == 2 then
				bytes = resized(bytes, length + math.random(1, 3))
			end
			for _ = 1, math.random(1, 4) do
				if buffer.len(bytes) > 0 then
					bytes = withBit(bytes, math.random(0, buffer.len(bytes) * 8 - 1))
				end
			end

			return { codec = planned, bytes = bytes, count = count, list = list }
		end, function(case)
			local ok, result = pcall(ruleOf, case.bytes, case.codec, case.count, case.list)
			Check.expect(ok, `decoding raised: {result}`)
		end, { runs = 400 })
	end,
}
