--!strict

--[=[
	Outbox

	What a side sends, from the call that sends it to the frames that leave at a flush (v5.md
	§4.1–§4.2, §5.3, §5.4).

	**At the call.** A message's payload is encoded at once, so a refused value raises at the
	caller's line (§7.1), and the encoding keeps the value as it was. A client then throttles it
	to its definition's `limit` (an over-limit reliable send waits in a FIFO of at most `burst`
	messages, checked every flush; others are dropped, `sendDropped`), and holds what goes to a
	namespace before its `WELCOME`, up to 32,768 B per connection.

	**At the flush.** Consecutive messages of one definition to one target are a run, encoded
	once into chunks that every recipient's frame copies. Fewer than `columnMinRows` messages
	copy their payloads; more, or any that list instances, are re-encoded as a run from the
	values their payloads decode to, each run as one unit (m2-plan.md §9). A server resolves
	each target once per flush; for a player whose namespace has no `WELCOME` sent yet, it holds
	the chunks, up to 32,768 B, and sends them after the `WELCOME`'s control chunk. A frame goes
	through `FireAllClients` when every player's frame would hold the same chunks, none of them
	listing instances (m2-plan.md §7), decided from the routing, never by comparing bytes.
]=]

-- Imports -----------------------------------------------------------------------------------------

local Bits = require("../wire/bits")
local Buckets = require("../session/buckets")
local Column = require("../wire/column")
local Control = require("../transport/control")
local Counters = require("../diag/counters")
local Fail = require("../diag/fail")
local Frame = require("../transport/frame")
local Ints = require("../wire/ints")
local Ir = require("../plan/ir")
local Rows = require("../codec/rows")
local Run = require("../codec/run")
local State = require("../session/state")
local Tag = require("../transport/tag")
local Ticks = require("./ticks")

-- Module ------------------------------------------------------------------------------------------

local Outbox = {}

-- Types -------------------------------------------------------------------------------------------

--[=[
	Consecutive messages sent together.

	@field role       what they are
	@field definition their definition; nil for control
	@field target     their target, or their player
	@field control    a control run's type
	@field messages   the messages, in call order
]=]
type Batch = {
	role: "event" | "ask" | "answer" | "control",
	definition: State.Definition?,
	target: any,
	control: number,
	messages: { State.Message },
}

--[=[
	What one player gets in a flush.

	@field reliable   chunks for its reliable frames, in order
	@field unreliable chunks for its unreliable frames, in order
]=]
type Plan = { reliable: { Frame.Chunk }, unreliable: { Frame.Chunk } }

-- Constants ---------------------------------------------------------------------------------------

const RELIABLE = 0
const UNRELIABLE = 1
const CONTROL = 0
const RUN_LIST = 2

const SLOT_BITS = 4
const EPOCH_BITS = 1
const OUTCOME_BITS = 2

const MODE_UNCHANGED = 0
const MODE_FULL = 2

const HOLD_QUEUE = 1
const LIMIT_QUEUE = 2

const TARGET_REQUIREMENT = "be a Player, an array of players, a group, Lync.all or Lync.except(target)"

-- Private -----------------------------------------------------------------------------------------

local function laneOf(definition: State.Definition): number
	return if definition.isUnreliable then UNRELIABLE else RELIABLE
end

local function isPlayer(rt: State.Runtime, value: any): boolean
	if rt.knownPlayers[value] ~= nil then
		return true
	end

	return typeof(value) == "Instance" and value:IsA("Player")
end

local function isArrayOfPlayers(rt: State.Runtime, value: { [any]: any }): boolean
	for key, player in value do
		if typeof(key) ~= "number" or not isPlayer(rt, player) then
			return false
		end
	end

	return true
end

local function checkTarget(rt: State.Runtime, definition: State.Definition, target: any)
	if isPlayer(rt, target) then
		return
	end

	if typeof(target) == "table" then
		local kind = rawget(target, "kind")
		if kind == "all" or kind == "except" or kind == "group" then
			return
		end

		if kind == nil and isArrayOfPlayers(rt, target) then
			return
		end
	end

	Fail.caller("unknownTarget", `{definition.subject}:fire target`, TARGET_REQUIREMENT, target)
