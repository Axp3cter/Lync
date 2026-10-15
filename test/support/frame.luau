--!strict

--[=[
	Frame

	Test-only pieces the transport doesn't provide: the `arena` schema of v5.md §3.4, run chunk
	headers, answer-row prefixes, and a run's payloads encoded or decoded alone. Headers, the toc,
	control chunks, frames and the tag are `src/transport`'s.
]=]

-- Imports -----------------------------------------------------------------------------------------

local Bits = require("../../src/wire/bits")
local Ints = require("../../src/wire/ints")
local Ir = require("../../src/plan/ir")
local Lync = require("../../src")
local Rows = require("../../src/codec/rows")
local Run = require("../../src/codec/run")

-- Module ------------------------------------------------------------------------------------------

local Frame = {}

-- Types -------------------------------------------------------------------------------------------

--[=[
	A run's payloads decoded as a frame's last chunk.

	@field rule   0, or the v5.md §4.8 rule that refuses them; 4 when the bits and the tail don't
	              meet
	@field values the decoded values
	@field misses the values the receiver can't resolve
]=]
export type Decoded = { rule: number, values: { any }, misses: { Rows.Miss } }

-- Constants ---------------------------------------------------------------------------------------

const SLOT_BITS = 4
const EPOCH_BITS = 1
const OUTCOME_BITS = 2

local t = Lync.types

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

return table.freeze(Frame)
