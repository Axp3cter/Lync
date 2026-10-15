--!strict

--[=[
	Frames

	Test-only whole frames for the transport specs: a decoder that walks a frame with
	`src/transport` and the codec, refusing it with the first v5.md §4.8 rule it breaks, and a
	generator of random honest chunks for it.

	The decoder stands in for milestone 2's inbound pipeline where a frame's bytes alone decide
	the rule: ids outside their space, messages on the wrong lane, unwelcomed namespaces and
	control types in the wrong direction are rule 7; collection lists, which milestone 2 never
	sends, are rule 7 too. It checks no tag and holds no session state beyond one frame: the
	first `WELCOME` chunk's first row carries `First` when the caller says so.
]=]

-- Imports -----------------------------------------------------------------------------------------

local Bits = require("../../src/wire/bits")
local Control = require("../../src/transport/control")
local Frame = require("../../src/transport/frame")
local FrameSupport = require("../support/frame")
local Gen = require("../support/gen")
local Header = require("../../src/transport/header")
local Ints = require("../../src/wire/ints")
local Ir = require("../../src/plan/ir")
local Lync = require("../../src")
local Rows = require("../../src/codec/rows")
local Run = require("../../src/codec/run")
local Toc = require("../../src/transport/toc")

-- Module ------------------------------------------------------------------------------------------

local Frames = {}

-- Types -------------------------------------------------------------------------------------------

