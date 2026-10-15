--!strict

--[=[
	golden.spec

	The golden frames of v5.md §4.10 that milestone 1 reproduces through the interpreter: G2, G2b,
	G3, G4 and G8. Each is built with `Run.encode` for its payloads and `Frame` for the rest,
	compared byte for byte with its `.bin` file, then decoded from that file. Every vector the index
	gives to a later milestone is checked to be one.
]=]

-- Imports -----------------------------------------------------------------------------------------

local Bits = require("../../src/wire/bits")
local Check = require("../support/check")
local Frame = require("../support/frame")
local Golden = require("../support/golden")
local Ir = require("../../src/plan/ir")
local Quant = require("../../src/wire/quant")
local Rows = require("../../src/codec/rows")
local Run = require("../../src/codec/run")

-- Constants ---------------------------------------------------------------------------------------

const ARENA = 1
const LANE_RELIABLE = 0
const LANE_UNRELIABLE = 1
const REPRODUCED = { G2 = true, G2b = true, G3 = true, G4 = true, G8 = true }

-- Private -----------------------------------------------------------------------------------------

local function hexOf(bytes: buffer): string
	local digits = table.create(buffer.len(bytes), "")
	for i = 0, buffer.len(bytes) - 1 do
		digits[i + 1] = string.format("%02x", buffer.readu8(bytes, i))
	end

	return table.concat(digits, " ")
end

local function newInstances(): Rows.Instances
	return { list = {}, index = {} }
end

