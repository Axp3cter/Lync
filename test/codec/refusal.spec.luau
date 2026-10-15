--!strict

--[=[
	refusal.spec

	`valueRefused` for each refusal of v5.md §3.3, raised at the caller's line with the subject and
	the value's path, from a single row (`Rows.encodeValue`) and from runs in single rows and in a
	column block (`Run.encode`). The writer is unchanged afterwards.
]=]

-- Imports -----------------------------------------------------------------------------------------

local Bits = require("../../src/wire/bits")
local Check = require("../support/check")
local Column = require("../../src/wire/column")
local Gen = require("../support/gen")
local Ir = require("../../src/plan/ir")
local Lync = require("../../src")
local Rows = require("../../src/codec/rows")
local Run = require("../../src/codec/run")

-- Types -------------------------------------------------------------------------------------------

--[=[
	One refusal.

	@field codec the codec of the record's field `v`
	@field value the refused value of `v`
	@field path  the expected path, from `data`
]=]
type Case = { codec: any, value: any, path: string }

-- Constants ---------------------------------------------------------------------------------------

const SOURCE = debug.info(1, "s")
const SUBJECT = "arena.test:fire"

local t = Lync.types

-- Private -----------------------------------------------------------------------------------------

local function casesOf(): { [string]: Case }
	local part = Instance.new("Part")
	local model = Instance.new("Model")
	local oversize = t.custom({
		name = "oversize",
		version = 1,
		maxBits = 4,
		encode = function(w, value)
			Bits.write(w, 8, value)
		end,
		decode = function(r)
			return Bits.read(r, 8), 0
		end,
	})

	return {
		["bool, not a boolean"] = { codec = t.bool(), value = "yes", path = "data.v" },
		["int, a fraction"] = { codec = t.int(0, 100), value = 1.5, path = "data.v" },
		["int, above max"] = { codec = t.int(0, 100), value = 101, path = "data.v" },
		["int, below min"] = { codec = t.int(0, 100), value = -1, path = "data.v" },
		["int, a string"] = { codec = t.int(0, 100), value = "5", path = "data.v" },
		["int, NaN"] = { codec = t.int(0, 100), value = 0 / 0, path = "data.v" },
		["t.int(), past 2^52 - 1"] = { codec = t.int(), value = 2 ^ 52, path = "data.v" },
		["t.int(), below -2^52"] = { codec = t.int(), value = -2 ^ 52 - 2, path = "data.v" },
		["t.int(), a fraction"] = { codec = t.int(), value = 0.5, path = "data.v" },
		["number, above max"] = { codec = t.number(0, 1, 0.25), value = 1.01, path = "data.v" },
		["number, NaN"] = { codec = t.number(0, 1, 0.25), value = 0 / 0, path = "data.v" },
		["f32, NaN"] = { codec = t.f32(), value = 0 / 0, path = "data.v" },
		["f32, infinite"] = { codec = t.f32(), value = math.huge, path = "data.v" },
		["f32, beyond the f32 range"] = { codec = t.f32(), value = 1e39, path = "data.v" },
		["f64, infinite"] = { codec = t.f64(), value = -math.huge, path = "data.v" },
		["f64, NaN"] = { codec = t.f64(), value = 0 / 0, path = "data.v" },
		["angle, infinite"] = { codec = t.angle(0.1), value = math.huge, path = "data.v" },
		["angle, a string"] = { codec = t.angle(0.1), value = "x", path = "data.v" },
		["string, too long"] = { codec = t.string(3), value = "abcd", path = "data.v" },
		["string, a number"] = { codec = t.string(3), value = 3, path = "data.v" },
		["buffer, too long"] = {
			codec = t.buffer(2),
			value = buffer.create(3),
			path = "data.v",
		},
		["buffer, a string"] = { codec = t.buffer(2), value = "ab", path = "data.v" },
		["vector3, out of range"] = {
			codec = t.vector3(-1, 1, 0.5),
			value = Vector3.new(0, 2, 0),
			path = "data.v",
		},
		["vector3, NaN"] = {
			codec = t.vector3(-1, 1, 0.5),
			value = Vector3.new(0 / 0, 0, 0),
			path = "data.v",
		},
		["vector3, not a Vector3"] = { codec = t.vector3(-1, 1, 0.5), value = 1, path = "data.v" },
		["vector3f32, infinite"] = {
			codec = t.vector3f32(),
			value = Vector3.new(math.huge, 0, 0),
			path = "data.v",
		},
		["direction, zero"] = { codec = t.direction(10), value = Vector3.zero, path = "data.v" },
		["direction, NaN"] = {
			codec = t.direction(10),
			value = Vector3.new(0 / 0, 1, 0),
			path = "data.v",
		},
		["rotation, with a position"] = {
			codec = t.rotation(9),
			value = CFrame.new(1, 0, 0),
			path = "data.v",
		},
		["rotation, not a CFrame"] = { codec = t.rotation(9), value = Vector3.one, path = "data.v" },
		["cframe, not a CFrame"] = {
			codec = t.cframe(t.vector3(-8, 8, 1 / 8), t.rotation(9)),
			value = Vector3.one,
			path = "data.v",
		},
		["cframe, position out of range"] = {
			codec = t.cframe(t.vector3(-8, 8, 1 / 8), t.rotation(9)),
			value = CFrame.new(9, 0, 0),
			path = "data.v.position",
		},
		["color3, a channel above 1"] = {
			codec = t.color3(),
			value = Color3.new(1.5, 0, 0),
			path = "data.v",
		},
		["color3, not a Color3"] = { codec = t.color3(), value = "red", path = "data.v" },
		["enum, not an item"] = {
			codec = t.enum({ "sword", "shield" }),
			value = "axe",
			path = "data.v",
		},
		["Roblox enum, an item of another enum"] = {
			codec = t.enum(Enum.Material),
			value = Enum.KeyCode.A,
			path = "data.v",
		},
		["Roblox enum, a string"] = {
			codec = t.enum(Enum.Material),
			value = "Plastic",
			path = "data.v",
		},
		["instance, not an instance"] = { codec = t.instance(), value = {}, path = "data.v" },
		["instance, of another class"] = {
			codec = t.instance("BasePart"),
			value = model,
			path = "data.v",
		},
		["optional, a present value refused"] = {
			codec = t.optional(t.int(0, 3)),
			value = 4,
			path = "data.v",
		},
		["array, too many elements"] = {
			codec = t.array(t.bool(), 2),
			value = { true, true, true },
			path = "data.v",
		},
		["array, not a table"] = { codec = t.array(t.bool(), 2), value = true, path = "data.v" },
		["array, an element refused"] = {
			codec = t.array(t.int(0, 3), 9),
			value = { 1, 2, 7 },
			path = "data.v[]",
		},
		["array, an element refused in a column block"] = {
			codec = t.array({ x = t.int(0, 3) }, 9),
			value = table.create(Column.MIN_ROWS, { x = 9 }),
			path = "data.v[].x",
		},
		["map, too many pairs"] = {
			codec = t.map(t.int(0, 9), t.bool(), 2),
			value = { [1] = true, [2] = true, [3] = true },
			path = "data.v",
		},
		["map, a key of the wrong kind"] = {
			codec = t.map(t.int(0, 9), t.bool(), 4),
			value = { a = true },
			path = "data.v[key]",
		},
		["map, a key out of range"] = {
			codec = t.map(t.int(0, 9), t.bool(), 4),
			value = { [10] = true },
			path = "data.v[key]",
		},
		["map, an enum key not an item"] = {
			codec = t.map(t.enum({ "a", "b" }), t.bool(), 4),
			value = { c = true },
			path = "data.v[key]",
		},
		["map, a value refused"] = {
			codec = t.map(t.string(4), t.int(0, 1), 4),
			value = { a = 0, b = 2 },
			path = "data.v[]",
		},
		["union, an unknown kind"] = {
			codec = t.union({ round = { number = t.int(1, 99) } }),
			value = { kind = "draw" },
			path = "data.v.kind",
		},
		["union, not a table"] = {
			codec = t.union({ round = { number = t.int(1, 99) } }),
			value = "round",
			path = "data.v",
		},
		["union, a variant field refused"] = {
			codec = t.union({ round = { number = t.int(1, 99) } }),
			value = { kind = "round", number = 100 },
			path = "data.v.number",
		},
		["record, not a table"] = { codec = { x = t.bool() }, value = 1, path = "data.v" },
		["record, a missing field"] = { codec = { x = t.bool() }, value = {}, path = "data.v.x" },
		["custom, past its declared bits"] = { codec = oversize, value = 200, path = "data.v" },
		["convert, a base value refused"] = {
			codec = t.convert(t.int(0, 9), tostring, tonumber),
			value = "12",
			path = "data.v",
		},
		["instance, accepted beside a refusal"] = {
			codec = { a = t.instance(), b = t.bool() },
			value = { a = part, b = 0 },
			path = "data.v.b",
		},
	}
