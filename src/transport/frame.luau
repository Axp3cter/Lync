--!strict

--[=[
	Frame

	Frames from chunks, and the size limits that split them (v5.md §4.1, §4.2, §4.9).

	A chunk is encoded once into its own writer and kept as its bits and its tail segment, so a
	chunk addressed to several players is copied into each one's frame. Downstream, every chunk
	starts on a byte boundary and is placed with `buffer.copy`; upstream, chunks are packed bit
	by bit with no alignment. A frame's tail is its chunks' tail segments in reverse chunk order,
	and its instance array is their instance lists in chunk order.

	Upstream frames are built untagged; the session appends the tag (`Tag`).
]=]

-- Imports -----------------------------------------------------------------------------------------

local Bits = require("../wire/bits")
local Header = require("./header")
local Host = require("../host/host")
local Ints = require("../wire/ints")
local Toc = require("./toc")

-- Module ------------------------------------------------------------------------------------------

local Frame = {}

-- Types -------------------------------------------------------------------------------------------

--[=[
	One encoded chunk.

	@field ns        the namespace index; 0 is control
	@field list      the toc list it belongs to: 1 state, 2 run, 3 remove, 4 rows
	@field bits      the chunk's bits, zero-padded to a byte boundary
	@field bitLength how many of `bits` are the chunk's
	@field tail      the chunk's tail segment, its values in reverse decode order
	@field instances the chunk's instance list, in order of first reference
]=]
export type Chunk = {
	ns: number,
	list: number,
	bits: buffer,
	bitLength: number,
	tail: buffer,
	instances: { Instance },
}

--[=[
	What a frame is: a downstream reliable frame, a downstream unreliable event or state frame,
	or an upstream frame on either lane.
]=]
export type Kind = "reliable" | "event" | "state" | "upReliable" | "upUnreliable"

-- Constants ---------------------------------------------------------------------------------------

const LANE_RELIABLE = 0
const LANE_UNRELIABLE = 1

--- The largest reliable frame, both directions, and the largest unreliable frame, tag included.
const MAX_RELIABLE_BYTES = 16_384
const MAX_UNRELIABLE_BYTES = 1000

const TAG_BYTES = 2
const TICK8_RANGE = 0x100

--- How many toc lists a downstream reliable frame has; every other kind has one.
const RELIABLE_LIST_COUNT = 3

--- Each kind's longest header, in bits: a full tick, a state seq, a non-empty ack.
const MAX_HEADER_BITS: { [Kind]: number } = {
	reliable = 18,
	event = 9,
	state = 21,
	upReliable = 29,
	upUnreliable = 41,
}

-- Private -----------------------------------------------------------------------------------------

local function listCountOf(kind: Kind): number
	return if kind == "reliable" then RELIABLE_LIST_COUNT else 1
end

local function listOf(kind: Kind, chunk: Chunk): number
	return if kind == "reliable" then chunk.list else 1
end

local function isContinued(chunks: { Chunk }, i: number, first: number): boolean
	if i == first then
		return false
	end

	local previous = chunks[i - 1]
	local chunk = chunks[i]

	return previous.list == chunk.list and previous.ns == chunk.ns
end