end

local function payloadOf(codec: Ir.Codec?, value: any, subject: string, root: Rows.Root): State.Payload
	if codec == nil then
		return State.EMPTY_PAYLOAD
	end

	local instances: Rows.Instances = { list = {}, index = {}, count = 0 }
	Rows.collect(codec, value, instances)
	local w = Bits.writer()
	Rows.encodeValue(w, codec, value, instances, subject, root)

	local bits, tail = Bits.parts(w)
	return {
		bits = bits,
		bitLength = w.bit,
		tail = tail,
		instances = instances.list,
		bytes = buffer.len(bits) + buffer.len(tail),
	}
end

local function messageOf(
	role: "event" | "ask" | "answer" | "control",
	definition: State.Definition?,
	target: any,
	payload: State.Payload
): State.Message
	return {
		role = role,
		definition = definition,
		target = target,
		payload = payload,
		request = nil,
		slot = 0,
		epoch = 0,
		outcome = 0,
		control = 0,
		row = nil,
		isHeld = false,
	}
end

local function isSettled(message: State.Message): boolean
	local request = message.request
	return request ~= nil and request.result ~= nil
end

-- A client's join hold (v5.md §5.3): sends to a namespace before its `WELCOME` wait, reliable
-- ones up to the hold; a refused namespace's sends are dropped.
local function enqueue(rt: State.Runtime, message: State.Message)
	local definition = message.definition :: State.Definition
	local status = definition.namespace.status
	if status == "refused" or isSettled(message) then
		return
	end

	if status ~= "welcomed" then
		local conn = rt.connection
		local bytes = message.payload.bytes
		if definition.isUnreliable or conn.holdBytes + bytes > State.MAX_HOLD_BYTES then
			State.fact(rt, "sendDropped", nil, definition, HOLD_QUEUE, laneOf(definition), bytes)
			return
		end

		message.isHeld = true
		conn.holdBytes += bytes
		State.count(rt, "heldBytes", nil, bytes)
	end

	table.insert(rt.pending, message)
end

