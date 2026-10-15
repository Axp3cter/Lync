--!strict

--[=[
	golden.spec

	The golden frames of v5.md §4.10 and m2-plan.md §5, built by `src/transport` around payloads
	from `Run.encode`, compared byte for byte with their `.bin` files, then decoded from those
	files. Run chunk headers and answer-row prefixes come from `support/frame`, since the
	transport leaves them to the session. The id permutation vector is checked the same way.
]=]

-- Imports -----------------------------------------------------------------------------------------

local Bits = require("../../src/wire/bits")
local Check = require("../support/check")
local Control = require("../../src/transport/control")
local Frame = require("../../src/transport/frame")
local FrameSupport = require("../support/frame")
local Golden = require("../support/golden")
local Header = require("../../src/transport/header")
local Ir = require("../../src/plan/ir")
local Lync = require("../../src")
local Permutation = require("../../src/session/permutation")
local Quant = require("../../src/wire/quant")
local Rows = require("../../src/codec/rows")
local Run = require("../../src/codec/run")
local Tag = require("../../src/transport/tag")
local Toc = require("../../src/transport/toc")

-- Constants ---------------------------------------------------------------------------------------

const ARENA = 1
const CONTROL = 0
const RUN_LIST = 2
const LANE_RELIABLE = 0
const LANE_UNRELIABLE = 1
const MODE_UNCHANGED = 0
const MODE_NEXT = 1
const MODE_FULL = 2

const TAG_KEY = buffer.fromstring("\0\1\2\3\4\5\6\7")
const TAG_COVER = 1024

const REPRODUCED = {
	G2 = true,
	G2b = true,
	G3 = true,
	G4 = true,
	G5 = true,
	G7 = true,
	G8 = true,
	G10 = true,
	G11 = true,
}

local t = Lync.types

-- Private -----------------------------------------------------------------------------------------

local function hexOf(bytes: buffer): string
	local digits = table.create(buffer.len(bytes), "")
	for i = 0, buffer.len(bytes) - 1 do
		digits[i + 1] = string.format("%02x", buffer.readu8(bytes, i))
	end

	return table.concat(digits, " ")
end

local function goldenOf(id: string): buffer
	return Golden.bytes(Golden.entry(id))
end

-- Decodes a run chunk with no instances: its payloads, then the chunk's rule 9 check.
local function decode(r: Bits.Reader, codec: Ir.Codec, count: number, out: { any }): number
	local chunk = Rows.beginChunk({}, 0, 0)
	local rule = Run.decode(r, codec, count, chunk, {}, out)
	if rule ~= 0 then
		return rule
	end

	return Rows.endChunk(chunk)
end

local function newInstances(): Rows.Instances
	return { list = {}, index = {}, count = 0 }
end