-- Writes a run chunk: its header, then its payloads through `Run`.
local function writeRun(
	w: Bits.Writer,
	entry: Ir.Entry,
	idWidth: number,
	codec: Ir.Codec,
	values: { any },
	subject: string
)
	local instances = newInstances()
	Run.collect(codec, values, #values, instances)
	Frame.writeRunHeader(w, entry.id, idWidth, #values, nil)
	Run.encode(w, codec, values, #values, instances, subject)
end

-- Writes a downstream reliable frame of one run segment of `arena`.
local function writeDownToc(w: Bits.Writer, tick: Frame.Tick)
	Frame.writeDownReliableHeader(w, tick)
	Frame.writeSegments(w, {})
	Frame.writeSegments(w, { { namespace = ARENA, chunks = 1 } })
	Frame.writeSegments(w, {})
	Bits.align(w)
end

local function readDownToc(r: Bits.Reader, tick: Frame.Tick)
	Check.expectEqual(Frame.readDownReliableHeader(r), tick, "tick")
	Check.expectEqual(Frame.readSegments(r), {}, "state segments")
	Check.expectEqual(Frame.readSegments(r), { { namespace = ARENA, chunks = 1 } }, "run segments")
	Check.expectEqual(Frame.readSegments(r), {}, "remove segments")
	Check.expect(Bits.readAlign(r), "chunk padding must be zero")
end

local function readRun(
	r: Bits.Reader,
	entry: Ir.Entry,
	idWidth: number,
	codec: Ir.Codec,
	expected: { any }
)
	local id, count = Frame.readRunHeader(r, idWidth, false)
	Check.expectEqual(id, entry.id, "id")
	Check.expectEqual(count, #expected, "count")

	local values = {}
	Check.expectEqual(Run.decode(r, codec, #expected, {}, values), 0, "rule")
	Check.expectEqual(values, expected, "values")
end

local function finish(r: Bits.Reader)
	Check.expect(Bits.meets(r), "bits and tail must meet")
end

local function announce(): (Ir.Namespace, Ir.Entry, Ir.Codec)
	local arena = Frame.arena()
	local entry = arena.down[1]
	Check.expectEqual(entry.definition.name, "announce")

	return arena, entry, entry.definition.data :: Ir.Codec
end

-- Tests -------------------------------------------------------------------------------------------

return {
	["G2: first reliable frame, announce round 3"] = function()
		local arena, entry, codec = announce()
		local values = { { kind = "round", number = 3 } }

		local w = Bits.writer()
		writeDownToc(w, 0)
		writeRun(w, entry, arena.downWidth, codec, values, "arena.announce:fire")
		Bits.align(w)
		local golden = Golden.bytes(Golden.entry("G2"))
		Check.expectBytes(Bits.finish(w), hexOf(golden))

		local r = Bits.reader(golden)
		readDownToc(r, 0)
		readRun(r, entry, arena.downWidth, codec, values)
		finish(r)
	end,

	["G2b: tick +1, a run of round 3 and winner blue"] = function()
		local arena, entry, codec = announce()
		local values = { { kind = "round", number = 3 }, { kind = "winner", team = "blue" } }

		local w = Bits.writer()
		writeDownToc(w, "next")
		writeRun(w, entry, arena.downWidth, codec, values, "arena.announce:fire")
		Bits.align(w)
		local golden = Golden.bytes(Golden.entry("G2b"))
		Check.expectBytes(Bits.finish(w), hexOf(golden))

		local r = Bits.reader(golden)
		readDownToc(r, "next")
		readRun(r, entry, arena.downWidth, codec, values)
		finish(r)
	end,

	["G3: answer to buy, slot 0, epoch 0, 250"] = function()
		local arena = Frame.arena()
		local entry = arena.down[2]
		Check.expectEqual(entry.definition.name, "buy")
		Check.expectEqual(entry.role, "answer")
		local codec = entry.definition.reply :: Ir.Codec

		local w = Bits.writer()
		writeDownToc(w, "unchanged")
		Frame.writeRunHeader(w, entry.id, arena.downWidth, 1, nil)
		Frame.writeAnswerPrefix(w, 0, 0, 0)
		Run.encode(w, codec, { 250 }, 1, newInstances(), "arena.buy:handle")
		Bits.align(w)
		local golden = Golden.bytes(Golden.entry("G3"))
		Check.expectBytes(Bits.finish(w), hexOf(golden))

		local r = Bits.reader(golden)
		readDownToc(r, "unchanged")
		local id, count = Frame.readRunHeader(r, arena.downWidth, false)
		Check.expectEqual({ id, count }, { entry.id, 1 }, "run header")
		local slot, epoch, outcome = Frame.readAnswerPrefix(r)
		Check.expectEqual({ slot, epoch, outcome }, { 0, 0, 0 }, "answer prefix")
		local values = {}
		Check.expectEqual(Run.decode(r, codec, 1, {}, values), 0, "rule")
		Check.expectEqual(values, { 250 }, "values")
		finish(r)
	end,

	["G4: chat gg, tagged"] = function()
		local arena = Frame.arena()
		local entry = arena.up[2]
		Check.expectEqual(entry.definition.name, "chat")
		local codec = entry.definition.data :: Ir.Codec

		local w = Bits.writer()
		Frame.writeUpReliableHeader(w)
		Frame.writeSegments(w, { { namespace = ARENA, chunks = 1 } })
		writeRun(w, entry, arena.upWidth, codec, { "gg" }, "arena.chat:fire")
		Bits.align(w)
		local golden = Golden.bytes(Golden.entry("G4"))
		local frame = Frame.tagged(Bits.finish(w), 0, LANE_RELIABLE, 0)
		Check.expectBytes(frame, hexOf(golden))

		local body = Frame.checkTag(golden, 0, LANE_RELIABLE, 0)
		Check.expect(body ~= nil, "the tag must match")
		local r = Bits.reader(body :: buffer)
		Check.expect(Frame.readUpReliableHeader(r), "ack must be '0'")
		Check.expectEqual(Frame.readSegments(r), { { namespace = ARENA, chunks = 1 } }, "segments")
		readRun(r, entry, arena.upWidth, codec, { "gg" })
		finish(r)
	end,

	["G8: four strikes as a column block, tagged"] = function()
		local arena = Frame.arena()
		local entry = arena.up[3]
		Check.expectEqual(entry.definition.name, "strike")
		local codec = entry.definition.data :: Ir.Codec
		local values = {}
		for _, target in { 5, 6, 7, 7 } do
			table.insert(values, { aim = Vector3.zAxis, target = target })
		end

		local w = Bits.writer()
		Frame.writeUpUnreliableHeader(w, 0)
		Frame.writeSegments(w, { { namespace = ARENA, chunks = 1 } })
		writeRun(w, entry, arena.upWidth, codec, values, "arena.strike:fire")
		Bits.align(w)
		local golden = Golden.bytes(Golden.entry("G8"))
		local frame = Frame.tagged(Bits.finish(w), 0, LANE_UNRELIABLE, 0)
		Check.expectBytes(frame, hexOf(golden))

		local body = Frame.checkTag(golden, 0, LANE_UNRELIABLE, 0)
		Check.expect(body ~= nil, "the tag must match")
		local r = Bits.reader(body :: buffer)
		Check.expectEqual(Frame.readUpUnreliableHeader(r), 0, "seq")
		Check.expectEqual(Frame.readSegments(r), { { namespace = ARENA, chunks = 1 } }, "segments")
		-- The aim's codes are 1024 of 0 to 2047, so it decodes just off the z axis.
		local aim = Vector3.new(Quant.undirection(1024, 1024, 11))
		local decoded = {}
		for i, value in values do
			decoded[i] = { aim = aim, target = value.target }
		end
		readRun(r, entry, arena.upWidth, codec, decoded)
		finish(r)
	end,

	["every frame vector is reproduced here or belongs to a later milestone"] = function()
		for _, entry in Golden.entries() do
			local id = entry.id
			local isFrame = entry.file ~= nil and string.match(id, "^G%d") ~= nil
			if not isFrame or id == "G9a" or id == "G9b" then
				continue
			end

			if entry.milestone == 1 then
				Check.expect(REPRODUCED[id] == true, `{id} is milestone 1 and must be reproduced`)
			else
				Check.expect(entry.milestone > 1, `{id} must name its milestone`)
			end
		end
	end,
}
