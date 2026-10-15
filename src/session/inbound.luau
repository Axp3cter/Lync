--!strict

--[=[
	Inbound

	What a side does with each remote call it receives.

	A server runs v5.md §6.1's pipeline, in order, and decodes nothing before it is paid for:
	1. **Shape**: one buffer, plus at most an array of `Instance` (`malformed`, rule 1).
	2. **Budgets**: the lane's frame and byte buckets, charged `buffer.len` + 8 B per instance
	   (`overBudget`); an over-budget reliable frame is still tag-checked, so the count stays in
	   step.
	3. **Integrity**: the untagged-`HELLO` rule, then the tag (`tagMismatch`, `frameGap`,
	   `desync`); on the unreliable lane, the replay window (`replayed`).
	4. **Decode** of the whole frame (v5.md §4.8), ids through the permutation, under one
	   `pcall` (`decoderRaised`), with the player's `inbound.elements` tokens as its element
	   allowance (rule 10 is `overBudget`). Control messages take effect as they are decoded.
	5. **Per message**: answers (`slotConflict`, late answers), `unresolved`, `limit`
	   (`overLimit`); a dropped ask is answered `rejected`.
	6. **Validators**, in their own thread: `false` drops the message, a raise or a yield too,
	   reported natively at most once per definition per window.
	7. **Delivery** to handlers, each in its own thread.

	A client checks the shape and decodes with a fixed allowance of 4,194,304 elements; past it a
	frame is refused and counted (`refusedFrames`), never a fact. It drops unresolved messages
	and counts them (`unresolvedMessages`).
]=]

-- Imports -----------------------------------------------------------------------------------------

local Bits = require("../wire/bits")
local Buckets = require("./buckets")
local Connection = require("./connection")
local Control = require("../transport/control")
local Counters = require("../diag/counters")
local Fail = require("../diag/fail")
local Frame = require("../transport/frame")
local Handshake = require("./handshake")
local Header = require("../transport/header")
local Ints = require("../wire/ints")
local Ir = require("../plan/ir")
local Replay = require("./replay")
local Requests = require("./requests")
local Rows = require("../codec/rows")
local Run = require("../codec/run")
local Seq = require("../transport/seq")
local State = require("./state")
local Tag = require("../transport/tag")
local Toc = require("../transport/toc")

-- Module ------------------------------------------------------------------------------------------

local Inbound = {}

-- Types -------------------------------------------------------------------------------------------

--[=[
	A message decoded from a frame, waiting for the frame to finish decoding.

	@field role       what it is
	@field definition its definition
	@field value      its payload
	@field slot       an ask's or answer's slot
	@field epoch      an ask's or answer's epoch
	@field outcome    an answer's outcome
	@field what       0, or the first unresolved value's kind: 1 enum, 2 nil instance, 3 class
	@field missValue  the unresolved value: the enum value or the instance's index in its chunk
	@field bytes      its chunk's bytes, on the chunk's first message; 0 on the others
]=]
type Received = {
	role: "event" | "ask" | "answer",
	definition: State.Definition,
	value: any,
	slot: number,
	epoch: number,
	outcome: number,
	what: number,
	missValue: number,
	bytes: number,
}

--[=[
	One frame's decoding.

	@field rt             the runtime
	@field conn           the connection it came on
	@field lane           the remote it came on
	@field list           the call's instance array
	@field instanceCount  the array's entries, up to its highest index
	@field offset         the instance entries the chunks so far have listed
	@field lists          the toc's lists
	@field rows           control rows, reused
	@field received       the decoded messages, in frame order
	@field ack            the upstream ack, if any
	@field isNewKey       whether the frame matched a server's pending new key
	@field matched        the count it matched at
	@field isAcknowledged whether it carried `REKEY-ACK`
	@field mode           a downstream reliable frame's tick mode
	@field tickBits       the tick bits the header carried
]=]
type Decoding = {
	rt: State.Runtime,
	conn: State.Connection,
	lane: number,
	list: { Instance? },
	instanceCount: number,
	offset: number,
	lists: { { Toc.Segment } },
	rows: { any },
	received: { Received },
	ack: Header.Ack?,
	isNewKey: boolean,
	matched: number,
	isAcknowledged: boolean,
	mode: number,
	tickBits: number,
}