end

local function newWriter(): Bits.Writer
	local w = Bits.writer()
	Bits.write(w, 13, 0x1234)
	Bits.writeTail(w, "before")

	return w
end

local function snapshotOf(w: Bits.Writer): string
	return `{w.bit} {#w.tail} {w.tailBytes} {buffer.tostring(Bits.finish(w))}`
end

local function newInstances(): Rows.Instances
	return { list = {}, index = {} }
end

local function checkCase(name: string, case: Case, codec: Ir.Codec, count: number)
	local w = newWriter()
	local before = snapshotOf(w)
	local values = {}
	for i = 1, count do
		values[i] = { v = case.value }
	end

	local instances = newInstances()
	Run.collect(codec, values, count, instances)
	local line = debug.info(1, "l") + 2
	Check.expectThrow(function()
		Run.encode(w, codec, values, count, instances, SUBJECT)
	end, { code = "valueRefused", at = `{SOURCE}:{line}`, subject = SUBJECT, path = case.path })

	local after = snapshotOf(w)
	Check.expectEqual(after, before, `{name}, {count} rows: the writer`)
end

-- Tests -------------------------------------------------------------------------------------------

local tests = {}

for name, case in casesOf() do
	tests[`{name}: refused with its path, the writer unchanged`] = function()
		local codec = Gen.plan({ v = case.codec, w = t.bool() })
		for _, count in { 1, Column.MIN_ROWS - 1, Column.MIN_ROWS, 2 * Column.MIN_ROWS + 1 } do
			local ok, message = pcall(checkCase, name, case, codec, count)
			if not ok then
				error(`{count} rows: {message}`, 0)
			end
		end

		local w = newWriter()
		local before = snapshotOf(w)
		local line = debug.info(1, "l") + 2
		Check.expectThrow(function()
			Rows.encodeValue(w, codec, { v = case.value }, newInstances(), SUBJECT)
		end, { code = "valueRefused", at = `{SOURCE}:{line}`, subject = SUBJECT, path = case.path })
		Check.expectEqual(snapshotOf(w), before, "the writer")
	end
end

tests["valueRefused: arena.strike data.aim, a zero direction"] = function()
	local schema = Lync.schema("arena", {
		strike = Lync.event({
			from = "client",
			lane = "unreliable",
			data = { target = t.int(1, 2 ^ 40), aim = t.direction(11) },
		}),
	})
	local codec = (schema :: any).ir.byName.strike.data
	Check.expectThrow(function()
		Rows.encodeValue(
			Bits.writer(),
			codec,
			{ target = 5, aim = Vector3.zero },
			newInstances(),
			"arena.strike"
		)
	end, { code = "valueRefused", subject = "arena.strike", path = "data.aim" })
end

tests["an accepted value leaves the writer extended"] = function()
	local codec = Gen.plan({ v = t.int(0, 3) })
	local w = newWriter()
	local before = w.bit
	Rows.encodeValue(w, codec, { v = 3 }, newInstances(), SUBJECT)
	Check.expectEqual(w.bit, before + 2, "bits")
end

return tests
