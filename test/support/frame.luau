--!strict

--[=[
	Frame

	Test-only frame pieces for the golden frames (v5.md §4.10): headers, the segment toc, run chunk
	headers, answer-row prefixes and the upstream tag, written and read under the golden
	conditions (seed 0, identity permutation, `arena` as namespace 1, tag key `00 01 … 07`,
	`tag.cover` 1024). Frames belong to milestone 2; this is only enough to wrap payloads.
]=]

-- Imports -----------------------------------------------------------------------------------------

local Bits = require("../../src/wire/bits")
local HalfSipHash = require("../../src/wire/halfsiphash")
local Ints = require("../../src/wire/ints")
local Ir = require("../../src/plan/ir")
local Lync = require("../../src")
local Rows = require("../../src/codec/rows")
local Run = require("../../src/codec/run")

-- Module ------------------------------------------------------------------------------------------

local Frame = {}

-- Types -------------------------------------------------------------------------------------------

--- One toc segment: a namespace index and how many chunks of the list's kind it holds.
export type Segment = { namespace: number, chunks: number }

--[=[
	A run's payloads decoded as a frame's last chunk.

	@field rule   0, or the v5.md §4.8 rule that refuses them; 4 when the bits and the tail don't
	              meet
	@field values the decoded values
	@field misses the values the receiver can't resolve
]=]
export type Decoded = { rule: number, values: { any }, misses: { Rows.Miss } }

--- A downstream reliable tick: unchanged (`'0'`), the last plus one (`'10'`), or a u16 (`'11'`).
export type Tick = "unchanged" | "next" | number

-- Constants ---------------------------------------------------------------------------------------

const TAG_KEY = buffer.fromstring("\0\1\2\3\4\5\6\7")
const TAG_COVER = 1024
const TAG_PREFIX_BYTES = 11
const SEQ_BITS = 12
const TICK_BITS = 16
const SLOT_BITS = 4
const EPOCH_BITS = 1
const OUTCOME_BITS = 2

local t = Lync.types

-- Private -----------------------------------------------------------------------------------------

local function tagOf(body: buffer, count: number, lane: number, instanceCount: number): number
	local length = buffer.len(body)
	local covered = math.min(TAG_COVER, length)
	local message = buffer.create(TAG_PREFIX_BYTES + covered)
	buffer.writeu32(message, 0, count)
	buffer.writeu8(message, 4, lane)
	buffer.writeu32(message, 5, length)
	buffer.writeu16(message, 9, instanceCount)
	buffer.copy(message, TAG_PREFIX_BYTES, body, 0, covered)

	local low = HalfSipHash.hash(TAG_KEY, message, 0, buffer.len(message), 1, 3, 4)
	return low % 0x1_0000
end

-- Public ------------------------------------------------------------------------------------------

--[=[
	Plans the `arena` schema of v5.md §3.4.

	@return its IR
]=]
function Frame.arena(): Ir.Namespace
	local schema = Lync.schema("arena", {
		chat = Lync.event({
			from = "client",
			data = t.string(200),
			limit = { perSecond = 5, burst = 5 },
		}),
		strike = Lync.event({
			from = "client",
			lane = "unreliable",
			data = { target = t.int(1, 2 ^ 40), aim = t.direction(11) },
		}),
		announce = Lync.event({
			from = "server",
			data = t.union({
				round = { number = t.int(1, 99) },
				winner = { team = t.enum({ "red", "blue" }) },
			}),
		}),
		buy = Lync.request({
			from = "client",
			data = { item = t.enum({ "sword", "shield" }) },
			reply = t.int(0, 100_000),
			timeout = 10,
		}),
		fighters = Lync.collection({
			key = t.int(1, 2 ^ 40),
			maxRecords = 64,
			data = {
				name = t.string(20),
				team = t.enum({ "red", "blue" }),
				health = t.int(0, 100),
				position = t.vector3(-2048, 2048, 1 / 32):newest(),
				look = t.rotation(9):newest(),
				title = t.optional(t.string(16)),
			},
		}),
		round = Lync.collection({
			data = { endsAt = t.int(0, 2 ^ 31), phase = t.enum({ "lobby", "play" }) },
		}),
	})

	return (schema :: any).ir
end

