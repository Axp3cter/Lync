--!strict

--[=[
	Handshake

	The control flows of v5.md §4.5–§4.6: `HELLO`, `WELCOME`, `MISMATCH`, `RATE` and `REKEY`.

	- **Server.** Namespaces get server-wide indices in the order of their first server-side
	  use. Each connection's `HELLO`s are answered in arrival order with `WELCOME` or
	  `MISMATCH`; one naming a namespace not loaded yet waits up to 10 s, holding the answers
	  behind it. A connection's first `WELCOME` carries the tag key, the state tick epoch and
	  rate, `tag.cover` and the permutation seed.
	- **Client.** A namespace's first use sends `HELLO`; answers are matched to `HELLO`s by
	  order. Until its first `WELCOME` a client sends only untagged frames of `HELLO`s, which the
	  server reads while it has accepted no tagged frame (the untagged-`HELLO` rule).

	Control messages take effect as they are decoded, so the chunks after a `WELCOME` in the
	same frame decode with its namespace welcomed and its permutation applied.
]=]

-- Imports -----------------------------------------------------------------------------------------

local Bits = require("../wire/bits")
local Buckets = require("./buckets")
local Connection = require("./connection")
local Control = require("../transport/control")
local Counters = require("../diag/counters")
local Header = require("../transport/header")
local Ir = require("../plan/ir")
local Permutation = require("./permutation")
local State = require("./state")
local Toc = require("../transport/toc")

-- Module ------------------------------------------------------------------------------------------

local Handshake = {}

-- Constants ---------------------------------------------------------------------------------------

const UP_SPACE = 1
const DOWN_SPACE = 2

const CONTROL = 0
const RELIABLE = 0
const MAX_RELIABLE_BYTES = 16_384

const MESSAGE_FIELDS = table.freeze({
	"messagesSent",
	"messagesReceived",
	"bytesSent",
	"bytesReceived",
})

-- Private -----------------------------------------------------------------------------------------

local function definitionOf(rt: State.Runtime, namespace: State.Namespace, ir: Ir.Definition)
	local subject = `{namespace.ir.name}.{ir.name}`
	local slots = {}
	for i, field in MESSAGE_FIELDS do
		slots[i] = Counters.slot(rt.counters, `{field}.{subject}`)
	end

	local limit = ir.limit
	local bucket = nil
	if rt.side == "client" and ir.from == "client" and limit ~= nil then
		bucket = Buckets.new(limit.perSecond, limit.burst, rt.host.clock())
	end

	local definition: State.Definition = {
		ir = ir,
		namespace = namespace,
		subject = subject,
		isFromClient = ir.from == "client",
		isUnreliable = ir.kind == "event" and ir.lane == "unreliable",
		eventId = -1,
		askId = -1,
		answerId = -1,
		listeners = {},
		validator = nil,
		handler = nil,
		reportedAt = -math.huge,
		bucket = bucket,
		fifo = {},
		sentSlot = slots[1],
		receivedSlot = slots[2],
		bytesSentSlot = slots[3],
		bytesReceivedSlot = slots[4],
	}
	namespace.definitions[ir.name] = definition
end

local function assignIds(namespace: State.Namespace, space: { Ir.Entry })
	for _, entry in space do
		local definition = namespace.definitions[entry.definition.name]
		if entry.role == "event" then
			definition.eventId = entry.id
		elseif entry.role == "ask" then
			definition.askId = entry.id
		else
			definition.answerId = entry.id
		end
	end
end