-- Constants ---------------------------------------------------------------------------------------

const RELIABLE = 0
const UNRELIABLE = 1
const CONTROL = 0

const SLOT_BITS = 4
const EPOCH_BITS = 1
const OUTCOME_BITS = 2
const MAX_OUTCOME = 2
const SEQ_BITS = 12

const TAG_BYTES = 2
const INSTANCE_CHARGE = 8
const LOOKAHEAD = 4
const DESYNC_FAILURES = 8
const REKEY_INTERVAL = 60
const COUNT_RANGE = 2 ^ 32
const SEQ_RANGE = 4096

const MODE_UNCHANGED = 0
const MODE_NEXT = 1
const TICK_RANGE = 0x1_0000
const TICK8_RANGE = 0x100

-- Private -----------------------------------------------------------------------------------------

-- The instance array's entry count, up to its highest index, or nil when the call isn't one
-- buffer plus at most an array of `Instance` (rule 1). Unreplicated instances arrive as holes.
local function instanceCountOf(count: number, frame: unknown, list: unknown): number?
	if count < 1 or count > 2 or typeof(frame) ~= "buffer" then
		return nil
	end

	if list == nil then
		return 0
	end

	if typeof(list) ~= "table" then
		return nil
	end

	local maxIndex = 0
	for key, value in list :: { [unknown]: unknown } do
		if typeof(key) ~= "number" or typeof(value) ~= "Instance" then
			return nil
		end

		local index = key :: number
		if index < 1 or index % 1 ~= 0 then
			return nil
		end
		maxIndex = math.max(maxIndex, index)
	end

	return maxIndex
end

local function push(
	d: Decoding,
	role: "event" | "ask" | "answer",
	definition: State.Definition,
	value: any,
	slot: number,
	epoch: number,
	outcome: number
)
	table.insert(d.received, {
		role = role,
		definition = definition,
		value = value,
		slot = slot,
		epoch = epoch,
		outcome = outcome,
		what = 0,
		missValue = 0,
		bytes = 0,
	})
end

local function readEvents(
	r: Bits.Reader,
	d: Decoding,
	definition: State.Definition,
	count: number,
	chunk: Rows.Chunk,
	misses: { Rows.Miss }
): number
	local codec = definition.ir.data
	if codec == nil then
		if not Bits.charge(r, count) then
			return 10
		end

		for _ = 1, count do
			push(d, "event", definition, nil, 0, 0, 0)
		end
		return 0
	end

	local values = {}
	local rule = Run.decode(r, codec, count, chunk, misses, values)
	if rule ~= 0 then
		return rule
	end

	for i = 1, count do
		push(d, "event", definition, values[i], 0, 0, 0)
	end
	return 0
end

-- Request and answer rows: each a slot and epoch, an answer's outcome, then its payload.
local function readRequests(
	r: Bits.Reader,
	d: Decoding,
	definition: State.Definition,
	role: "ask" | "answer",
	count: number,
	chunk: Rows.Chunk,
	misses: { Rows.Miss }
): number
	if not Bits.charge(r, count) then
		return 10
	end

	for row = 1, count do
		local slot = Bits.read(r, SLOT_BITS)
		local epoch = Bits.read(r, EPOCH_BITS)
		if slot == nil or epoch == nil then
			return 4
		end

		local outcome = State.OUTCOME_VALUE
		local codec = definition.ir.data
		if role == "answer" then
			local readOutcome = Bits.read(r, OUTCOME_BITS)
			if readOutcome == nil then
				return 4
			end
			if readOutcome > MAX_OUTCOME then
				return 2
			end

			outcome = readOutcome
			codec = if outcome == State.OUTCOME_VALUE then definition.ir.reply else nil
		end

		local value = nil
		if codec ~= nil then
			local rowValue, rule = Rows.read(r, codec, chunk, row, misses)
			if rule ~= 0 then
				return rule
			end
			value = rowValue
		end
		push(d, role, definition, value, slot, epoch, outcome)
	end

	return 0
