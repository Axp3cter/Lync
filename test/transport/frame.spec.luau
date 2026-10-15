--!strict

--[=[
	frame.spec

	Frames from chunks (v5.md §4.1, §4.2, §4.9): `Bits.copy` places bits at any offset; frames of
	every kind round-trip random chunk lists, downstream aligned and upstream packed, with tails
	in reverse chunk order and instance arrays in chunk order; a chunk copied into several frames
	decodes the same in each; `Frame.fits` splits exactly at the size limits; `Frame.open`
	refuses oversized frames (rule 8).
]=]

-- Imports -----------------------------------------------------------------------------------------

local process = require("@lune/process")

local Bits = require("../../src/wire/bits")
local Check = require("../support/check")
local Frame = require("../../src/transport/frame")
local FrameSupport = require("../support/frame")
local Frames = require("./frames")
local Header = require("../../src/transport/header")
local Ir = require("../../src/plan/ir")
local Prop = require("../support/prop")
local Tag = require("../../src/transport/tag")
local Toc = require("../../src/transport/toc")

-- Types -------------------------------------------------------------------------------------------

type Shape = { kind: Frame.Kind, down: boolean, lane: number }

-- Constants ---------------------------------------------------------------------------------------

const LANE_RELIABLE = 0
const LANE_UNRELIABLE = 1
const MODE_FULL = 2

const MAX_RELIABLE_BYTES = 16_384
const MAX_UNRELIABLE_BYTES = 1000
const MAX_RELIABLE_CHUNK_BYTES = 16_256
const MAX_UNRELIABLE_CHUNK_BYTES = 960

const RUNS = 200
const FULL_RUNS = 5000

const SHAPES: { Shape } = {
	{ kind = "reliable", down = true, lane = LANE_RELIABLE },
	{ kind = "event", down = true, lane = LANE_UNRELIABLE },
	{ kind = "state", down = true, lane = LANE_UNRELIABLE },
	{ kind = "upReliable", down = false, lane = LANE_RELIABLE },
	{ kind = "upUnreliable", down = false, lane = LANE_UNRELIABLE },
}

-- Private -----------------------------------------------------------------------------------------

local function runs(): number
	return if process.env.LYNC_FULL == "1" then FULL_RUNS else RUNS
end

-- A chunk of random bits and tail bytes, in the given toc list.
local function rawChunk(ns: number, list: number, bitLength: number, tailBytes: number): Frame.Chunk
	local w = Bits.writer()
	local written = 0
	while written < bitLength do
		local width = math.min(24, bitLength - written)
		Bits.write(w, width, math.random(0, 2 ^ width - 1))
		written += width
	end

	local tail = buffer.create(tailBytes)
	for i = 0, tailBytes - 1 do
		buffer.writeu8(tail, i, math.random(0, 255))
	end
	Bits.writeTail(w, tail)

	local instances: { Instance } = {}
	for i = 1, math.random(0, 2) do
		instances[i] = Instance.new("Folder")
	end

	return Frame.chunk(ns, list, w, instances)
end