-- A run chunk of `arena`: its header, then its payloads through `Run`.
local function runChunk(
	entry: Ir.Entry,
	idWidth: number,
	codec: Ir.Codec,
	values: { any },
	subject: string
): Frame.Chunk
	local instances = newInstances()
	Run.collect(codec, values, #values, instances)
	local w = Bits.writer()
	FrameSupport.writeRunHeader(w, entry.id, idWidth, #values, nil)
	Run.encode(w, codec, values, #values, instances, subject, "data")

	return Frame.chunk(ARENA, RUN_LIST, w, instances.list)
end

local function controlChunk(kind: number, rows: { any }): Frame.Chunk
	local w = Bits.writer()
	Control.write(w, kind, rows)

	return Frame.chunk(CONTROL, RUN_LIST, w, {})
end

local function downReliable(mode: number, tick: number, chunk: Frame.Chunk): buffer
	local frame, instances = Frame.down("reliable", mode, tick, nil, { chunk }, 1, 1)
	Check.expectEqual(instances, {}, "instances")

	return frame
end

local function tagged(body: buffer, count: number, lane: number): buffer
	local tag = Tag.compute(TAG_KEY, count, lane, body, buffer.len(body), 0, TAG_COVER)

	return Tag.append(body, tag)
end

-- Opens a downstream reliable frame and reads its header and toc: one run segment.
local function openDown(golden: buffer, mode: number, tick: number, ns: number): Bits.Reader
	local r, rule = Frame.open(golden, true, LANE_RELIABLE)
	Check.expectEqual(rule, 0, "open rule")
	local reader = r :: Bits.Reader

	local readMode, readTick, headerRule = Header.readDownReliable(reader)
	Check.expectEqual({ readMode, readTick, headerRule }, { mode, tick, 0 }, "header")

	local lists = {}
	Check.expectEqual(Toc.read(reader, 3, lists), 0, "toc rule")
	Check.expectEqual(lists, { {}, { { ns = ns, count = 1 } }, {} }, "toc")
	Check.expect(Bits.readAlign(reader), "chunk padding must be zero")

	return reader
end

-- Opens a tagged upstream frame, checks its tag at `count`, and reads its header.
local function openUp(
	golden: buffer,
	lane: number,
	count: number
): (Bits.Reader, number?, Header.Ack?)
	local r, rule = Frame.open(golden, false, lane)
	Check.expectEqual(rule, 0, "open rule")
	local reader = r :: Bits.Reader

	local expected = Tag.compute(TAG_KEY, count, lane, golden, reader.stop, 0, TAG_COVER)
	Check.expectEqual(Tag.read(golden), expected, "tag")

	local seq, ack, headerRule = Header.readUp(reader, lane)
	Check.expectEqual(headerRule, 0, "header rule")

	return reader, seq, ack
end

local function readToc(r: Bits.Reader, expected: { Toc.Segment })
	local lists = {}
	Check.expectEqual(Toc.read(r, 1, lists), 0, "toc rule")
	Check.expectEqual(lists, { expected }, "toc")
end

local function readRun(
	r: Bits.Reader,
	entry: Ir.Entry,
	idWidth: number,
	codec: Ir.Codec,
	expected: { any }
)
	local id, count = FrameSupport.readRunHeader(r, idWidth, false)
	Check.expectEqual(id, entry.id, "id")
	Check.expectEqual(count, #expected, "count")

	local values = {}
	Check.expectEqual(decode(r, codec, #expected, values), 0, "rule")
	Check.expectEqual(values, expected, "values")
end

local function finishDown(r: Bits.Reader)
	Check.expect(Bits.readAlign(r), "final padding must be zero")
	Check.expect(Bits.meets(r), "bits and tail must meet")
end

local function finishUp(r: Bits.Reader)
	Check.expect(Bits.meets(r), "bits and tail must meet")
end

local function announce(): (Ir.Namespace, Ir.Entry, Ir.Codec)
	local arena = FrameSupport.arena()
	local entry = arena.down[1]
	Check.expectEqual(entry.definition.name, "announce")

	return arena, entry, entry.definition.data :: Ir.Codec
end

-- The `HELLO` of G7: G6's schema, `arena` with only `chat`.
local function chatOnlyHello(): Control.Hello
	local schema = Lync.schema("arena", {
		chat = Lync.event({ from = "client", data = t.string(200) }),
	})
	local ir: Ir.Namespace = (schema :: any).ir

	return { version = 1, seed = 0, hashLow = ir.hashLow, hashHigh = ir.hashHigh, name = "arena" }
end

local function firstWelcome(): Control.Welcome
	return {
		index = ARENA,
		first = {
			epoch = 1000.5,
			stateRate = 20,
			keyLow = 0x0302_0100,
			keyHigh = 0x0706_0504,
			cover = TAG_COVER,
			permutationSeed = 0,
			probeOneIn = 0,
			probeMaxPerSecond = 0,
			beacon = 0,
		},
	}
end

-- Tests -------------------------------------------------------------------------------------------

return {
	["G2: first reliable frame, announce round 3"] = function()
		local arena, entry, codec = announce()
		local values = { { kind = "round", number = 3 } }
		local golden = goldenOf("G2")

		local chunk = runChunk(entry, arena.downWidth, codec, values, "arena.announce:fire")
		Check.expectBytes(downReliable(MODE_FULL, 0, chunk), hexOf(golden))

		local r = openDown(golden, MODE_FULL, 0, ARENA)
		readRun(r, entry, arena.downWidth, codec, values)
		finishDown(r)
	end,

	["G2b: tick +1, a run of round 3 and winner blue"] = function()
		local arena, entry, codec = announce()
		local values = { { kind = "round", number = 3 }, { kind = "winner", team = "blue" } }
		local golden = goldenOf("G2b")

		local chunk = runChunk(entry, arena.downWidth, codec, values, "arena.announce:fire")
		Check.expectBytes(downReliable(MODE_NEXT, 1, chunk), hexOf(golden))

		local r = openDown(golden, MODE_NEXT, 0, ARENA)
		readRun(r, entry, arena.downWidth, codec, values)
		finishDown(r)
	end,

	["G3: answer to buy, slot 0, epoch 0, 250"] = function()
		local arena = FrameSupport.arena()
		local entry = arena.down[2]
		Check.expectEqual(entry.definition.name, "buy")
		Check.expectEqual(entry.role, "answer")
		local codec = entry.definition.reply :: Ir.Codec
		local golden = goldenOf("G3")

		local w = Bits.writer()
		FrameSupport.writeRunHeader(w, entry.id, arena.downWidth, 1, nil)
		FrameSupport.writeAnswerPrefix(w, 0, 0, 0)
		Run.encode(w, codec, { 250 }, 1, newInstances(), "arena.buy:handle", "reply")
		local chunk = Frame.chunk(ARENA, RUN_LIST, w, {})
		Check.expectBytes(downReliable(MODE_UNCHANGED, 0, chunk), hexOf(golden))

		local r = openDown(golden, MODE_UNCHANGED, 0, ARENA)
		local id, count = FrameSupport.readRunHeader(r, arena.downWidth, false)
		Check.expectEqual({ id, count }, { entry.id, 1 }, "run header")
		local slot, epoch, outcome = FrameSupport.readAnswerPrefix(r)
		Check.expectEqual({ slot, epoch, outcome }, { 0, 0, 0 }, "answer prefix")
		local values = {}
		Check.expectEqual(decode(r, codec, 1, values), 0, "rule")
		Check.expectEqual(values, { 250 }, "values")
		finishDown(r)
	end,

	["G4: chat gg, tagged"] = function()
		local arena = FrameSupport.arena()
		local entry = arena.up[2]
		Check.expectEqual(entry.definition.name, "chat")
		local codec = entry.definition.data :: Ir.Codec
		local golden = goldenOf("G4")

		local chunk = runChunk(entry, arena.upWidth, codec, { "gg" }, "arena.chat:fire")
		local body, instances = Frame.up(LANE_RELIABLE, nil, nil, { chunk })
		Check.expectEqual(instances, {}, "instances")
		Check.expectBytes(tagged(body, 0, LANE_RELIABLE), hexOf(golden))

		local r, seq, ack = openUp(golden, LANE_RELIABLE, 0)
		Check.expectEqual({ seq, ack }, {}, "no seq, ack '0'")
		readToc(r, { { ns = ARENA, count = 1 } })
		readRun(r, entry, arena.upWidth, codec, { "gg" })
		finishUp(r)
	end,

	["G5: ack-only, state seq 5 received with 4 and 3, tagged"] = function()
		local golden = goldenOf("G5")
		local ack = { seq = 5, received = 0b11 }

		local body = Frame.up(LANE_UNRELIABLE, 0, ack, {})
		Check.expectBytes(tagged(body, 0, LANE_UNRELIABLE), hexOf(golden))

		local r, seq, readAck = openUp(golden, LANE_UNRELIABLE, 0)
		Check.expectEqual(seq, 0, "seq")
		Check.expectEqual(readAck, ack, "ack")
		readToc(r, {})
		finishUp(r)
	end,

	["G7: untagged HELLO for G6's schema"] = function()
		local hello = chatOnlyHello()
		local golden = goldenOf("G7")

		local body = Frame.up(LANE_RELIABLE, nil, nil, { controlChunk(Control.HELLO, { hello }) })
		Check.expectBytes(body, hexOf(golden))

		local r = Bits.reader(golden)
		local seq, ack, headerRule = Header.readUp(r, LANE_RELIABLE)
		Check.expectEqual({ seq, ack, headerRule }, { nil, nil, 0 }, "header")
		readToc(r, { { ns = CONTROL, count = 1 } })
		local rows = {}
		local kind, rule = Control.read(r, false, rows)
		Check.expectEqual({ kind, rule }, { Control.HELLO, 0 }, "control")
		Check.expectEqual(rows, { hello }, "rows")
		finishUp(r)
	end,

	["G8: four strikes as a column block, tagged"] = function()
		local arena = FrameSupport.arena()
		local entry = arena.up[3]
		Check.expectEqual(entry.definition.name, "strike")
		local codec = entry.definition.data :: Ir.Codec
		local values = {}
		for _, target in { 5, 6, 7, 7 } do
			table.insert(values, { aim = Vector3.zAxis, target = target })
		end
		local golden = goldenOf("G8")

		local chunk = runChunk(entry, arena.upWidth, codec, values, "arena.strike:fire")
		local body = Frame.up(LANE_UNRELIABLE, 0, nil, { chunk })
		Check.expectBytes(tagged(body, 0, LANE_UNRELIABLE), hexOf(golden))

		local r, seq, ack = openUp(golden, LANE_UNRELIABLE, 0)
		Check.expectEqual({ seq, ack }, { 0 }, "seq 0, ack '0'")
		readToc(r, { { ns = ARENA, count = 1 } })
		-- The aim's codes are 1024 of 0 to 2047, so it decodes just off the z axis.
		local aim = Vector3.new(Quant.undirection(1024, 1024, 11))
		local decoded = {}
		for i, value in values do
			decoded[i] = { aim = aim, target = value.target }
		end
		readRun(r, entry, arena.upWidth, codec, decoded)
		finishUp(r)
	end,

	["G10: first reliable frame holding the connection's first WELCOME"] = function()
		local welcome = firstWelcome()
		local golden = goldenOf("G10")

		local chunk = controlChunk(Control.WELCOME, { welcome })
		Check.expectBytes(downReliable(MODE_FULL, 0, chunk), hexOf(golden))

		local r = openDown(golden, MODE_FULL, 0, CONTROL)
		local rows = {}
		local kind, rule = Control.read(r, true, rows)
		Check.expectEqual({ kind, rule }, { Control.WELCOME, 0 }, "control")
		Check.expectEqual(rows, { welcome }, "rows")
		finishDown(r)
	end,

	["G11: tick unchanged, one MISMATCH"] = function()
		local golden = goldenOf("G11")

		local chunk = controlChunk(Control.MISMATCH, { true })
		Check.expectBytes(downReliable(MODE_UNCHANGED, 0, chunk), hexOf(golden))

		local r = openDown(golden, MODE_UNCHANGED, 0, CONTROL)
		local rows = {}
		local kind, rule = Control.read(r, false, rows)
		Check.expectEqual({ kind, rule }, { Control.MISMATCH, 0 }, "control")
		Check.expectEqual(rows, { true }, "rows")
		finishDown(r)
	end,

	["PERM-12345678: the id permutation for seed 0x12345678 over 5 ids"] = function()
		local golden = goldenOf("PERM-12345678")
		local forward, inverse = Permutation.build(0x1234_5678, 0x158b_86ab, 1, 5)

		local bytes = buffer.create(#forward)
		for i, wireId in forward do
			buffer.writeu8(bytes, i - 1, wireId)
		end
		Check.expectBytes(bytes, hexOf(golden))
		for canonical, wireId in forward do
			Check.expectEqual(inverse[wireId + 1], canonical - 1, `inverse of {wireId}`)
		end
	end,

	["every frame vector of milestones 1 and 2 is reproduced here"] = function()
		for _, entry in Golden.entries() do
			local id = entry.id
			local isFrame = entry.file ~= nil and string.match(id, "^G%d") ~= nil
			if not isFrame or id == "G9a" or id == "G9b" then
				continue
			end

			if entry.milestone <= 2 then
				Check.expect(
					REPRODUCED[id] == true,
					`{id} is milestone {entry.milestone} and must be reproduced`
				)
			end
		end
	end,
}