--[=[
	One decoded chunk.

	@field ns      the namespace index; 0 is control
	@field kind    the control type, nil for a run
	@field id      the run's id in its space, nil for control
	@field rows    the control rows, or the run's messages: values for events, `{ slot, epoch,
	               outcome, value }` for asks and answers
	@field misses  the run's values the receiver can't resolve
]=]
export type Decoded = {
	ns: number,
	kind: number?,
	id: number?,
	rows: { any },
	misses: { Rows.Miss },
}

--[=[
	What a frame is decoded against.

	@field down         whether the server sent it
	@field lane         the remote it came on
	@field namespaces   the welcomed namespaces by index
	@field instances    the call's instance array; an unreplicated instance is nil
	@field budget       the decode element allowance
	@field firstWelcome whether the frame's first `WELCOME` row carries `First`
]=]
export type Context = {
	down: boolean,
	lane: number,
	namespaces: { [number]: Ir.Namespace },
	instances: { Instance? },
	budget: number,
	firstWelcome: boolean,
}

-- Constants ---------------------------------------------------------------------------------------

const CONTROL = 0
const RUN_LIST = 2
const LANE_RELIABLE = 0
const LANE_UNRELIABLE = 1
const SLOT_BITS = 4
const EPOCH_BITS = 1
const OUTCOME_VALUE = 0
const MAX_OUTCOME = 2

--- The control types each direction may carry (v5.md §4.6).
const DOWN_CONTROL = { Control.WELCOME, Control.MISMATCH, Control.REKEY, Control.RATE }
const UP_CONTROL = { Control.HELLO, Control.REKEY_ACK, Control.REPORT, Control.BEACON }

local t = Lync.types

-- Private -----------------------------------------------------------------------------------------

-- A random integer in [0, max], for ranges past `math.random`'s 32 bits.
local function integerUpTo(max: number): number
	return math.floor(math.random() * (max + 1))
end

local function isDirectionOf(kind: number, down: boolean): boolean
	return table.find(if down then DOWN_CONTROL else UP_CONTROL, kind) ~= nil
end

-- Whether a run of the entry may travel on the lane (rule 7).
local function isLaneOf(entry: Ir.Entry, lane: number): boolean
	local definition = entry.definition
	local isUnreliable = definition.kind == "event" and definition.lane == "unreliable"

	return isUnreliable == (lane == LANE_UNRELIABLE)
end

local function readPrefixedRows(
	r: Bits.Reader,
	entry: Ir.Entry,
	count: number,
	chunk: Rows.Chunk,
	decoded: Decoded
): number
	if not Bits.charge(r, count) then
		return 10
	end

	local definition = entry.definition
	for row = 1, count do
		local slot = Bits.read(r, SLOT_BITS)
		local epoch = Bits.read(r, EPOCH_BITS)
		if slot == nil or epoch == nil then
			return 4
		end

		local outcome = OUTCOME_VALUE
		local codec = definition.data
		if entry.role == "answer" then
			local readOutcome = Bits.read(r, 2)
			if readOutcome == nil then
				return 4
			end
			if readOutcome > MAX_OUTCOME then
				return 2
			end
			outcome = readOutcome
			codec = if outcome == OUTCOME_VALUE then definition.reply else nil
		end

		local value = nil
		if codec ~= nil then
			local rowValue, rule = Rows.read(r, codec, chunk, row, decoded.misses)
			if rule ~= 0 then
				return rule
			end
			value = rowValue
		end
		decoded.rows[row] = { slot = slot, epoch = epoch, outcome = outcome, value = value }
	end

	return 0
end

local function readRun(
	r: Bits.Reader,
	ns: number,
	context: Context,
	offset: number
): (Decoded?, number, number)
	local namespace = context.namespaces[ns]
	if namespace == nil then
		return nil, 7, 0
	end

	local space = if context.down then namespace.down else namespace.up
	local width = if context.down then namespace.downWidth else namespace.upWidth
	local id = Bits.read(r, width)
	if id == nil then
		return nil, 4, 0
	end

	local entry = space[id + 1]
	if entry == nil or not isLaneOf(entry, context.lane) then
		return nil, 7, 0
	end

	local countLessOne, countRule = Ints.readEg(r, 0)
	if countLessOne == nil then
		return nil, countRule, 0
	end

	local instanceCount = 0
	if entry.definition.hasInstances then
		local readCount, instanceRule = Ints.readEg(r, 0)
		if readCount == nil then
			return nil, instanceRule, 0
		end
		instanceCount = readCount
	end

	local decoded: Decoded = { ns = ns, id = id, rows = {}, misses = {} }
	local chunk = Rows.beginChunk(context.instances, offset, instanceCount)
	local rule = if entry.role == "event"
		then Run.decode(
			r,
			entry.definition.data :: Ir.Codec,
			countLessOne + 1,
			chunk,
			decoded.misses,
			decoded.rows
		)
		else readPrefixedRows(r, entry, countLessOne + 1, chunk, decoded)
	if rule == 0 then
		rule = Rows.endChunk(chunk)
	end
	if rule ~= 0 then
		return nil, rule, 0
	end

	return decoded, 0, instanceCount
end

-- Decodes one chunk: its namespace's run, or a control chunk. Returns the instance entries it
-- used.
local function readChunk(
	r: Bits.Reader,
	ns: number,
	context: Context,
	offset: number
): (Decoded?, number, number)
	if ns ~= CONTROL then
		return readRun(r, ns, context, offset)
	end

	if context.lane ~= LANE_RELIABLE then
		return nil, 7, 0
	end

	local rows = {}
	local kind, rule = Control.read(r, context.firstWelcome, rows)
	if kind == nil then
		return nil, rule, 0
	end

	if not isDirectionOf(kind, context.down) then
		return nil, 7, 0
	end

	if kind == Control.WELCOME then
		context.firstWelcome = false
	end

	return { ns = CONTROL, kind = kind, rows = rows, misses = {} }, 0, 0
end

local function readHeader(r: Bits.Reader, context: Context): (number, number)
	if not context.down then
		local _, _, rule = Header.readUp(r, context.lane)
		return rule, 1
	end

	if context.lane == LANE_RELIABLE then
		local _, _, rule = Header.readDownReliable(r)
		return rule, 3
	end

	local isState, _, _, rule = Header.readDownUnreliable(r)
	if isState then
		return 7, 1
	end

	return rule, 1
end

-- A random value of each type of control row the direction carries.
local function controlRowOf(kind: number, size: number): any
	if kind == Control.HELLO then
		local name = {}
		for i = 1, math.random(1, math.min(64, size + 1)) do
			name[i] = string.char(math.random(0, 255))
		end
		return {
			version = math.random(0, 255),
			seed = integerUpTo(2 ^ 32 - 1),
			hashLow = integerUpTo(2 ^ 32 - 1),
			hashHigh = integerUpTo(2 ^ 32 - 1),
			name = table.concat(name),
		}
	elseif kind == Control.WELCOME then
		return { index = math.random(1, 2 ^ 20) }
	elseif kind == Control.REKEY then
		return { keyLow = integerUpTo(2 ^ 32 - 1), keyHigh = integerUpTo(2 ^ 32 - 1) }
	elseif kind == Control.REPORT then
		return {
			probes = integerUpTo(2 ^ 31),
			identitySucceeded = math.random(0, 1000),
			sourceUnlisted = math.random(0, 3),
			refusedFrames = integerUpTo(2 ^ 40),
		}
	elseif kind == Control.BEACON then
		return math.random(0, 0xffff)
	elseif kind == Control.RATE then
		return { epoch = (math.random() - 0.5) * 2 ^ 40, stateRate = math.random(10, 60) }
	end

	return true
end

local function controlChunkOf(down: boolean, size: number): Frame.Chunk
	local kinds = if down then DOWN_CONTROL else UP_CONTROL
	local kind = kinds[math.random(1, #kinds)]
	local rows = {}
	for i = 1, math.random(1, 3) do
		rows[i] = controlRowOf(kind, size)
	end

	local w = Bits.writer()
	Control.write(w, kind, rows)

	return Frame.chunk(CONTROL, RUN_LIST, w, {})
end

local function runChunkOf(
	ns: number,
	namespace: Ir.Namespace,
	entry: Ir.Entry,
	down: boolean,
	size: number
): Frame.Chunk
	local definition = entry.definition
	local style = Gen.style({ Instance.new("Part"), Instance.new("Part"), Instance.new("Folder") })
	local count = math.random(1, if entry.role == "event" then 6 else 2)
	local width = if down then namespace.downWidth else namespace.upWidth
	local instances: Rows.Instances = { list = {}, index = {}, count = 0 }
	local w = Bits.writer()

	if entry.role == "event" then
		local codec = definition.data :: Ir.Codec
		local values = {}
		for i = 1, count do
			values[i] = Gen.value(codec, size, style)
		end
		Run.collect(codec, values, count, instances)
		FrameSupport.writeRunHeader(
			w,
			entry.id,
			width,
			count,
			if definition.hasInstances then #instances.list else nil
		)
		Run.encode(w, codec, values, count, instances, "test.run:fire", "data")

		return Frame.chunk(ns, RUN_LIST, w, instances.list)
	end

	local isAnswer = entry.role == "answer"
	local codec = (if isAnswer then definition.reply else definition.data) :: Ir.Codec
	local values = {}
	for i = 1, count do
		values[i] = Gen.value(codec, size, style)
		Rows.collect(codec, values[i], instances)
	end
	FrameSupport.writeRunHeader(
		w,
		entry.id,
		width,
		count,
		if definition.hasInstances then #instances.list else nil
	)
	for i = 1, count do
		Bits.write(w, SLOT_BITS, math.random(0, 15))
		Bits.write(w, EPOCH_BITS, math.random(0, 1))
		if isAnswer then
			Bits.write(w, 2, OUTCOME_VALUE)
		end
		Rows.encodeValue(
			w,
			codec,
			values[i],
			instances,
			"test.run:fire",
			if isAnswer then "reply" else "data"
		)
	end

	return Frame.chunk(ns, RUN_LIST, w, instances.list)
end

-- Public ------------------------------------------------------------------------------------------

--[=[
	Generates random honest chunks for one kind of frame, in toc order.

	@param  down       whether the server sends them
	@param  lane       the remote they go on
	@param  namespaces the namespaces by index
	@param  size       how many chunks, and how large values, may grow
	@return the chunks
]=]
function Frames.chunks(
	down: boolean,
	lane: number,
	namespaces: { [number]: Ir.Namespace },
	size: number
): { Frame.Chunk }
	local candidates = {}
	for ns, namespace in namespaces do
		for _, entry in if down then namespace.down else namespace.up do
			if isLaneOf(entry, lane) then
				table.insert(candidates, { ns = ns, namespace = namespace, entry = entry })
			end
		end
	end

	local chunks = {}
	for i = 1, math.random(0, 1 + size // 10) do
		if lane == LANE_RELIABLE and math.random() < 0.25 then
			chunks[i] = controlChunkOf(down, size)
			continue
		end

		local candidate = candidates[math.random(1, #candidates)]
		chunks[i] = runChunkOf(candidate.ns, candidate.namespace, candidate.entry, down, size)
	end

	return chunks
end

--[=[
	Decodes a whole frame.

	@param  frame   the frame, untagged downstream; upstream, its last two bytes are the tag
	@param  context what the frame is decoded against; `firstWelcome` is updated
	@return 0, or the first v5.md §4.8 rule the frame breaks
	@return the decoded chunks in frame order, when the rule is 0
]=]
function Frames.decode(frame: buffer, context: Context): (number, { Decoded })
	local r, openRule = Frame.open(frame, context.down, context.lane)
	if r == nil then
		return openRule, {}
	end
	r.budget = context.budget

	local headerRule, listCount = readHeader(r, context)
	if headerRule ~= 0 then
		return headerRule, {}
	end

	local lists: { { Toc.Segment } } = {}
	local tocRule = Toc.read(r, listCount, lists)
	if tocRule ~= 0 then
		return tocRule, {}
	end

	if listCount == 3 and (#lists[1] > 0 or #lists[3] > 0) then
		return 7, {}
	end

	local decodedChunks = {}
	local offset = 0
	for _, segment in lists[if listCount == 3 then RUN_LIST else 1] do
		for _ = 1, segment.count do
			if context.down and not Bits.readAlign(r) then
				return 4, {}
			end

			local decoded, rule, used = readChunk(r, segment.ns, context, offset)
			if decoded == nil then
				return rule, {}
			end
			table.insert(decodedChunks, decoded)
			offset += used
		end
	end

	if context.down and not Bits.readAlign(r) then
		return 4, {}
	end

	if not Bits.meets(r) then
		return 4, {}
	end

	if #context.instances > offset then
		return 9, {}
	end

	return 0, decodedChunks
end

--[=[
	Decodes one chunk alone, from its bits and tail, as if it were the only chunk of a frame.

	@param  chunk   the chunk
	@param  context what it is decoded against; `instances` is replaced by the chunk's own
	@return 0, or the rule
	@return the decoded chunk, when the rule is 0
]=]
function Frames.decodeChunk(chunk: Frame.Chunk, context: Context): (number, Decoded?)
	local bitBytes = buffer.len(chunk.bits)
	local bytes = buffer.create(bitBytes + buffer.len(chunk.tail))
	buffer.copy(bytes, 0, chunk.bits)
	buffer.copy(bytes, bitBytes, chunk.tail)

	local r = Bits.reader(bytes, 0, nil, context.budget)
	local chunkContext = table.clone(context)
	-- An instance list is an instance array with no unreplicated entries.
	chunkContext.instances = chunk.instances :: any
	local decoded, rule = readChunk(r, chunk.ns, chunkContext, 0)
	if decoded == nil then
		return rule, nil
	end

	if not Bits.meets(r) then
		return 4, nil
	end

	return 0, decoded
end

--[=[
	Plans `probe`, a namespace whose messages can break the payload rules `arena`'s can't: map
	keys (rule 5), instance lists (rule 9) and refused values (rule 3), both ways, plus an
	unreliable server event.

	@return its IR
]=]
function Frames.probe(): Ir.Namespace
	local schema = Lync.schema("probe", {
		tally = Lync.event({ from = "client", data = t.map(t.string(8), t.int(0, 100), 10) }),
		point = Lync.event({ from = "client", data = t.array(t.instance(), 4) }),
		reading = Lync.event({ from = "client", data = t.f64() }),
		shown = Lync.event({ from = "server", data = t.array(t.instance(), 4) }),
		scores = Lync.event({ from = "server", data = t.map(t.string(8), t.int(0, 100), 10) }),
		blip = Lync.event({ from = "server", lane = "unreliable", data = t.int(0, 7) }),
	})

	return (schema :: any).ir
end

return table.freeze(Frames)