-- The toc of chunks `first` to `last`: consecutive chunks of one list and namespace share a
-- segment.
local function segmentsOf(
	kind: Kind,
	chunks: { Chunk },
	first: number,
	last: number
): { { Toc.Segment } }
	local lists = {}
	for list = 1, listCountOf(kind) do
		lists[list] = {}
	end

	for i = first, last do
		local segments = lists[listOf(kind, chunks[i])]
		if isContinued(chunks, i, first) then
			segments[#segments].count += 1
		else
			table.insert(segments, { ns = chunks[i].ns, count = 1 })
		end
	end

	return lists
end

local function appendInstances(instances: { Instance }, chunk: Chunk)
	table.move(chunk.instances, 1, #chunk.instances, #instances + 1, instances)
end

-- Public ------------------------------------------------------------------------------------------

--[=[
	Creates a chunk from a writer that holds exactly one chunk.

	@param  ns        the namespace index; 0 for a control chunk
	@param  list      the toc list: 1 state, 2 run (runs and control chunks), 3 remove, 4 rows
	@param  w         the writer, written from bit 0; unchanged
	@param  instances the chunk's instance list
	@return the chunk
]=]
function Frame.chunk(ns: number, list: number, w: Bits.Writer, instances: { Instance }): Chunk
	local bits, tail = Bits.parts(w)

	return {
		ns = ns,
		list = list,
		bits = bits,
		bitLength = w.bit,
		tail = tail,
		instances = instances,
	}
end

--[=[
	Builds a downstream frame.

	@param  kind   "reliable", "event" or "state"
	@param  mode   a reliable frame's tick mode: 0 unchanged, 1 plus one, 2 full
	@param  tick   the state tick T
	@param  seq    a state frame's seq, the player's state-frame counter; nil otherwise
	@param  chunks the chunks, in toc order: for a reliable frame, state chunks, then runs, then
	               removes
	@param  first  the first chunk the frame holds
	@param  last   the last chunk the frame holds, from `Frame.fits`
	@return the frame
	@return its instance array
]=]
function Frame.down(
	kind: Kind,
	mode: number,
	tick: number,
	seq: number?,
	chunks: { Chunk },
	first: number,
	last: number
): (buffer, { Instance })
	local w = Bits.writer()
	if kind == "reliable" then
		Header.writeDownReliable(w, mode, tick)
	else
		Header.writeDownUnreliable(w, if kind == "state" then seq else nil, tick % TICK8_RANGE)
	end
	Toc.write(w, segmentsOf(kind, chunks, first, last))
	Bits.align(w)

	local headBytes = w.bit // 8
	local length = headBytes
	for i = first, last do
		length += buffer.len(chunks[i].bits) + buffer.len(chunks[i].tail)
	end

	local frame = buffer.create(length)
	buffer.copy(frame, 0, w.buf, 0, headBytes)
	local at = headBytes
	local instances = {}
	for i = first, last do
		local chunk = chunks[i]
		buffer.copy(frame, at, chunk.bits)
		at += buffer.len(chunk.bits)
		appendInstances(instances, chunk)
	end
	for i = last, first, -1 do
		local tail = chunks[i].tail
		buffer.copy(frame, at, tail)
		at += buffer.len(tail)
	end

	return frame, instances
end

--[=[
	Returns how many chunks, from `first`, fit one frame of a kind (v5.md §4.9): 16,384 B for a
	reliable frame and 1000 B for an unreliable one, header, toc and tag included.

	The size counts the kind's longest header, so a frame built from the result fits whatever
	its tick mode, seq or ack.

	@param  kind   the frame's kind
	@param  chunks the chunks, in toc order
	@param  first  the first chunk of the frame
	@return the last chunk that fits; `first - 1` when none is left
]=]
function Frame.fits(kind: Kind, chunks: { Chunk }, first: number): number
	local isUp = kind == "upReliable" or kind == "upUnreliable"
	local maxBytes = if kind == "reliable" or kind == "upReliable"
		then MAX_RELIABLE_BYTES
		else MAX_UNRELIABLE_BYTES
	local listCount = listCountOf(kind)
	local segmentCounts = table.create(listCount, 0)
	local headBits = MAX_HEADER_BITS[kind] + listCount
	local chunkBits = 0
	local byteCount = if isUp then TAG_BYTES else 0
	local segmentChunkCount = 0

	for i = first, #chunks do
		local chunk = chunks[i]
		if isContinued(chunks, i, first) then
			headBits += Ints.egBits(segmentChunkCount, 0) - Ints.egBits(segmentChunkCount - 1, 0)
			segmentChunkCount += 1
		else
			local list = listOf(kind, chunk)
			local segmentCount = segmentCounts[list]
			headBits += Ints.egBits(segmentCount + 1, 0) - Ints.egBits(segmentCount, 0)
			headBits += Ints.egBits(chunk.ns, 0) + Ints.egBits(0, 0)
			segmentCounts[list] = segmentCount + 1
			segmentChunkCount = 1
		end

		byteCount += buffer.len(chunk.tail)
		if isUp then
			chunkBits += chunk.bitLength
		else
			byteCount += buffer.len(chunk.bits)
		end

		if (headBits + chunkBits + 7) // 8 + byteCount > maxBytes then
			return i - 1
		end
	end

	return #chunks
end

--[=[
	Opens a received frame for decoding, checking its size (rule 8).

	@param  buf  the frame
	@param  down whether it came from the server
	@param  lane the remote it came on
	@return a reader over its bits and tail, with its tail cursor before an upstream frame's tag;
	        nil on refusal
	@return 0, or the v5.md §4.8 rule that refuses it: 8 over its size, 4 when an upstream frame
	        is too short to hold a tag
]=]
function Frame.open(buf: buffer, down: boolean, lane: Host.Lane): (Bits.Reader?, number)
	local length = buffer.len(buf)
	if lane == LANE_UNRELIABLE and length > MAX_UNRELIABLE_BYTES then
		return nil, 8
	end

	if down then
		return Bits.reader(buf), 0
	end

	if lane == LANE_RELIABLE and length > MAX_RELIABLE_BYTES then
		return nil, 8
	end

	if length < TAG_BYTES then
		return nil, 4
	end

	return Bits.reader(buf, 0, length - TAG_BYTES), 0
end

--[=[
	Builds an upstream frame, untagged.

	@param  lane   the remote it goes on
	@param  seq    the client's unreliable-frame counter on the unreliable lane; nil on the
	               reliable lane
	@param  ack    the newest state frame received, nil for `'0'`
	@param  chunks every chunk of the frame, all run chunks, in call order
	@return the frame before its tag
	@return its instance array
]=]
function Frame.up(
	lane: Host.Lane,
	seq: number?,
	ack: Header.Ack?,
	chunks: { Chunk }
): (buffer, { Instance })
	local w = Bits.writer()
	Header.writeUp(w, lane, seq, ack)
	local kind: Kind = if lane == LANE_RELIABLE then "upReliable" else "upUnreliable"
	Toc.write(w, segmentsOf(kind, chunks, 1, #chunks))

	local instances = {}
	for _, chunk in chunks do
		Bits.copy(w, chunk.bits, chunk.bitLength)
		Bits.writeTail(w, chunk.tail)
		appendInstances(instances, chunk)
	end

	return Bits.finish(w), instances
end

return table.freeze(Frame)