-- Builds a namespace's permutations: of the space a side sends, and of the one it reads.
local function permute(namespace: State.Namespace, seed: number, isServer: boolean)
	local ir = namespace.ir
	local upForward, upInverse = Permutation.build(seed, ir.hashLow, UP_SPACE, #ir.up)
	local downForward, downInverse = Permutation.build(seed, ir.hashLow, DOWN_SPACE, #ir.down)
	namespace.sendIds = if isServer then downForward else upForward
	namespace.readIds = if isServer then upInverse else downInverse
end

local function hashOf(hello: Control.Hello): string
	return `{hello.hashLow}:{hello.hashHigh}`
end

local function firstOf(rt: State.Runtime, conn: State.Connection): Control.First
	local pinnedKey = rt.pinnedKey
	local keyLow = if pinnedKey == nil then rt.host.entropy32() else buffer.readu32(pinnedKey, 0)
	local keyHigh = if pinnedKey == nil then rt.host.entropy32() else buffer.readu32(pinnedKey, 4)
	conn.key = Connection.key(keyLow, keyHigh)
	conn.cover = rt.config.cover
	conn.isWelcomed = true

	return {
		epoch = rt.epoch,
		stateRate = rt.stateRate,
		keyLow = keyLow,
		keyHigh = keyHigh,
		cover = conn.cover,
		permutationSeed = rt.permutationSeed,
		probeOneIn = 0,
		probeMaxPerSecond = 0,
		beacon = 0,
	}
end

local function refuse(rt: State.Runtime, conn: State.Connection, hello: Control.Hello)
	local namespace = rt.namespaces[hello.name]
	if namespace ~= nil then
		conn.refused[namespace.index] = true
	end

	rt.control(rt, conn.player, Control.MISMATCH, true)
	State.fact(
		rt,
		"schemaMismatch",
		conn.player,
		nil,
		hello.version,
		if hello.seed == State.BUILD_SEED then 0 else 1,
		hello.hashLow,
		hello.hashHigh,
		if namespace == nil then 1 else 0
	)
end

-- Answers one `HELLO`, or answers whether it must wait for its namespace to load.
local function answer(rt: State.Runtime, conn: State.Connection, waiting: State.Waiting): boolean
	local hello = waiting.hello
	local namespace = rt.namespaces[hello.name]
	if namespace == nil then
		if rt.host.clock() - waiting.at < State.WAIT_SECONDS then
			return false
		end

		refuse(rt, conn, hello)
		return true
	end

	local ir = namespace.ir
	if
		hello.version ~= State.VERSION
		or hello.seed ~= State.BUILD_SEED
		or hello.hashLow ~= ir.hashLow
		or hello.hashHigh ~= ir.hashHigh
	then
		refuse(rt, conn, hello)
		return true
	end

	local first = if conn.isWelcomed then nil else firstOf(rt, conn)
	conn.welcomed[namespace.index] = true
	rt.control(rt, conn.player, Control.WELCOME, { index = namespace.index, first = first })
	return true
end

local function answerWaiting(rt: State.Runtime, conn: State.Connection)
	local waiting = conn.waiting
	while #waiting > 0 and answer(rt, conn, waiting[1]) do
		table.remove(waiting, 1)
	end
end

local function releaseHolds(rt: State.Runtime, namespace: State.Namespace, isDropped: boolean)
	local conn = rt.connection
	local kept = {}
	for _, message in rt.pending do
		local definition = message.definition
		if definition == nil or definition.namespace ~= namespace or not message.isHeld then
			table.insert(kept, message)
			continue
		end

		message.isHeld = false
		conn.holdBytes -= message.payload.bytes
		State.count(rt, "heldBytes", nil, -message.payload.bytes)
		if not isDropped then
			table.insert(kept, message)
		end
	end
	rt.pending = kept
end

-- Public ------------------------------------------------------------------------------------------

--[=[
	Records a `HELLO` from a client and answers what it can, in arrival order. A second `HELLO`
	for a namespace is `repeatedHello` and ignored.

	@param rt    the server's runtime
	@param conn  the client's connection
	@param hello the message
]=]
function Handshake.hello(rt: State.Runtime, conn: State.Connection, hello: Control.Hello)
	local firstHash = conn.hashByName[hello.name]
	if firstHash ~= nil then
		local hashChanged = if firstHash == hashOf(hello) then 0 else 1
		State.fact(rt, "repeatedHello", conn.player, nil, hashChanged)
		return
	end

	conn.hashByName[hello.name] = hashOf(hello)
	table.insert(conn.waiting, { hello = hello, at = rt.host.clock() })
	answerWaiting(rt, conn)
end

--[=[
	Sends a client's `HELLO` for a namespace on its first use.

	@param rt        the client's runtime
	@param namespace the namespace
]=]
function Handshake.introduce(rt: State.Runtime, namespace: State.Namespace)
	local ir = namespace.ir
	namespace.status = "hello"
	table.insert(rt.connection.asked, namespace)
	rt.control(rt, nil, Control.HELLO, {
		version = State.VERSION,
		seed = State.BUILD_SEED,
		hashLow = ir.hashLow,
		hashHigh = ir.hashHigh,
		name = ir.name,
	})
end

--[=[
	Creates a namespace's run-time record. On a server it takes the next index, gets its
	permutations and answers the `HELLO`s waiting for it.

	@param  rt the runtime
	@param  ir the planned namespace
	@return the namespace
]=]
function Handshake.load(rt: State.Runtime, ir: Ir.Namespace): State.Namespace
	local namespace: State.Namespace = {
		ir = ir,
		index = 0,
		definitions = {},
		status = "new",
		sendIds = {},
		readIds = {},
		view = nil,
	}
	for _, definition in ir.definitions do
		definitionOf(rt, namespace, definition)
	end
	assignIds(namespace, ir.up)
	assignIds(namespace, ir.down)
	rt.namespaces[ir.name] = namespace
	if rt.side == "client" then
		return namespace
	end

	local index = #rt.namespaceByIndex + 1
	namespace.index = index
	namespace.status = "welcomed"
	rt.namespaceByIndex[index] = namespace
	permute(namespace, rt.permutationSeed, true)
	for _, conn in rt.connections do
		answerWaiting(rt, conn)
	end

	return namespace
end

--[=[
	Applies a `MISMATCH` on a client: the oldest unanswered `HELLO`'s namespace is refused, its
	held sends are dropped, and `schemaMismatch` is reported natively, once.

	@param  rt the client's runtime
	@return 0, or 7 when no `HELLO` awaits an answer
]=]
function Handshake.mismatch(rt: State.Runtime): number
	local namespace = table.remove(rt.connection.asked, 1)
	if namespace == nil then
		return 7
	end

	namespace.status = "refused"
	releaseHolds(rt, namespace, true)
	rt.host.report(
		`[Lync] schemaMismatch: namespace {namespace.ir.name} must match the server's schema, `
			.. "version and build seed; publish one build to every server"
	)
	return 0
end

--[=[
	Applies a `RATE` on a client.

	@param rt   the client's runtime
	@param rate the new epoch and rate
]=]
function Handshake.rate(rt: State.Runtime, rate: Control.Rate)
	rt.epoch = rate.epoch
	rt.stateRate = rate.stateRate
end

--[=[
	Sends `REKEY` to a client: a new key the server also tries until the client acknowledges
	it (v5.md §4.5).

	@param rt   the server's runtime
	@param conn the client's connection
]=]
function Handshake.rekey(rt: State.Runtime, conn: State.Connection)
	local keyLow = rt.host.entropy32()
	local keyHigh = rt.host.entropy32()
	conn.pendingKey = Connection.key(keyLow, keyHigh)
	conn.rekeyAt = rt.host.clock()
	rt.control(rt, conn.player, Control.REKEY, { keyLow = keyLow, keyHigh = keyHigh })
end

--[=[
	Applies a `REKEY` on a client: it switches key, restarts its count, and acknowledges in its
	next reliable frame.

	@param rt    the client's runtime
	@param rekey the new key
]=]
function Handshake.rekeyed(rt: State.Runtime, rekey: Control.Rekey)
	local conn = rt.connection
	conn.key = Connection.key(rekey.keyLow, rekey.keyHigh)
	conn.count = 0
	rt.control(rt, nil, Control.REKEY_ACK, true)
end

--[=[
	Answers the `HELLO`s that have waited 10 s for their namespace. Called every step.

	@param rt the server's runtime
]=]
function Handshake.sweep(rt: State.Runtime)
	for _, conn in rt.connections do
		if #conn.waiting > 0 then
			answerWaiting(rt, conn)
		end
	end
end

--[=[
	Reads a frame as untagged `HELLO`s, as a client sends before its first `WELCOME`: a reliable
	upstream frame of nothing but `HELLO` control chunks, decoded canonically.

	@param  frame the frame
	@return the `HELLO`s, or nil when the frame is anything else
]=]
function Handshake.untagged(frame: buffer): { Control.Hello }?
	if buffer.len(frame) > MAX_RELIABLE_BYTES then
		return nil
	end

	local r = Bits.reader(frame)
	local _, ack, headerRule = Header.readUp(r, RELIABLE)
	local lists = {}
	if headerRule ~= 0 or ack ~= nil or Toc.read(r, 1, lists) ~= 0 then
		return nil
	end

	local hellos = {}
	local rows = {}
	for _, segment in lists[1] do
		if segment.ns ~= CONTROL then
			return nil
		end

		for _ = 1, segment.count do
			local kind = Control.read(r, false, rows)
			if kind ~= Control.HELLO then
				return nil
			end
			table.move(rows, 1, #rows, #hellos + 1, hellos)
		end
	end

	if #hellos == 0 or not Bits.meets(r) then
		return nil
	end

	return hellos
end

--[=[
	Applies a `WELCOME` on a client: the oldest unanswered `HELLO`'s namespace is welcomed, with
	its index and permutation, and its held sends are released; the connection's first also
	sets the key, the state tick epoch and rate, `tag.cover` and the permutation seed.

	@param  rt      the client's runtime
	@param  welcome the message
	@return 0, or 7 when no `HELLO` awaits an answer
]=]
function Handshake.welcome(rt: State.Runtime, welcome: Control.Welcome): number
	local conn = rt.connection
	local namespace = table.remove(conn.asked, 1)
	if namespace == nil then
		return 7
	end

	local first = welcome.first
	if first ~= nil then
		conn.key = Connection.key(first.keyLow, first.keyHigh)
		conn.cover = first.cover
		conn.isWelcomed = true
		rt.epoch = first.epoch
		rt.stateRate = first.stateRate
		rt.permutationSeed = first.permutationSeed
	end

	namespace.index = welcome.index
	namespace.status = "welcomed"
	rt.namespaceByIndex[welcome.index] = namespace
	permute(namespace, rt.permutationSeed, false)
	releaseHolds(rt, namespace, false)
	return 0
end

return table.freeze(Handshake)
