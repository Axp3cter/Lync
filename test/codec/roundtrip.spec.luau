--!strict

--[=[
	roundtrip.spec

	Property round trips (m1-plan.md §3, unit C): every codec of v5.md §3.3, alone and nested in
	optional, array, map, union and record, in runs of 1 to 2 × `Column.MIN_ROWS` + 1 messages, so
	in single rows and in column blocks. Each run decodes to the values encoded, the bits and tail
	meet, and the decoded values encode to the same bytes.
]=]

-- Imports -----------------------------------------------------------------------------------------

local Bits = require("../../src/wire/bits")
local Check = require("../support/check")
local Column = require("../../src/wire/column")
local Frame = require("../support/frame")
local Gen = require("../support/gen")
local Ir = require("../../src/plan/ir")
local Lync = require("../../src")
local Prop = require("../support/prop")

-- Constants ---------------------------------------------------------------------------------------

const MAX_RUN = 2 * Column.MIN_ROWS + 1
const ZERO_WIDTH = { intSingle = true, enumSingle = true }

local t = Lync.types

-- Private -----------------------------------------------------------------------------------------

local function instancePool(): { Instance }
	local pool = {}
	for _ = 1, 3 do
		table.insert(pool, Instance.new("Part"))
		table.insert(pool, Instance.new("Model"))
	end

	return pool
end

local function leafCodecs(): { [string]: any }
	return {
		bool = t.bool(),
		int = t.int(-5, 1000),
		intWide = t.int(-2 ^ 52, 2 ^ 52 - 1),
		intSingle = t.int(7, 7),
		varint = t.int(),
		number = t.number(-10, 10, 0.25),
		f32 = t.f32(),
		f64 = t.f64(),
		angle = t.angle(math.rad(1)),
		string = t.string(12),
		buffer = t.buffer(12),
		vector3 = t.vector3(-2048, 2048, 1 / 32),
		vector3f32 = t.vector3f32(),
		direction = t.direction(11),
		rotation = t.rotation(9),
		cframe = t.cframe(t.vector3(-1024, 1024, 1 / 64), t.rotation(12)),
		cframeF32 = t.cframe(t.vector3f32(), t.rotation(7)),
		color3 = t.color3(),
		enum = t.enum({ "red", "green", "blue" }),
		enumSingle = t.enum({ "only" }),
		robloxEnum = t.enum(Enum.Material),
		instance = t.instance(),
		instanceClass = t.instance("BasePart"),
		custom = Gen.custom(),
		convert = t.convert(t.int(0, 255), string.char, string.byte),
	}
end

-- Writes codes of one width, one after another, as a single row's payload.
local function payloadOf(width: number, codes: { number }): buffer
	local w = Bits.writer()
	for _, code in codes do
		Bits.write(w, width, code)
	end

	return Bits.finish(w)
end

local function bytesOf(codec: Ir.Codec, values: { any }, count: number): buffer
	return (Frame.encodeRun(codec, values, count))
end

local function checkRoundTrip(codec: Ir.Codec, values: { any }, count: number)
	local bytes, list = Frame.encodeRun(codec, values, count)
	local decoded = Frame.decodeRun(bytes, codec, count, list)
	Check.expectEqual(decoded.rule, 0, "rule")
	Check.expectEqual(decoded.misses, {}, "misses")
	Check.expectEqual(decoded.values, values, "decoded")

	local again = bytesOf(codec, decoded.values, count)
	Check.expectEqual(buffer.tostring(again), buffer.tostring(bytes), "re-encoded")
end

local function checkEveryCount(codec: Ir.Codec, name: string, pool: { Instance })
	for count = 1, MAX_RUN do
		for _ = 1, 4 do
			local style = Gen.style(pool)
			local values = {}
			for i = 1, count do
				values[i] = Gen.value(codec, 12, style)
			end

			local ok, message = pcall(checkRoundTrip, codec, values, count)
			if not ok then
				error(`{name}, {count} rows: {message}`, 0)
			end
		end
	end
end

-- A 0-bit leaf can't be an array element alone (`zeroWidthElement`), so it travels with a bool.
local function nestingsOf(codec: any, name: string): { [string]: any }
	local element = if ZERO_WIDTH[name] then { value = codec, flag = t.bool() } else codec
	return {
		optional = t.optional(codec),
		array = t.array(element, MAX_RUN),
		map = t.map(t.int(0, 50), codec, MAX_RUN),
		union = t.union({ empty = {}, holds = { value = codec, flag = t.bool() } }),
		record = { value = codec, after = t.int(0, 3) },
	}
end

-- Tests -------------------------------------------------------------------------------------------