-- A client's `limit` (v5.md §5.4): a send leaves while tokens remain and nothing older waits.
local function admit(rt: State.Runtime, message: State.Message)
	local definition = message.definition :: State.Definition
	local bucket = definition.bucket
	local fifo = definition.fifo
	if bucket == nil or (#fifo == 0 and Buckets.take(bucket, 1, rt.host.clock())) then
		enqueue(rt, message)
		return
	end

	local limit = definition.ir.limit :: State.Limit
	if definition.isUnreliable or #fifo >= limit.burst then
		local bytes = message.payload.bytes
		State.fact(rt, "sendDropped", nil, definition, LIMIT_QUEUE, laneOf(definition), bytes)
		return
	end

	table.insert(fifo, message)
end

local function releaseFifos(rt: State.Runtime)
	local now = rt.host.clock()
	for _, namespace in rt.namespaces do
		for _, definition in namespace.definitions do
			local fifo = definition.fifo
			while #fifo > 0 and Buckets.take(definition.bucket :: Buckets.Bucket, 1, now) do
				enqueue(rt, table.remove(fifo, 1) :: State.Message)
			end
		end
	end
end

local function batchesOf(messages: { State.Message }): { Batch }
	local batches: { Batch } = {}
	local current: Batch? = nil
	for _, message in messages do
		if isSettled(message) then
			continue
		end

		if
			current ~= nil
			and current.role == message.role
			and current.definition == message.definition
			and current.target == message.target
			and current.control == message.control
		then
			table.insert(current.messages, message)
			continue
		end

		local batch: Batch = {
			role = message.role,
			definition = message.definition,
			target = message.target,
			control = message.control,
			messages = { message },
		}
		table.insert(batches, batch)
		current = batch
	end

	return batches
end

local function codecOf(definition: State.Definition, message: State.Message): Ir.Codec?
	if message.role ~= "answer" then
		return definition.ir.data
	end

	return if message.outcome == State.OUTCOME_VALUE then definition.ir.reply else nil
end

-- The value a payload decodes to: the value as it was when it was sent.
local function valueOf(codec: Ir.Codec, payload: State.Payload): any
	local bitBytes = buffer.len(payload.bits)
	local buf = buffer.create(bitBytes + buffer.len(payload.tail))
	buffer.copy(buf, 0, payload.bits)
	buffer.copy(buf, bitBytes, payload.tail)

	local instances = payload.instances
	local chunk = Rows.beginChunk(instances, 0, #instances)
	local value = Rows.read(Bits.reader(buf), codec, chunk, 1, {})
	return value
end

local function writePrefix(w: Bits.Writer, message: State.Message)
	if message.role == "event" then
		return
	end

	Bits.write(w, SLOT_BITS, message.slot)
	Bits.write(w, EPOCH_BITS, message.epoch)
	if message.role == "answer" then
		Bits.write(w, OUTCOME_BITS, message.outcome)
	end
end

local function copyPayload(w: Bits.Writer, payload: State.Payload)
	if payload.bitLength > 0 then
		Bits.copy(w, payload.bits, payload.bitLength)
	end
	if buffer.len(payload.tail) > 0 then
		Bits.writeTail(w, payload.tail)
	end
end

local function encodeRequests(
	w: Bits.Writer,
	batch: Batch,
	first: number,
	last: number,
	instances: Rows.Instances
)
	local definition = batch.definition :: State.Definition
	local values = {}
	for i = first, last do
		local message = batch.messages[i]
		local codec = codecOf(definition, message)
		if codec ~= nil then
			values[i] = valueOf(codec, message.payload)
			Rows.collect(codec, values[i], instances)
		end
	end

	Ints.writeEg(w, #instances.list, 0)
	local root: Rows.Root = if batch.role == "answer" then "reply" else "data"
	for i = first, last do
		local message = batch.messages[i]
		local codec = codecOf(definition, message)
		writePrefix(w, message)
		if codec ~= nil then
			Rows.encodeValue(w, codec, values[i], instances, definition.subject, root)
		end
	end
end

-- One run chunk of messages `first` to `last` of a batch (v5.md §4.1).
local function runChunkOf(rt: State.Runtime, batch: Batch, first: number, last: number): Frame.Chunk
	local definition = batch.definition :: State.Definition
	local namespace = definition.namespace
	local ir = definition.ir
	local canonical = if batch.role == "event"
		then definition.eventId
		elseif batch.role == "ask" then definition.askId
		else definition.answerId
	local idWidth = if rt.side == "server" then namespace.ir.downWidth else namespace.ir.upWidth
	local count = last - first + 1
	local codec = codecOf(definition, batch.messages[first])

	local w = Bits.writer()
	Bits.write(w, idWidth, namespace.sendIds[canonical + 1])
	Ints.writeEg(w, count - 1, 0)

	local instances: Rows.Instances = { list = {}, index = {}, count = 0 }
	if batch.role ~= "event" and ir.hasInstances then
		encodeRequests(w, batch, first, last, instances)
	elseif codec ~= nil and (ir.hasInstances or count >= Column.MIN_ROWS) then
		local values = {}
		for i = first, last do
			values[i - first + 1] = valueOf(codec, batch.messages[i].payload)
		end
		Run.collect(codec, values, count, instances)
		if ir.hasInstances then
			Ints.writeEg(w, #instances.list, 0)
		end
		Run.encode(w, codec, values, count, instances, definition.subject, "data")
	else
		if ir.hasInstances then
			Ints.writeEg(w, 0, 0)
		end
		for i = first, last do
			local message = batch.messages[i]
			writePrefix(w, message)
			copyPayload(w, message.payload)
		end
	end

	return Frame.chunk(namespace.index, RUN_LIST, w, instances.list)
end

local function bytesOf(chunk: Frame.Chunk): number
	return buffer.len(chunk.bits) + buffer.len(chunk.tail)
end

-- Splits a run until each chunk fits an empty frame (v5.md §4.1, §4.9); one message always does.
local function splitInto(
	rt: State.Runtime,
	batch: Batch,
	first: number,
	last: number,
	chunks: { Frame.Chunk },
	counts: { number }
)
	local definition = batch.definition :: State.Definition
	local maxBytes = if definition.isUnreliable
		then State.MAX_UNRELIABLE_CHUNK
		else State.MAX_RELIABLE_CHUNK
	local chunk = runChunkOf(rt, batch, first, last)
	if first == last or bytesOf(chunk) <= maxBytes then
		table.insert(chunks, chunk)
		table.insert(counts, last - first + 1)
		return
	end

	local middle = (first + last) // 2
	splitInto(rt, batch, first, middle, chunks, counts)
	splitInto(rt, batch, middle + 1, last, chunks, counts)
end

local function chunksOf(rt: State.Runtime, batch: Batch): ({ Frame.Chunk }, { number })
	if batch.role ~= "control" then
		local chunks = {}
		local counts = {}
		splitInto(rt, batch, 1, #batch.messages, chunks, counts)
		return chunks, counts
	end

	local rows = {}
	for i, message in batch.messages do
		rows[i] = message.row
	end

	local w = Bits.writer()
	Control.write(w, batch.control, rows)
	return { Frame.chunk(CONTROL, RUN_LIST, w, {}) }, { #rows }
end

local function resolveInto(rt: State.Runtime, target: any, into: { [State.Connection]: true })
	local conn = rt.connections[target]
	if conn ~= nil then
		into[conn] = true
		return
	end

	if typeof(target) ~= "table" then
		return
	end

	local kind = rawget(target, "kind")
	if kind == "all" then
		for _, each in rt.connections do
			into[each] = true
		end
	elseif kind == "except" then
		local excluded = {}
		resolveInto(rt, target.target, excluded)
		for _, each in rt.connections do
			if excluded[each] == nil then
				into[each] = true
			end
		end
	elseif kind == "group" then
		for player in (target :: State.Group).members do
			resolveInto(rt, player, into)
		end
	elseif kind == nil then
		for _, player in target do
			resolveInto(rt, player, into)
		end
	end
end

local function recipientsOf(
	rt: State.Runtime,
	batch: Batch,
	resolved: { [any]: { [State.Connection]: true } }
): { [State.Connection]: true }
	local target = batch.target
	local recipients = resolved[target]
	if recipients ~= nil then
		return recipients
	end

	recipients = {}
	resolveInto(rt, target, recipients)
	resolved[target] = recipients
	return recipients
end

local function planOf(plans: { [State.Connection]: Plan }, conn: State.Connection): Plan
	local plan = plans[conn]
	if plan == nil then
		plan = { reliable = {}, unreliable = {} }
		plans[conn] = plan
	end

	return plan
end

local function place(
	rt: State.Runtime,
	plan: Plan,
	player: Player?,
	lane: number,
	chunk: Frame.Chunk,
	definition: State.Definition,
	count: number
)
	table.insert(if lane == RELIABLE then plan.reliable else plan.unreliable, chunk)
	Counters.add(rt.counters, definition.sentSlot, player, count)
	Counters.add(rt.counters, definition.bytesSentSlot, player, bytesOf(chunk))
end

local function hold(
	rt: State.Runtime,
	conn: State.Connection,
	chunk: Frame.Chunk,
	lane: number,
	definition: State.Definition,
	count: number
)
	local bytes = bytesOf(chunk)
	if conn.holdBytes + bytes > State.MAX_HOLD_BYTES then
		State.fact(rt, "sendDropped", conn.player, definition, HOLD_QUEUE, lane, bytes)
		return
	end

	conn.holdBytes += bytes
	State.count(rt, "heldBytes", conn.player, bytes)
	table.insert(conn.holds, {
		chunk = chunk,
		lane = lane,
		index = definition.namespace.index,
		definition = definition,
		count = count,
	})
end

-- Releases the chunks held for a namespace into a plan, or drops them when it was refused.
local function releaseHolds(rt: State.Runtime, conn: State.Connection, plan: Plan, index: number?)
	local kept = {}
	for _, held in conn.holds do
		local isReleased = held.index == index
		if not isReleased and conn.refused[held.index] == nil then
			table.insert(kept, held)
			continue
		end

		local bytes = bytesOf(held.chunk)
		conn.holdBytes -= bytes
		State.count(rt, "heldBytes", conn.player, -bytes)
		if isReleased then
			place(rt, plan, conn.player, held.lane, held.chunk, held.definition, held.count)
		end
	end
	conn.holds = kept
end

local function routeControl(rt: State.Runtime, conn: State.Connection, plan: Plan, batch: Batch, chunk: Frame.Chunk)
	table.insert(plan.reliable, chunk)
	if batch.control == Control.MISMATCH then
		releaseHolds(rt, conn, plan, nil)
		return
	end

	if batch.control ~= Control.WELCOME then
		return
	end

	for _, message in batch.messages do
		local index = message.row.index
		conn.sending[index] = true
		releaseHolds(rt, conn, plan, index)
	end
end

local function route(
	rt: State.Runtime,
	conn: State.Connection,
	plan: Plan,
	batch: Batch,
	chunks: { Frame.Chunk },
	counts: { number }
)
	if batch.role == "control" then
		routeControl(rt, conn, plan, batch, chunks[1])
		return
	end

	local definition = batch.definition :: State.Definition
	local index = definition.namespace.index
	if conn.refused[index] ~= nil then
		return
	end

	local lane = laneOf(definition)
	for i, chunk in chunks do
		if conn.sending[index] == nil then
			hold(rt, conn, chunk, lane, definition, counts[i])
		else
			place(rt, plan, conn.player, lane, chunk, definition, counts[i])
		end
	end
end

-- Whether every player gets the same chunks on a lane, none listing instances, so one
-- `FireAllClients` serves them all.
local function isShared(rt: State.Runtime, plans: { [State.Connection]: Plan }, lane: number): boolean
	local shared: { Frame.Chunk }? = nil
	for _, conn in rt.connections do
		local plan = plans[conn]
		if plan == nil then
			return false
		end

		local chunks = if lane == RELIABLE then plan.reliable else plan.unreliable
		if shared == nil then
			for _, chunk in chunks do
				if #chunk.instances > 0 then
					return false
				end
			end
			shared = chunks
		elseif #chunks ~= #shared then
			return false
		else
			for i, chunk in chunks do
				if chunk ~= shared[i] then
					return false
				end
			end
		end
	end

	return shared ~= nil and #shared > 0
end

local function sendDown(
	rt: State.Runtime,
	player: Player?,
	lane: number,
	chunks: { Frame.Chunk },
	tick: number,
	mode: number
)
	local transport = rt.host.transport
	local kind: Frame.Kind = if lane == RELIABLE then "reliable" else "event"
	local frameMode = mode
	local first = 1
	while first <= #chunks do
		local last = Frame.fits(kind, chunks, first)
		local frame, instances = Frame.down(kind, frameMode, tick, nil, chunks, first, last)
		local list = if #instances > 0 then instances else nil
		if player == nil then
			transport.broadcast(lane, frame, list)
		else
			transport.send(player, lane, frame, list)
		end

		frameMode = MODE_UNCHANGED
		first = last + 1
	end
end

local function sendShared(rt: State.Runtime, plans: { [State.Connection]: Plan }, lane: number, tick: number)
	local chunks: { Frame.Chunk } = {}
	local lastTick: number? = nil
	for conn, plan in plans do
		if lane == RELIABLE then
			chunks = plan.reliable
			plan.reliable = {}
			lastTick = if lastTick == nil or lastTick == conn.lastTick then conn.lastTick else -1
			conn.lastTick = tick
		else
			chunks = plan.unreliable
			plan.unreliable = {}
		end
	end

	sendDown(rt, nil, lane, chunks, tick, Ticks.mode(lastTick or -1, tick))
end

local function flushServer(rt: State.Runtime, messages: { State.Message })
	local tick = rt.lastTick
	local plans: { [State.Connection]: Plan } = {}
	local resolved = {}
	for _, batch in batchesOf(messages) do
		local ok, chunks, counts = pcall(chunksOf, rt, batch)
		if not ok then
			rt.host.report(tostring(chunks))
			continue
		end

		if batch.role == "event" then
			for conn in recipientsOf(rt, batch, resolved) do
				route(rt, conn, planOf(plans, conn), batch, chunks, counts)
			end
			continue
		end

		local conn = rt.connections[batch.target]
		if conn ~= nil then
			route(rt, conn, planOf(plans, conn), batch, chunks, counts)
		end
	end

	if isShared(rt, plans, RELIABLE) then
		sendShared(rt, plans, RELIABLE, tick)
	end
	if isShared(rt, plans, UNRELIABLE) then
		sendShared(rt, plans, UNRELIABLE, tick)
	end

	for conn, plan in plans do
		local player = conn.player :: Player
		if #plan.reliable > 0 then
			sendDown(rt, player, RELIABLE, plan.reliable, tick, Ticks.mode(conn.lastTick, tick))
			conn.lastTick = tick
		end
		if #plan.unreliable > 0 then
			sendDown(rt, player, UNRELIABLE, plan.unreliable, tick, MODE_FULL)
		end
	end
end

local function sendUp(rt: State.Runtime, lane: number, chunks: { Frame.Chunk })
	local conn = rt.connection
	local kind: Frame.Kind = if lane == RELIABLE then "upReliable" else "upUnreliable"
	local first = 1
	while first <= #chunks do
		local last = Frame.fits(kind, chunks, first)
		local part = table.move(chunks, first, last, 1, {})
		local count = if lane == RELIABLE then conn.count else conn.seq
		local body, instances = Frame.up(lane, if lane == RELIABLE then nil else count, nil, part)
		local tag = Tag.compute(conn.key :: buffer, count, lane, body, buffer.len(body), #instances, conn.cover)
		if lane == RELIABLE then
			conn.count += 1
		else
			conn.seq += 1
		end

		local list = if #instances > 0 then instances else nil
		rt.host.transport.send(nil, lane, Tag.append(body, tag), list)
		first = last + 1
	end
end

-- Before its first `WELCOME` a client sends only untagged frames of `HELLO`s (v5.md §4.5).
local function sendHellos(rt: State.Runtime, messages: { State.Message }): { State.Message }
	local rows = {}
	local kept = {}
	for _, message in messages do
		if message.role == "control" and message.control == Control.HELLO then
			table.insert(rows, message.row)
		else
			table.insert(kept, message)
		end
	end

	if #rows > 0 then
		local w = Bits.writer()
		Control.write(w, Control.HELLO, rows)
		local frame = Frame.up(RELIABLE, nil, nil, { Frame.chunk(CONTROL, RUN_LIST, w, {}) })
		rt.host.transport.send(nil, RELIABLE, frame, nil)
	end

	return kept
end

local function flushClient(rt: State.Runtime, messages: { State.Message }): { State.Message }
	if not rt.connection.isWelcomed then
		return sendHellos(rt, messages)
	end

	local kept = {}
	local controls = {}
	local sendable = {}
	for _, message in messages do
		local definition = message.definition
		if definition == nil then
			table.insert(controls, message)
		elseif definition.namespace.status ~= "welcomed" then
			table.insert(kept, message)
		else
			table.insert(sendable, message)
		end
	end

	local reliable = {}
	local unreliable = {}
	for _, batch in batchesOf(controls) do
		local chunks = chunksOf(rt, batch)
		table.insert(reliable, chunks[1])
	end
	for _, batch in batchesOf(sendable) do
		local ok, chunks, counts = pcall(chunksOf, rt, batch)
		if not ok then
			rt.host.report(tostring(chunks))
			continue
		end

		local definition = batch.definition :: State.Definition
		local plan = { reliable = reliable, unreliable = unreliable }
		for i, chunk in chunks do
			place(rt, plan, nil, laneOf(definition), chunk, definition, counts[i])
		end
	end

	sendUp(rt, RELIABLE, reliable)
	sendUp(rt, UNRELIABLE, unreliable)
	return kept
end

-- Public ------------------------------------------------------------------------------------------

--[=[
	Queues an answer to an ask this side read.

	@param  rt         the runtime
	@param  definition the request
	@param  player     the asking player, on a server
	@param  slot       the ask's slot
	@param  epoch      the ask's epoch
	@param  outcome    0 value, 1 rejected, 2 unanswered
	@param  value      the reply, for outcome 0
	@error  valueRefused, when the reply doesn't fit the request's `reply`, from `reply`
]=]
function Outbox.answer(
	rt: State.Runtime,
	definition: State.Definition,
	player: Player?,
	slot: number,
	epoch: number,
	outcome: number,
	value: any
)
	local codec = if outcome == State.OUTCOME_VALUE then definition.ir.reply else nil
	local payload = payloadOf(codec, value, `{definition.subject}:handle`, "reply")
	local message = messageOf("answer", definition, player, payload)
	message.slot = slot
	message.epoch = epoch
	message.outcome = outcome
	table.insert(rt.pending, message)
end

--[=[
	Encodes an ask and queues it, on a slot the caller took.

	@param rt         the runtime
	@param definition the request
	@param player     the player asked, on a server
	@param value      the ask's payload
	@param slot       the request's slot
	@param epoch      the slot's epoch
	@error valueRefused, when the value doesn't fit the request's `data`
]=]
function Outbox.ask(
	rt: State.Runtime,
	definition: State.Definition,
	player: Player?,
	value: any,
	slot: number,
	epoch: number
)
	local payload = payloadOf(definition.ir.data, value, `{definition.subject}:invoke`, "data")
	local conn = if player == nil then rt.connection else rt.connections[player]
	local message = messageOf("ask", definition, player, payload)
	message.request = conn.asking[slot]
	message.slot = slot
	message.epoch = epoch
	if rt.side == "server" then
		table.insert(rt.pending, message)
	else
		admit(rt, message)
	end
end

--[=[
	Queues a control message (v5.md §4.6).

	@param rt     the runtime
	@param player the player it goes to, on a server
	@param kind   the control type
	@param row    its fields, as `Control.write` takes them
]=]
function Outbox.control(rt: State.Runtime, player: Player?, kind: number, row: any)
	local message = messageOf("control", nil, player, State.EMPTY_PAYLOAD)
	message.control = kind
	message.row = row
	table.insert(rt.pending, message)
end

--[=[
	Encodes an event and queues it.

	@param rt         the runtime
	@param definition the event
	@param target     who it goes to, on a server; nil on a client
	@param value      its payload
	@error unknownTarget, when a server's target is none of the target forms
	@error valueRefused, when the value doesn't fit the event's `data`
]=]
function Outbox.fire(rt: State.Runtime, definition: State.Definition, target: State.Target?, value: any)
	if rt.side == "server" then
		checkTarget(rt, definition, target)
	end

	local payload = payloadOf(definition.ir.data, value, `{definition.subject}:fire`, "data")
	local message = messageOf("event", definition, target, payload)
	if rt.side == "server" then
		table.insert(rt.pending, message)
	else
		admit(rt, message)
	end
end

--[=[
	Sends everything pending, as frames: per player on a server, or to the server. Nothing is
	done when nothing is pending, and a flush already running makes this one a no-op.

	@param rt the runtime
]=]
function Outbox.flush(rt: State.Runtime)
	if rt.isFlushing then
		return
	end

	local isServer = rt.side == "server"
	if not isServer then
		if not rt.host.transport.ready() then
			return
		end
		releaseFifos(rt)
	else
		Ticks.advance(rt)
	end

	if #rt.pending == 0 then
		return
	end

	rt.isFlushing = true
	local messages = rt.pending
	rt.pending = {}
	if isServer then
		flushServer(rt, messages)
	else
		local kept = flushClient(rt, messages)
		table.move(rt.pending, 1, #rt.pending, #kept + 1, kept)
		rt.pending = kept
	end
	rt.isFlushing = false
end

return table.freeze(Outbox)