end

local function markMisses(d: Decoding, first: number, misses: { Rows.Miss })
	for _, miss in misses do
		local received = d.received[first + miss.row - 1]
		if received.what == 0 then
			received.what = miss.what
			received.missValue = miss.value
		end
	end
end

-- One run chunk, its id read in the space this side receives (rule 7 outside it, or on a lane
-- its definition doesn't use).
local function readRun(r: Bits.Reader, d: Decoding, namespace: State.Namespace): number
	local ir = namespace.ir
	local isServer = d.rt.side == "server"
	local id = Bits.read(r, if isServer then ir.upWidth else ir.downWidth)
	if id == nil then
		return 4
	end

	local canonical = namespace.readIds[id + 1]
	if canonical == nil then
		return 7
	end

	local entry: Ir.Entry = (if isServer then ir.up else ir.down)[canonical + 1]
	local definition = namespace.definitions[entry.definition.name]
	if definition.isUnreliable ~= (d.lane == UNRELIABLE) then
		return 7
	end

	local countLessOne, countRule = Ints.readEg(r, 0)
	if countLessOne == nil then
		return countRule
	end

	local instanceCount = 0
	if entry.definition.hasInstances then
		local readCount, instanceRule = Ints.readEg(r, 0)
		if readCount == nil then
			return instanceRule
		end
		instanceCount = readCount
	end

	local startBit = r.bit
	local startStop = r.stop
	local first = #d.received + 1
	local misses = {}
	local chunk = Rows.beginChunk(d.list, d.offset, instanceCount)
	local count = countLessOne + 1
	local rule = if entry.role == "event"
		then readEvents(r, d, definition, count, chunk, misses)
		else readRequests(r, d, definition, entry.role, count, chunk, misses)
	if rule == 0 then
		rule = Rows.endChunk(chunk)
	end
	if rule ~= 0 then
		return rule
	end

	d.offset += instanceCount
	d.received[first].bytes = (r.bit - startBit + 7) // 8 + startStop - r.stop
	markMisses(d, first, misses)
	return 0
end

-- A control chunk from a client: `HELLO`, `REKEY-ACK` (only in the first frame tagged with a
-- pending key) and `REPORT` (read and ignored until milestone 5); `BEACON` while beacons are off
-- and every downstream type are rule 7.
local function readUpControl(r: Bits.Reader, d: Decoding): number
	if d.lane ~= RELIABLE then
		return 7
	end

	local rows = d.rows
	local kind, rule = Control.read(r, false, rows)
	if kind == nil then
		return rule
	end

	local conn = d.conn
	if kind == Control.HELLO then
		for _, hello in rows do
			Handshake.hello(d.rt, conn, hello)
		end
		return 0
	end

	if kind == Control.REKEY_ACK then
		if not d.isNewKey or d.isAcknowledged or #rows > 1 then
			return 7
		end

		d.isAcknowledged = true
		conn.key = conn.pendingKey
		conn.pendingKey = nil
		conn.count = d.matched + 1
		return 0
	end

	return if kind == Control.REPORT then 0 else 7
end

-- A control chunk from the server; each takes effect as it is decoded.
local function readDownControl(r: Bits.Reader, d: Decoding): number
	if d.lane ~= RELIABLE then
		return 7
	end

	local rt = d.rt
	local rows = d.rows
	local kind, rule = Control.read(r, not d.conn.isWelcomed, rows)
	if kind == nil then
		return rule
	end

	for _, row in rows do
		local effectRule = 0
		if kind == Control.WELCOME then
			effectRule = Handshake.welcome(rt, row)
		elseif kind == Control.MISMATCH then
			effectRule = Handshake.mismatch(rt)
		elseif kind == Control.REKEY then
			Handshake.rekeyed(rt, row)
		elseif kind == Control.RATE then
			Handshake.rate(rt, row)
		else
			effectRule = 7
		end

		if effectRule ~= 0 then
			return effectRule
		end
	end

	return 0
end

local function readChunks(r: Bits.Reader, d: Decoding, segments: { Toc.Segment }): number
	local rt = d.rt
	local isServer = rt.side == "server"
	for _, segment in segments do
		local ns = segment.ns
		for _ = 1, segment.count do
			local rule
			if ns == CONTROL then
				rule = if isServer then readUpControl(r, d) else readDownControl(r, d)
			else
				local namespace = rt.namespaceByIndex[ns]
				local isWelcomed = if isServer
					then d.conn.welcomed[ns] ~= nil
					else namespace ~= nil and namespace.status == "welcomed"
				rule = if namespace ~= nil and isWelcomed then readRun(r, d, namespace) else 7
			end

			if rule == 0 and not isServer and not Bits.readAlign(r) then
				rule = 4
			end
			if rule ~= 0 then
				return rule
			end
		end
	end

	return 0
end

local function finishFrame(r: Bits.Reader, d: Decoding): number
	if not Bits.meets(r) then
		return 4
	end

	if d.offset < d.instanceCount then
		return 9
	end

	if d.isNewKey and not d.isAcknowledged then
		return 7
	end

	return 0
end

local function decodeUp(r: Bits.Reader, d: Decoding): number
	local _, ack, headerRule = Header.readUp(r, d.lane)
	if headerRule ~= 0 then
		return headerRule
	end
	d.ack = ack

	local tocRule = Toc.read(r, 1, d.lists)
	if tocRule ~= 0 then
		return tocRule
	end

	local rule = readChunks(r, d, d.lists[1])
	if rule ~= 0 then
		return rule
	end

	return finishFrame(r, d)
end

local function decodeDown(r: Bits.Reader, d: Decoding): number
	local runList = 1
	if d.lane == RELIABLE then
		local mode, tickBits, headerRule = Header.readDownReliable(r)
		if mode == nil then
			return headerRule
		end
		d.mode = mode
		d.tickBits = tickBits

		local tocRule = Toc.read(r, 3, d.lists)
		if tocRule ~= 0 then
			return tocRule
		end

		-- Collections are milestone 4: state and remove lists carry nothing yet.
		if #d.lists[1] > 0 or #d.lists[3] > 0 then
			return 7
		end
		runList = 2
	else
		local isState, _, tick8, headerRule = Header.readDownUnreliable(r)
		if isState == nil then
			return headerRule
		end

		-- State frames are milestone 4.
		if isState then
			return 7
		end
		d.tickBits = tick8

		local tocRule = Toc.read(r, 1, d.lists)
		if tocRule ~= 0 then
			return tocRule
		end
	end

	if not Bits.readAlign(r) then
		return 4
	end

	local rule = readChunks(r, d, d.lists[runList])
	if rule ~= 0 then
		return rule
	end

	return finishFrame(r, d)
end

local function decodingOf(
	rt: State.Runtime,
	conn: State.Connection,
	lane: number,
	list: { Instance? },
	instanceCount: number
): Decoding
	return {
		rt = rt,
		conn = conn,
		lane = lane,
		list = list,
		instanceCount = instanceCount,
		offset = 0,
		lists = {},
		rows = {},
		received = {},
		ack = nil,
		isNewKey = false,
		matched = 0,
		isAcknowledged = false,
		mode = 0,
		tickBits = 0,
	}
end

local function reportRaised(rt: State.Runtime, player: Player?, lane: number, message: unknown)
	State.fact(rt, "decoderRaised", player, nil, lane)

	local now = rt.host.clock()
	if now - rt.decodeReportedAt < rt.config.window then
		return
	end

	rt.decodeReportedAt = now
	rt.host.report(
		`[Lync] decoderRaised: frame decode must not raise, got {Fail.show(message)}; `
			.. "report this as a Lync bug"
	)
end

-- The value nearest `estimate` whose low bits are `bits`, in a counter that wraps at `range`.
local function nearestOf(estimate: number, bits: number, range: number): number
	local ahead = (bits - estimate) % range
	if ahead >= range / 2 then
		ahead -= range
	end

	return estimate + ahead
end

local function estimateOf(rt: State.Runtime): number
	return math.floor((rt.host.now() - rt.epoch) * rt.stateRate)
end

-- The state tick of a frame a client decoded (v5.md §4.1 ticks).
local function tickOf(rt: State.Runtime, d: Decoding): number
	local conn = rt.connection
	if d.lane == UNRELIABLE then
		return nearestOf(estimateOf(rt), d.tickBits, TICK8_RANGE)
	end

	local tick = if d.mode == MODE_UNCHANGED
		then conn.lastTick
		elseif d.mode == MODE_NEXT then conn.lastTick + 1
		else nearestOf(estimateOf(rt), d.tickBits, TICK_RANGE)
	conn.lastTick = tick
	return tick
end

local function runValidators(state: { isRunning: boolean })
	local validator, player, value = coroutine.yield()
	while true do
		state.isRunning = true
		local ok, result = pcall(validator, player, value)
		state.isRunning = false
		validator, player, value = coroutine.yield(ok, result)
	end
end

local function reportFault(
	rt: State.Runtime,
	definition: State.Definition,
	validator: (...any) -> any,
	code: "validatorError" | "validatorYielded",
	requirement: string,
	got: any
)
	State.count(rt, "validatorErrors", nil, 1)

	local now = rt.host.clock()
	if now - definition.reportedAt < rt.config.window then
		return
	end

	definition.reportedAt = now
	local source, line = debug.info(validator, "sl")
	local at = { source = source, line = line }
	local subject = `{definition.subject} validator`
	local _, message = pcall(Fail.declaration, code, at, subject, requirement, got)
	rt.host.report(message)
end

-- Runs a definition's validator in the validator thread (v5.md §6.1 step 6), and answers
-- whether the message is accepted. A yield abandons the thread to whoever resumes it.
local function isValid(
	rt: State.Runtime,
	definition: State.Definition,
	player: Player?,
	value: any
): boolean
	local validator = definition.validator
	if validator == nil then
		return true
	end

	local thread = rt.validatorThread
	if thread == nil then
		local state = { isRunning = false }
		thread = coroutine.create(runValidators)
		coroutine.resume(thread, state)
		rt.validatorThread = thread
		rt.validatorState = state
	end

	local _, ok, result = coroutine.resume(thread, validator, player, value)
	if rt.validatorState.isRunning then
		rt.validatorThread = nil
		reportFault(rt, definition, validator, "validatorYielded", "return without yielding", Fail.NONE)
		return false
	end

	if not ok then
		local got = if typeof(result) == "string"
			then string.gsub(result, "^.-:%d+: ", "", 1)
			else result
		reportFault(rt, definition, validator, "validatorError", "return a boolean without raising", got)
		return false
	end

	if result == true then
		return true
	end

	if result == false then
		State.count(rt, "validatorRejections", player, 1)
		return false
	end

	reportFault(rt, definition, validator, "validatorError", "return a boolean without raising", result)
	return false
end

local function isOverLimit(
	rt: State.Runtime,
	conn: State.Connection,
	definition: State.Definition
): boolean
	local limit = definition.ir.limit
	if limit == nil or Buckets.take(Connection.limitOf(rt, conn, definition), 1, rt.host.clock()) then
		return false
	end

	State.fact(rt, "overLimit", conn.player, definition, limit.perSecond, limit.burst)
	return true
end

local function deliver(rt: State.Runtime, definition: State.Definition, ...: any)
	for _, listener in definition.listeners do
		rt.host.spawn(listener, ...)
	end
end

local function reject(rt: State.Runtime, conn: State.Connection, received: Received)
	local definition = received.definition
	rt.answer(
		rt,
		definition,
		conn.player,
		received.slot,
		received.epoch,
		State.OUTCOME_REJECTED,
		nil
	)
end

-- Answers whether a message is unresolved, recording it: a fact on a server, a count on a client.
local function isUnresolved(rt: State.Runtime, conn: State.Connection, received: Received): boolean
	if received.what == 0 then
		return false
	end

	if rt.side == "client" then
		State.count(rt, "unresolvedMessages", nil, 1)
		return true
	end

	State.fact(
		rt,
		"unresolved",
		conn.player,
		received.definition,
		received.what,
		received.missValue
	)
	return true
end

local function processAnswer(rt: State.Runtime, conn: State.Connection, received: Received)
	local request =
		Requests.match(rt, conn, received.definition, received.slot, received.epoch)
	if request == nil or isUnresolved(rt, conn, received) then
		return
	end

	Requests.settle(rt, conn, request, received.outcome, received.value)
end

-- Steps 5 to 7 for one event or ask; a client only resolves and delivers.
local function processMessage(rt: State.Runtime, conn: State.Connection, received: Received)
	local definition = received.definition
	local player = conn.player
	local isAsk = received.role == "ask"
	if isAsk and not Requests.admit(rt, conn, definition, received.slot, received.epoch) then
		return
	end

	local isServer = rt.side == "server"
	local isDropped = isUnresolved(rt, conn, received)
		or (isServer and isOverLimit(rt, conn, definition))
		or (isServer and not isValid(rt, definition, player, received.value))
	if isDropped then
		if isAsk then
			reject(rt, conn, received)
		end
		return
	end

	if isAsk and isServer then
		Requests.handle(rt, conn, definition, received.slot, received.epoch, player, received.value)
	elseif isAsk then
		Requests.handle(rt, conn, definition, received.slot, received.epoch, received.value)
	elseif isServer then
		deliver(rt, definition, player, received.value)
	else
		deliver(rt, definition, received.value)
	end
end

local function process(rt: State.Runtime, conn: State.Connection, d: Decoding)
	local counters = rt.counters
	local player = conn.player
	for _, received in d.received do
		local definition = received.definition
		Counters.add(counters, definition.receivedSlot, player, 1)
		Counters.add(counters, definition.bytesReceivedSlot, player, received.bytes)
		if received.role == "answer" then
			processAnswer(rt, conn, received)
		else
			processMessage(rt, conn, received)
		end
	end
end

local function failTag(rt: State.Runtime, conn: State.Connection, lane: number, expected: number)
	State.fact(rt, "tagMismatch", conn.player, nil, lane, expected % COUNT_RANGE)
	conn.failures += 1
	if conn.failures < DESYNC_FAILURES then
		return
	end

	conn.failures = 0
	local canRekey = conn.key ~= nil and rt.host.clock() - conn.rekeyAt >= REKEY_INTERVAL
	if canRekey then
		Handshake.rekey(rt, conn)
	end
	State.fact(rt, "desync", conn.player, nil, DESYNC_FAILURES, if canRekey then 1 else 0)
end

-- The count a reliable frame's tag matches, with the current key at e to e + 4 or with a pending
-- new key at 0 to 4, and whether it was the new key.
local function matchReliable(
	conn: State.Connection,
	frame: buffer,
	instanceCount: number
): (number?, boolean)
	local length = buffer.len(frame) - TAG_BYTES
	if length < 0 then
		return nil, false
	end

	local tag = Tag.read(frame)
	local key = conn.key
	if key ~= nil then
		for count = conn.count, conn.count + LOOKAHEAD do
			if Tag.compute(key, count, RELIABLE, frame, length, instanceCount, conn.cover) == tag then
				return count, false
			end
		end
	end

	local pendingKey = conn.pendingKey
	if pendingKey ~= nil then
		for count = 0, LOOKAHEAD do
			local computed =
				Tag.compute(pendingKey, count, RELIABLE, frame, length, instanceCount, conn.cover)
			if computed == tag then
				return count, true
			end
		end
	end

	return nil, false
end

local function isTagAt(
	conn: State.Connection,
	key: buffer?,
	seq: number,
	frame: buffer,
	instanceCount: number
): boolean
	if key == nil or seq < 0 then
		return false
	end

	local length = buffer.len(frame) - TAG_BYTES
	return Tag.compute(key, seq, UNRELIABLE, frame, length, instanceCount, conn.cover)
		== Tag.read(frame)
end

-- The extended seq an unreliable frame's tag matches, trying the two neighbouring extensions,
-- with either key; else nil and the extension tried first.
local function matchUnreliable(
	conn: State.Connection,
	frame: buffer,
	instanceCount: number
): (number?, number)
	if buffer.len(frame) < TAG_BYTES then
		return nil, 0
	end

	local seq12 = Bits.read(Bits.reader(frame, 0, buffer.len(frame) - TAG_BYTES), SEQ_BITS)
	if seq12 == nil then
		return nil, 0
	end

	local full = Seq.extend(Replay.newest(conn.window), seq12)
	for _, seq in { full, full - SEQ_RANGE, full + SEQ_RANGE } do
		if
			isTagAt(conn, conn.key, seq, frame, instanceCount)
			or isTagAt(conn, conn.pendingKey, seq, frame, instanceCount)
		then
			return seq, full
		end
	end

	return nil, full
end

local function isPaid(
	rt: State.Runtime,
	conn: State.Connection,
	lane: number,
	frame: buffer,
	instanceCount: number
): boolean
	local now = rt.host.clock()
	local charge = buffer.len(frame) + INSTANCE_CHARGE * instanceCount
	local frames = conn.buckets[lane * 2 + 1]
	local bytes = conn.buckets[lane * 2 + 2]

	return Buckets.take(frames, 1, now) and Buckets.take(bytes, charge, now)
end

-- Step 3. Answers whether the frame goes on to decoding, filling in what its tag matched.
local function isAuthentic(
	rt: State.Runtime,
	conn: State.Connection,
	lane: number,
	frame: buffer,
	instanceCount: number,
	d: Decoding
): boolean
	if lane == UNRELIABLE then
		local seq, expected = matchUnreliable(conn, frame, instanceCount)
		if seq == nil then
			failTag(rt, conn, lane, expected)
			return false
		end

		conn.failures = 0
		local window = conn.window
		local status = Replay.status(window, seq)
		if status ~= 0 then
			State.fact(rt, "replayed", conn.player, nil, seq, Replay.newest(window) - seq, if status == 1 then 1 else 0)
			return false
		end

		Replay.accept(window, seq)
		return true
	end

	local count, isNewKey = matchReliable(conn, frame, instanceCount)
	if count == nil then
		failTag(rt, conn, lane, conn.count)
		return false
	end

	conn.failures = 0
	conn.hasTagged = true
	d.isNewKey = isNewKey
	d.matched = count
	if isNewKey then
		return true
	end

	if count > conn.count then
		State.fact(rt, "frameGap", conn.player, nil, count - conn.count)
	end
	conn.count = count + 1
	return true
end

local function receiveOnServer(
	rt: State.Runtime,
	player: Player,
	lane: number,
	count: number,
	frame: unknown,
	list: unknown
)
	local conn = rt.connections[player]
	if conn == nil then
		return
	end

	local instanceCount = instanceCountOf(count, frame, list)
	if instanceCount == nil then
		State.fact(rt, "malformed", player, nil, lane, 1)
		return
	end

	local bytes = frame :: buffer
	local instances = (list or {}) :: { Instance? }
	if not isPaid(rt, conn, lane, bytes, instanceCount) then
		State.fact(rt, "overBudget", player, nil, lane, buffer.len(bytes), instanceCount, 0)
		if lane == RELIABLE then
			local matched, isNewKey = matchReliable(conn, bytes, instanceCount)
			if matched ~= nil and not isNewKey then
				conn.count = matched + 1
			end
		end
		return
	end

	if lane == RELIABLE and not conn.hasTagged then
		local hellos = Handshake.untagged(bytes)
		if hellos ~= nil then
			for _, hello in hellos do
				Handshake.hello(rt, conn, hello)
			end
			return
		end
	end

	local d = decodingOf(rt, conn, lane, instances, instanceCount)
	if not isAuthentic(rt, conn, lane, bytes, instanceCount, d) then
		return
	end

	local r, openRule = Frame.open(bytes, false, lane)
	if r == nil then
		State.fact(rt, "malformed", player, nil, lane, openRule)
		return
	end

	local now = rt.host.clock()
	local elements = conn.buckets[Connection.ELEMENTS]
	local allowance = math.floor(Buckets.peek(elements, now))
	r.budget = allowance
	local ok, rule = pcall(decodeUp, r, d)
	local used = allowance - r.budget
	Buckets.take(elements, math.min(used, allowance), now)
	if not ok then
		reportRaised(rt, player, lane, rule)
		return
	end

	if rule == 10 then
		State.fact(rt, "overBudget", player, nil, lane, buffer.len(bytes), instanceCount, used)
		return
	end

	if rule ~= 0 then
		State.fact(rt, "malformed", player, nil, lane, rule)
		return
	end

	local ack = d.ack
	if ack ~= nil then
		State.fact(rt, "impossibleAck", player, nil, Seq.extend(-1, ack.seq))
	end

	process(rt, conn, d)
end

local function receiveOnClient(rt: State.Runtime, lane: number, count: number, frame: unknown, list: unknown)
	local instanceCount = instanceCountOf(count, frame, list)
	if instanceCount == nil then
		State.fact(rt, "malformed", nil, nil, lane, 1)
		return
	end

	local bytes = frame :: buffer
	local r, openRule = Frame.open(bytes, true, lane)
	if r == nil then
		State.fact(rt, "malformed", nil, nil, lane, openRule)
		return
	end

	local conn = rt.connection
	local d = decodingOf(rt, conn, lane, (list or {}) :: { Instance? }, instanceCount)
	r.budget = State.CLIENT_ALLOWANCE
	local ok, rule = pcall(decodeDown, r, d)
	if not ok then
		reportRaised(rt, nil, lane, rule)
		return
	end

	if rule == 10 then
		State.count(rt, "refusedFrames", nil, 1)
		return
	end

	if rule ~= 0 then
		State.fact(rt, "malformed", nil, nil, lane, rule)
		return
	end

	rt.dispatchTick = tickOf(rt, d)
	process(rt, conn, d)
	rt.dispatchTick = nil
end

-- Public ------------------------------------------------------------------------------------------

--[=[
	Receives one remote call: on a server, v5.md §6.1 steps 1 to 7; on a client, the shape, the
	decode (§4.8) and delivery.

	@param rt     the runtime
	@param player the sender on a server; nil on a client
	@param lane   the remote it came on
	@param ...    the remote's arguments, untouched
]=]
function Inbound.receive(rt: State.Runtime, player: Player?, lane: number, ...: unknown)
	local frame, list = ...
	if player == nil then
		receiveOnClient(rt, lane, select("#", ...), frame, list)
		return
	end

	receiveOnServer(rt, player, lane, select("#", ...), frame, list)
end

return table.freeze(Inbound)