return {
	["every codec alone, in rows and column blocks"] = function()
		math.randomseed(1)
		local pool = instancePool()
		for name, codec in leafCodecs() do
			checkEveryCount(Gen.plan(codec), name, pool)
		end
	end,

	["every codec nested in optional, array, map, union and record"] = function()
		math.randomseed(2)
		local pool = instancePool()
		for name, codec in leafCodecs() do
			for nesting, nested in nestingsOf(codec, name) do
				checkEveryCount(Gen.plan(nested), `{nesting} of {name}`, pool)
			end
		end
	end,

	["map keys of every key kind, in rows and column blocks"] = function()
		math.randomseed(3)
		local pool = instancePool()
		local keys = {
			int = t.int(-50, 50),
			varint = t.int(),
			enum = t.enum({ "a", "b", "c", "d", "e", "f", "g" }),
			string = t.string(3),
		}
		for name, key in keys do
			checkEveryCount(Gen.plan(t.map(key, t.int(0, 9), MAX_RUN)), `{name} keys`, pool)
		end
	end,

	["random nested codecs round trip"] = function()
		local pool = instancePool()
		Prop.check("nested codec", function(size: number)
			local planned = Gen.plannedCodec(3, size)

			local count = math.random(1, MAX_RUN)
			local style = Gen.style(pool)
			local values = {}
			for i = 1, count do
				values[i] = Gen.value(planned, size // 8 + 1, style)
			end
			return { codec = planned, values = values, count = count }
		end, function(case)
			checkRoundTrip(case.codec, case.values, case.count)
		end, { runs = 300 })
	end,

	["an empty record costs nothing"] = function()
		local codec = Gen.plan({})
		local bytes = bytesOf(codec, { {}, {}, {}, {}, {} }, 5)
		Check.expectEqual(buffer.len(bytes), 0, "bytes")
	end,

	["an array of MIN_ROWS elements is a column block inside its row"] = function()
		local codec = Gen.plan(t.array(t.int(0, 100), 20))
		local elements = { 40, 41, 42, 42 }
		for _ = 5, Column.MIN_ROWS do
			table.insert(elements, 42)
		end
		local count = #elements

		local countBits = 5
		local _, _, columnBits = Column.choose(elements, 1, count, 101)
		local bytes = bytesOf(codec, { elements }, 1)
		Check.expectEqual(buffer.len(bytes), math.ceil((countBits + columnBits) / 8), "bytes")
		checkRoundTrip(codec, { elements }, 1)
	end,

	["an int column wider than 2^52 codes exactly"] = function()
		-- Residuals depend only on codes modulo n, so t.int(-2^52, 2^52 - 1), whose codes are
		-- v + 2^52, codes as t.int() of the same codes on the centred interval.
		local wide = Gen.plan(t.int(-2 ^ 52, 2 ^ 52 - 1))
		local varint = Gen.plan(t.int())
		local values = { 2 ^ 52 - 1, -2 ^ 52, 0, 2 ^ 52 - 1, -1, 5, 2 ^ 52 - 2 }
		local centred = {}
		for i, value in values do
			centred[i] = if value < 0 then value + 2 ^ 52 else value - 2 ^ 52
		end

		local wideBytes = bytesOf(wide, values, #values)
		local varintBytes = bytesOf(varint, centred, #values)
		Check.expectEqual(buffer.tostring(wideBytes), buffer.tostring(varintBytes), "bytes")
		checkRoundTrip(wide, values, #values)
	end,

	["t.number and t.vector3 re-encode every code, the top code included"] = function()
		for _, bounds in { { 0, 0.3, 0.1 }, { 0, 0.7, 0.1 }, { 0, 2.3, 0.1 }, { -1, 1, 1 / 3 } } do
			local min, max, step = bounds[1], bounds[2], bounds[3]
			local number = Gen.plan(t.number(min, max, step)) :: Ir.NumberCodec
			local vector = Gen.plan(t.vector3(min, max, step))
			for code = 0, number.steps do
				local numberRow = payloadOf(number.width, { code })
				local decoded = Frame.decodeRun(numberRow, number, 1, {})
				Check.expectEqual(decoded.rule, 0, `t.number{bounds}: code {code}`)
				local again = bytesOf(number, decoded.values, 1)
				Check.expectEqual(buffer.tostring(again), buffer.tostring(numberRow), `code {code}`)

				for _, codes in { { code, 0, number.steps }, { number.steps, code, 0 } } do
					local vectorRow = payloadOf(number.width, codes)
					local decodedVector = Frame.decodeRun(vectorRow, vector, 1, {})
					Check.expectEqual(decodedVector.rule, 0, "t.vector3 rule")
					local vectorAgain = bytesOf(vector, decodedVector.values, 1)
					Check.expectEqual(
						buffer.tostring(vectorAgain),
						buffer.tostring(vectorRow),
						"t.vector3"
					)
				end
			end
		end
	end,

	["collecting lists instances in the order the payloads reference them first"] = function()
		local pool = instancePool()
		Prop.check("collect order", function(size: number)
			local codec = nil
			while codec == nil do
				local ok, planned = pcall(Gen.plan, {
					a = Gen.codec(2, size),
					b = t.instance(),
					c = Gen.codec(2, size),
				})
				codec = if ok and planned.kind == "record" then planned else nil
			end

			local count = math.random(1, MAX_RUN)
			local style = Gen.style(pool)
			local values = {}
			for i = 1, count do
				values[i] = Gen.value(codec, size // 8 + 1, style)
			end
			return { codec = codec, values = values, count = count }
		end, function(case)
			-- Rule 9 holds only when the list is in order of first reference and complete.
			local bytes, list = Frame.encodeRun(case.codec, case.values, case.count)
			Check.expectEqual(Frame.decodeRun(bytes, case.codec, case.count, list).rule, 0, "rule")
		end, { runs = 200 })
	end,
}