--[=[
	Returns whether an upstream frame ends in the tag of its body.

	@param  frame         the frame, tag included
	@param  count         the frame count (reliable) or extended seq (unreliable)
	@param  lane          0 reliable, 1 unreliable
	@param  instanceCount how many instances the call carries
	@return the body, without the tag, or nil when the tag differs
]=]
function Frame.checkTag(frame: buffer, count: number, lane: number, instanceCount: number): buffer?
	local bodyBytes = buffer.len(frame) - 2
	local body = buffer.create(bodyBytes)
	buffer.copy(body, 0, frame, 0, bodyBytes)
	if buffer.readu16(frame, bodyBytes) ~= tagOf(body, count, lane, instanceCount) then
		return nil
	end

	return body
end

--[=[
	Decodes a run's payloads that fill a buffer, as the last chunk of a frame, in one chunk.

	@param  bytes         the payloads
	@param  codec         the messages' codec
	@param  count         how many messages
	@param  list          the chunk's instances; an unreplicated one is nil
	@param  instanceCount the chunk's instance count, `#list` when nil
	@param  budget        the decode element allowance, unlimited when nil
	@return the rule, the values and the misses
]=]
function Frame.decodeRun(
	bytes: buffer,
	codec: Ir.Codec,
	count: number,
	list: { Instance? },
	instanceCount: number?,
	budget: number?
): Decoded
	local r = Bits.reader(bytes, nil, nil, budget)
	local chunk = Rows.beginChunk(list, 0, instanceCount or #list)
	local values = {}
	local misses = {}
	local rule = Run.decode(r, codec, count, chunk, misses, values)
	if rule == 0 then
		rule = Rows.endChunk(chunk)
	end
	if rule == 0 and not Bits.meets(r) then
		rule = 4
	end

	return { rule = rule, values = values, misses = misses }
end

--[=[
	Encodes a run's payloads alone, its instances collected first.

	@param  codec  the messages' codec
	@param  values the messages' values
	@param  count  how many messages
	@return the payloads, aligned, with their tail
	@return the chunk's instances
	@error  valueRefused, from `data`
]=]
function Frame.encodeRun(codec: Ir.Codec, values: { any }, count: number): (buffer, { Instance })
	local instances: Rows.Instances = { list = {}, index = {}, count = 0 }
	Run.collect(codec, values, count, instances)
	local w = Bits.writer()
	Run.encode(w, codec, values, count, instances, "test.run:fire", "data")

	return Bits.finish(w), instances.list
end

--[=[
	Reads an answer row's prefix.

	@param  r the reader
	@return the slot, or nil when bits run out
	@return the epoch
	@return the outcome
]=]
function Frame.readAnswerPrefix(r: Bits.Reader): (number?, number?, number?)
	return Bits.read(r, SLOT_BITS), Bits.read(r, EPOCH_BITS), Bits.read(r, OUTCOME_BITS)
end

--[=[
	Reads a downstream reliable frame's tick header.

	@param  r the reader
	@return the tick
]=]
function Frame.readDownReliableHeader(r: Bits.Reader): Tick?
	if Bits.read(r, 1) == 0 then
		return "unchanged"
	end

	if Bits.read(r, 1) == 0 then
		return "next"
	end

	return Bits.read(r, TICK_BITS)
end

--[=[
	Reads a run chunk's header.

	@param  r            the reader
	@param  idWidth      the bits of an id in the space
	@param  hasInstances whether the definition's payload can hold instances
	@return the id
	@return the message count
	@return the instance count, 0 without instances
]=]
function Frame.readRunHeader(
	r: Bits.Reader,
	idWidth: number,
	hasInstances: boolean
): (number?, number?, number?)
	local id = Bits.read(r, idWidth)
	local countLessOne = Ints.readEg(r, 0)
	local instanceCount = if hasInstances then Ints.readEg(r, 0) else 0
	if countLessOne == nil then
		return id, nil, instanceCount
	end

	return id, countLessOne + 1, instanceCount
end

--[=[
	Reads one list of toc segments.

	@param  r the reader
	@return the segments
]=]
function Frame.readSegments(r: Bits.Reader): { Segment }
	local segments = {}
	local segmentCount = Ints.readEg(r, 0) or 0
	for _ = 1, segmentCount do
		local namespace = Ints.readEg(r, 0) or -1
		local chunksLessOne = Ints.readEg(r, 0) or -2
		table.insert(segments, { namespace = namespace, chunks = chunksLessOne + 1 })
	end

	return segments
end

--[=[
	Reads an upstream reliable frame's header, which must be an empty ack (`'0'`).

	@param  r the reader
	@return whether the ack is `'0'`
]=]
function Frame.readUpReliableHeader(r: Bits.Reader): boolean
	return Bits.read(r, 1) == 0
end

--[=[
	Reads an upstream unreliable frame's header, whose ack must be `'0'`.

	@param  r the reader
	@return the seq, or nil when the ack is not `'0'`
]=]
function Frame.readUpUnreliableHeader(r: Bits.Reader): number?
	local seq = Bits.read(r, SEQ_BITS)
	if Bits.read(r, 1) ~= 0 then
		return nil
	end

	return seq
end

--[=[
	Appends the upstream tag to a frame body.

	@param  body          the frame before the tag
	@param  count         the frame count (reliable) or extended seq (unreliable)
	@param  lane          0 reliable, 1 unreliable
	@param  instanceCount how many instances the call carries
	@return the frame with its tag
]=]
function Frame.tagged(body: buffer, count: number, lane: number, instanceCount: number): buffer
	local bodyBytes = buffer.len(body)
	local frame = buffer.create(bodyBytes + 2)
	buffer.copy(frame, 0, body)
	buffer.writeu16(frame, bodyBytes, tagOf(body, count, lane, instanceCount))

	return frame
end

--[=[
	Writes an answer row's prefix (v5.md §5.2).

	@param w       the writer
	@param slot    the request slot, 0 to 15
	@param epoch   the slot's epoch, 0 or 1
	@param outcome 0 value, 1 rejected, 2 unanswered
]=]
function Frame.writeAnswerPrefix(w: Bits.Writer, slot: number, epoch: number, outcome: number)
	Bits.write(w, SLOT_BITS, slot)
	Bits.write(w, EPOCH_BITS, epoch)
	Bits.write(w, OUTCOME_BITS, outcome)
end

--[=[
	Writes a downstream reliable frame's tick header.

	@param w    the writer
	@param tick the tick
]=]
function Frame.writeDownReliableHeader(w: Bits.Writer, tick: Tick)
	if tick == "unchanged" then
		Bits.write(w, 1, 0)
	elseif tick == "next" then
		Bits.write(w, 2, 0b01)
	else
		Bits.write(w, 2, 0b11)
		Bits.write(w, TICK_BITS, tick)
	end
end

--[=[
	Writes a run chunk's header.

	@param w             the writer
	@param id            the definition's id in its space
	@param idWidth       the bits of an id in the space
	@param count         how many messages, at least 1
	@param instanceCount the chunk's instance count, or nil when the definition holds none
]=]
function Frame.writeRunHeader(
	w: Bits.Writer,
	id: number,
	idWidth: number,
	count: number,
	instanceCount: number?
)
	Bits.write(w, idWidth, id)
	Ints.writeEg(w, count - 1, 0)
	if instanceCount ~= nil then
		Ints.writeEg(w, instanceCount, 0)
	end
end

--[=[
	Writes one list of toc segments.

	@param w        the writer
	@param segments the segments, in order
]=]
function Frame.writeSegments(w: Bits.Writer, segments: { Segment })
	Ints.writeEg(w, #segments, 0)
	for _, segment in segments do
		Ints.writeEg(w, segment.namespace, 0)
		Ints.writeEg(w, segment.chunks - 1, 0)
	end
end

--[=[
	Writes an upstream reliable frame's header with an empty ack (`'0'`).

	@param w the writer
]=]
function Frame.writeUpReliableHeader(w: Bits.Writer)
	Bits.write(w, 1, 0)
end

--[=[
	Writes an upstream unreliable frame's header with an empty ack (`'0'`).

	@param w   the writer
	@param seq the frame's seq, 0 to 4095
]=]
function Frame.writeUpUnreliableHeader(w: Bits.Writer, seq: number)
	Bits.write(w, SEQ_BITS, seq)
	Bits.write(w, 1, 0)
end

return table.freeze(Frame)