-- Random raw chunks in toc order for a frame kind: runs (list 2), and for a reliable frame
-- state (1) and remove (3) chunks around them, for a state frame rows (4).
local function rawChunks(kind: Frame.Kind, size: number): { Frame.Chunk }
	local lists = if kind == "reliable" then { 1, 2, 3 } elseif kind == "state" then { 4 } else { 2 }
	local chunks = {}
	for _, list in lists do
		local ns = math.random(0, 2)
		for _ = 1, math.random(0, 1 + size // 15) do
			-- State and remove segments ascend; runs may name any namespace next.
			if math.random() < 0.5 then
				ns = if list == 1 or list == 3 then ns + 1 else math.random(0, 4)
			end
			table.insert(
				chunks,
				rawChunk(ns, list, math.random(1, 8 * size), math.random(0, size // 4))
			)
		end
	end

	return chunks
end

-- The toc the frame of chunks `first` to `last` must carry.
local function tocOf(
	kind: Frame.Kind,
	chunks: { Frame.Chunk },
	first: number,
	last: number
): { { Toc.Segment } }
	local lists = if kind == "reliable" then { {}, {}, {} } else { {} }
	local previous: Frame.Chunk? = nil
	for i = first, last do
		local chunk = chunks[i]
		local segments = lists[if kind == "reliable" then chunk.list else 1]
		if previous ~= nil and previous.list == chunk.list and previous.ns == chunk.ns then
			segments[#segments].count += 1
		else
			table.insert(segments, { ns = chunk.ns, count = 1 })
		end
		previous = chunk
	end

	return lists
end

-- Builds a frame with the kind's longest header; upstream, tagged with a zero tag.
local function build(
	shape: Shape,
	chunks: { Frame.Chunk },
	first: number,
	last: number
): (buffer, { Instance })
	if shape.down then
		return Frame.down(shape.kind, MODE_FULL, 0x1_2345, 0x6789, chunks, first, last)
	end

	local selected = table.move(chunks, first, last, 1, {})
	local seq = if shape.lane == LANE_UNRELIABLE then 0xabc else nil
	local body, instances = Frame.up(shape.lane, seq, { seq = 4095, received = 0xffff }, selected)

	return Tag.append(body, 0), instances
end

local function readHeader(r: Bits.Reader, shape: Shape)
	if shape.kind == "reliable" then
		Check.expectEqual({ Header.readDownReliable(r) }, { MODE_FULL, 0x2345, 0 }, "header")
	elseif shape.down then
		local isState = shape.kind == "state"
		local expected = { isState, if isState then 0x789 else 0, 0x45, 0 }
		Check.expectEqual({ Header.readDownUnreliable(r) }, expected, "header")
	else
		local seq, ack, rule = Header.readUp(r, shape.lane)
		Check.expectEqual(rule, 0, "header rule")
		Check.expectEqual(seq, if shape.lane == LANE_UNRELIABLE then 0xabc else nil, "seq")
		Check.expectEqual(ack, { seq = 4095, received = 0xffff }, "ack")
	end
end

-- Reads `bitLength` bits as bytes, the last zero-padded.
local function readBits(r: Bits.Reader, bitLength: number): buffer?
	local bytes = buffer.create((bitLength + 7) // 8)
	for i = 0, buffer.len(bytes) - 1 do
		local value = Bits.read(r, math.min(8, bitLength - 8 * i))
		if value == nil then
			return nil
		end
		buffer.writeu8(bytes, i, value)
	end

	return bytes
end

local function bigChunk(bytes: number, list: number): Frame.Chunk
	local w = Bits.writer()
	for _ = 1, bytes do
		Bits.write(w, 8, 0xa5)
	end

	return Frame.chunk(1, list, w, {})
end

-- A one-chunk frame of the kind padded to `bytes` with its longest header.
local function frameOfBytes(shape: Shape, bytes: number): ({ Frame.Chunk }, number)
	local list = if shape.kind == "state" then 4 else 2
	local probe = { bigChunk(1, list) }
	local overhead = buffer.len((build(shape, probe, 1, 1))) - 1
	local chunks = { bigChunk(bytes - overhead, list) }

	return chunks, buffer.len((build(shape, chunks, 1, 1)))
end

local function namespaces(): { [number]: Ir.Namespace }
	return { [1] = FrameSupport.arena(), [2] = Frames.probe() }
end

-- Tests -------------------------------------------------------------------------------------------

return {
	["Bits.copy appends bits at any offset as if written there"] = function()
		Prop.check("bits copy", function(size: number)
			local fields = {}
			for i = 1, math.random(0, size) do
				local width = math.random(0, 53)
				fields[i] = { width, math.floor(math.random() * 2 ^ width) }
			end
			return { offset = math.random(0, 40), fields = fields }
		end, function(case: { offset: number, fields: { { number } } })
			local source = Bits.writer()
			local direct = Bits.writer()
			local copied = Bits.writer()
			Bits.write(direct, case.offset, 2 ^ case.offset - 1)
			Bits.write(copied, case.offset, 2 ^ case.offset - 1)
			for _, field in case.fields do
				Bits.write(source, field[1], field[2])
				Bits.write(direct, field[1], field[2])
			end

			local bits = Bits.parts(source)
			Bits.copy(copied, bits, source.bit)
			Check.expectEqual(copied.bit, direct.bit, "bit")
			Check.expectEqual(Bits.finish(copied), Bits.finish(direct), "bytes")
		end)
	end,

	["frames of every kind round-trip random chunk lists"] = function()
		Prop.check("raw frames", function(size: number)
			local shape = SHAPES[math.random(1, #SHAPES)]
			return { shape = shape, chunks = rawChunks(shape.kind, size) }
		end, function(case: { shape: Shape, chunks: { Frame.Chunk } })
			local shape, chunks = case.shape, case.chunks
			local frame, instances = build(shape, chunks, 1, #chunks)
			-- Opened as reliable: these frames test layout, not the unreliable size limit.
			local r, rule = Frame.open(frame, shape.down, LANE_RELIABLE)
			Check.expectEqual(rule, 0, "open")
			local reader = r :: Bits.Reader

			readHeader(reader, shape)
			local lists = {}
			local listCount = if shape.kind == "reliable" then 3 else 1
			Check.expectEqual(Toc.read(reader, listCount, lists), 0, "toc rule")
			Check.expectEqual(lists, tocOf(shape.kind, chunks, 1, #chunks), "toc")

			local expectedInstances = {}
			for i, chunk in chunks do
				if shape.down then
					Check.expect(Bits.readAlign(reader), `chunk {i} padding`)
				end
				Check.expectEqual(readBits(reader, chunk.bitLength), chunk.bits, `chunk {i} bits`)
				table.move(
					chunk.instances,
					1,
					#chunk.instances,
					#expectedInstances + 1,
					expectedInstances
				)
			end
			Check.expect(Bits.readAlign(reader), "final padding")
			for i, chunk in chunks do
				local tail = Bits.readTail(reader, buffer.len(chunk.tail), true)
				Check.expectEqual(tail, chunk.tail, `chunk {i} tail`)
			end
			Check.expect(Bits.meets(reader), "bits and tail must meet")
			Check.expectEqual(instances, expectedInstances, "instances")
		end, { runs = runs() })
	end,

	["a chunk decodes the same alone and in every frame it is copied into"] = function()
		Prop.check("shared chunks", function(size: number)
			local shape = SHAPES[math.random(1, #SHAPES)]
			while shape.kind == "state" do
				shape = SHAPES[math.random(1, #SHAPES)]
			end
			return {
				shape = shape,
				chunks = Frames.chunks(shape.down, shape.lane, namespaces(), size),
			}
		end, function(case: { shape: Shape, chunks: { Frame.Chunk } })
			local shape, chunks = case.shape, case.chunks
			local context: Frames.Context = {
				down = shape.down,
				lane = shape.lane,
				namespaces = namespaces(),
				instances = {},
				budget = math.huge,
				firstWelcome = false,
			}

			local alone = {}
			for i, chunk in chunks do
				local rule, decoded = Frames.decodeChunk(chunk, context)
				Check.expectEqual(rule, 0, `chunk {i} alone`)
				alone[i] = decoded
			end

			-- The whole list, then every suffix: each chunk lands at another offset after
			-- other chunks, under the same and other headers.
			for first = 1, math.max(#chunks, 1) do
				local frame, instances = build(shape, chunks, first, #chunks)
				context.instances = instances :: any
				local rule, decodedChunks = Frames.decode(frame, context)
				Check.expectEqual(rule, 0, `frame from {first}`)
				Check.expectEqual(
					decodedChunks,
					table.move(alone, first, #chunks, 1, {}),
					`frame from {first}`
				)
			end
		end, { runs = runs() })
	end,

	["Frame.fits splits a chunk list exactly at the frame size limits"] = function()
		Prop.check("fits", function(size: number)
			local shape = SHAPES[math.random(1, #SHAPES)]
			local chunks = {}
			local isReliable = shape.kind == "reliable" or shape.kind == "upReliable"
			local maxChunkBytes = if isReliable then 3000 else 200
			for _, chunk in rawChunks(shape.kind, size) do
				table.insert(chunks, chunk)
			end
			for _ = 1, math.random(1, 12) do
				local list = if shape.kind == "state" then 4 else 2
				local bytes = math.random(1, maxChunkBytes)
				table.insert(
					chunks,
					rawChunk(
						math.random(0, 3),
						list,
						8 * bytes - math.random(0, 7),
						math.random(0, bytes // 8)
					)
				)
			end
			return { shape = shape, chunks = chunks }
		end, function(case: { shape: Shape, chunks: { Frame.Chunk } })
			local shape, chunks = case.shape, case.chunks
			local isReliable = shape.kind == "reliable" or shape.kind == "upReliable"
			local maxBytes = if isReliable then MAX_RELIABLE_BYTES else MAX_UNRELIABLE_BYTES
			local first = 1
			while first <= #chunks do
				local last = Frame.fits(shape.kind, chunks, first)
				Check.expect(last >= first, `chunk {first} fits an empty frame`)
				Check.expect(
					buffer.len((build(shape, chunks, first, last))) <= maxBytes,
					`frame {first} to {last}`
				)
				if last < #chunks then
					local over = buffer.len((build(shape, chunks, first, last + 1)))
					Check.expect(over > maxBytes, `frame {first} to {last + 1} is {over} B`)
				end
				first = last + 1
			end
		end, { runs = runs() })
	end,

	["a frame of exactly the limit fits, one byte more does not"] = function()
		for _, shape in SHAPES do
			local isReliable = shape.kind == "reliable" or shape.kind == "upReliable"
			local maxBytes = if isReliable then MAX_RELIABLE_BYTES else MAX_UNRELIABLE_BYTES

			local atLimit, atLimitBytes = frameOfBytes(shape, maxBytes)
			Check.expectEqual(atLimitBytes, maxBytes, `{shape.kind} at the limit`)
			Check.expectEqual(
				Frame.fits(shape.kind, atLimit, 1),
				1,
				`{shape.kind} at the limit fits`
			)

			local over, overBytes = frameOfBytes(shape, maxBytes + 1)
			Check.expectEqual(overBytes, maxBytes + 1, `{shape.kind} past the limit`)
			Check.expectEqual(Frame.fits(shape.kind, over, 1), 0, `{shape.kind} past the limit`)
		end
	end,

	["the largest chunk fits an empty frame of its lane"] = function()
		for _, shape in SHAPES do
			local isReliable = shape.kind == "reliable" or shape.kind == "upReliable"
			local chunkBytes = if isReliable
				then MAX_RELIABLE_CHUNK_BYTES
				else MAX_UNRELIABLE_CHUNK_BYTES
			local list = if shape.kind == "state" then 4 else 2
			local chunks = { bigChunk(chunkBytes, list), bigChunk(chunkBytes, list) }
			Check.expectEqual(Frame.fits(shape.kind, chunks, 1), 1, shape.kind)
			Check.expectEqual(Frame.fits(shape.kind, chunks, 3), 2, `{shape.kind}, none left`)
		end
	end,

	["Frame.open refuses frames over their size with rule 8"] = function()
		local function ruleOf(length: number, down: boolean, lane: number): number
			local _, rule = Frame.open(buffer.create(length), down, lane)
			return rule
		end

		Check.expectEqual(
			ruleOf(MAX_RELIABLE_BYTES, false, LANE_RELIABLE),
			0,
			"up reliable at the limit"
		)
		Check.expectEqual(
			ruleOf(MAX_RELIABLE_BYTES + 1, false, LANE_RELIABLE),
			8,
			"up reliable past it"
		)
		Check.expectEqual(
			ruleOf(MAX_UNRELIABLE_BYTES, false, LANE_UNRELIABLE),
			0,
			"up unreliable at the limit"
		)
		Check.expectEqual(
			ruleOf(MAX_UNRELIABLE_BYTES + 1, false, LANE_UNRELIABLE),
			8,
			"up unreliable past it"
		)
		Check.expectEqual(
			ruleOf(MAX_UNRELIABLE_BYTES, true, LANE_UNRELIABLE),
			0,
			"down unreliable at the limit"
		)
		Check.expectEqual(
			ruleOf(MAX_UNRELIABLE_BYTES + 1, true, LANE_UNRELIABLE),
			8,
			"down unreliable past it"
		)
		Check.expectEqual(
			ruleOf(2 * MAX_RELIABLE_BYTES, true, LANE_RELIABLE),
			0,
			"rule 8 names upstream reliable only"
		)
	end,

	["an upstream reader stops before the tag, and a frame too short for one is rule 4"] = function()
		for length = 0, 1 do
			local r, rule = Frame.open(buffer.create(length), false, LANE_RELIABLE)
			Check.expectEqual({ r, rule }, { nil, 4 }, `{length} bytes`)
		end

		local r = Frame.open(buffer.create(10), false, LANE_UNRELIABLE)
		Check.expectEqual((r :: Bits.Reader).stop, 8, "up stop")
		local down = Frame.open(buffer.create(10), true, LANE_RELIABLE)
		Check.expectEqual((down :: Bits.Reader).stop, 10, "down stop")
	end,
}
