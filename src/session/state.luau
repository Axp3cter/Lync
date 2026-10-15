--!strict

--[=[
	State

	The record one runtime keeps (m2-plan.md §2): its side's host, diagnostics, configuration,
	namespaces and connections, and what waits to be sent. No module keeps runtime state at
	module level, so one process holds a server and many clients.

	The record's types live here, below every layer that reads it: `session` decodes into it,
	`sched` sends from it and `api` builds it. Two of its fields are the scheduler's queueing,
	`answer` and `control`, which `session` code calls without requiring a later layer.

	Times are `os.clock()` seconds (`host.clock`) unless a field says `GetServerTimeNow()`.
]=]

-- Imports -----------------------------------------------------------------------------------------

local Buckets = require("./buckets")
local Console = require("../diag/console")
local Control = require("../transport/control")
local Counters = require("../diag/counters")
local Facts = require("../diag/facts")
local Frame = require("../transport/frame")
local Host = require("../host/host")
local Ir = require("../plan/ir")
local Replay = require("./replay")

-- Module ------------------------------------------------------------------------------------------

local State = {}

-- Types -------------------------------------------------------------------------------------------

--- A token bucket's settings: `perSecond` tokens a second, holding at most `burst`.
export type Limit = { perSecond: number, burst: number }

--[=[
	The options of `Lync.configure` (v5.md §7.5), resolved.

	@field stateRate        `state.rate`, state ticks per second
	@field stateBudget      `state.budget`, accepted for milestone 4
	@field stateFloor       `state.floor`, accepted for milestone 4
	@field reliableFrames   `inbound.reliable.frames`
	@field reliableBytes    `inbound.reliable.bytes`
	@field unreliableFrames `inbound.unreliable.frames`
	@field unreliableBytes  `inbound.unreliable.bytes`
	@field elements         `inbound.elements`
	@field cover            `tag.cover`, bytes
	@field window           `observe.window`
	@field perPlayerEvents  `observe.perPlayerEvents`
	@field serverEvents     `observe.serverEvents`
	@field console          `console`
	@field profile          `profile`
]=]
export type Config = {
	stateRate: number,
	stateBudget: number,
	stateFloor: number,
	reliableFrames: Limit,
	reliableBytes: Limit,
	unreliableFrames: Limit,
	unreliableBytes: Limit,
	elements: Limit,
	cover: number,
	window: number,
	perPlayerEvents: number,
	serverEvents: number,
	console: boolean,
	profile: boolean,
}

--[=[
	A message's encoded payload, kept apart from its run so a run is assembled at flush.

	@field bits      the payload's bits, zero-padded to a byte boundary
	@field bitLength how many of `bits` are the payload's
	@field tail      its tail segment
	@field instances the instances it references, in order of first reference
	@field bytes     its size, the bits rounded up to bytes plus the tail
]=]
export type Payload = {
	bits: buffer,
	bitLength: number,
	tail: buffer,
	instances: { Instance },
	bytes: number,
}

--[=[
	A request this side asked and waits on.

	@field definition the request
	@field player     the player asked, on a server
	@field thread     the caller's thread, resumed with the result
	@field deadline   when it times out
	@field slot       its slot, 0 to 15, or -1 while it waits for one
	@field epoch      its slot's epoch when it was taken
	@field result     the result once it is settled
]=]
export type Request = {
	definition: Definition,
	player: Player?,
	thread: thread,
	deadline: number,
	slot: number,
	epoch: number,
	result: { [string]: any }?,
}

--[=[
	An ask this side read and has not answered yet.

	@field definition the request
	@field epoch      the ask's epoch
	@field thread     the handler's thread, once it runs
	@field deadline   when it is answered `unanswered` if the handler has not returned
	@field isAnswered whether its answer is queued, or it was abandoned
]=]
export type Answering = {
	definition: Definition,
	epoch: number,
	thread: thread?,
	deadline: number,
	isAnswered: boolean,
}

--[=[
	One message waiting to be sent.

	@field role       what it is
	@field definition its definition; nil for control
	@field target     a server event's target; the player of a server's ask, answer or control
	@field payload    its encoded payload
	@field request    an ask's request
	@field slot       an ask's or answer's slot
	@field epoch      an ask's or answer's epoch
	@field outcome    an answer's outcome: 0 value, 1 rejected, 2 unanswered
	@field control    a control message's type
	@field row        a control message's fields
	@field isHeld     whether a client counts it in its join hold
]=]
export type Message = {
	role: "event" | "ask" | "answer" | "control",
	definition: Definition?,
	target: any,
	payload: Payload,
	request: Request?,
	slot: number,
	epoch: number,
	outcome: number,
	control: number,
	row: any,
	isHeld: boolean,
}

--[=[
	A definition at run time.

	@field ir            the planned definition
	@field namespace     its namespace
	@field subject       `namespace.definition`, for messages
	@field isFromClient  whether a client sends its events and asks
	@field isUnreliable  whether it is an event on the unreliable lane
	@field eventId       its event's canonical id, or -1
	@field askId         its ask's canonical id, or -1
	@field answerId      its answer's canonical id, or -1
	@field listeners     `connect` handlers
	@field validator     the server's `validate` function
	@field handler       the `handle` function
	@field reportedAt    when a validator fault was last reported natively
	@field bucket        a client's `limit` bucket
	@field fifo          a client's over-limit reliable sends, oldest first
	@field sentSlot      the `messagesSent` counter
	@field receivedSlot  the `messagesReceived` counter
	@field bytesSentSlot the `bytesSent` counter
	@field bytesReceivedSlot the `bytesReceived` counter
]=]
export type Definition = {
	ir: Ir.Definition,
	namespace: Namespace,
	subject: string,
	isFromClient: boolean,
	isUnreliable: boolean,
	eventId: number,
	askId: number,
	answerId: number,
	listeners: { (...any) -> () },
	validator: ((...any) -> any)?,
	handler: ((...any) -> ...any)?,
	reportedAt: number,
	bucket: Buckets.Bucket?,
	fifo: { Message },
	sentSlot: number,
	receivedSlot: number,
	bytesSentSlot: number,
	bytesReceivedSlot: number,
}

--[=[
	A namespace at run time.

	@field ir          the planned namespace
	@field index       its server-wide index; on a client 0 until its `WELCOME`
	@field definitions its definitions by name
	@field status      a client's handshake: `HELLO` not sent, sent, welcomed or refused
	@field sendIds     wire ids by canonical id + 1, of the space this side sends
	@field readIds     canonical ids by wire id + 1, of the space this side reads
	@field view        the side's view
]=]
export type Namespace = {
	ir: Ir.Namespace,
	index: number,
	definitions: { [string]: Definition },
	status: "new" | "hello" | "welcomed" | "refused",
	sendIds: { number },
	readIds: { number },
	view: any,
}

--[=[
	A `HELLO` a server has not answered yet.

	@field hello the message
	@field at    when it arrived
]=]
export type Waiting = { hello: Control.Hello, at: number }

--[=[
	A chunk a server holds for a player until its namespace's `WELCOME` (v5.md §5.3).

	@field chunk      the chunk
	@field lane       the remote it goes on
	@field index      its namespace's index
	@field definition its run's definition
	@field count      its run's message count
]=]
export type Held = {
	chunk: Frame.Chunk,
	lane: number,
	index: number,
	definition: Definition,
	count: number,
}

--[=[
	One peer's connection: a server keeps one per player, a client one to the server.

	@field player        the player, on a server
	@field key           the tag key, once the first `WELCOME` is sent or received
	@field cover         `tag.cover` as the first `WELCOME` carried it
	@field count         a client's next upstream reliable count; a server's expected count e
	@field pendingKey    a server's new key while its `REKEY` is unacknowledged
	@field rekeyAt       when a server last sent `REKEY`
	@field failures      a server's consecutive tag failures
	@field hasTagged     whether a server has accepted a tagged frame
	@field isWelcomed    whether the first `WELCOME` was sent (server) or received (client)
	@field seq           a client's next upstream unreliable seq
	@field window        a server's replay window
	@field waiting       a server's unanswered `HELLO`s, in arrival order
	@field asked         a client's namespaces whose `HELLO` awaits its answer, in order
	@field hashByName    a server's first `HELLO` hash per namespace name, as "low:high"
	@field welcomed      a server's namespaces welcomed, by index, as decoding sees them
	@field refused       a server's namespaces answered `MISMATCH`, by index
	@field sending       a server's namespaces whose `WELCOME` has been sent, by index
	@field holds         a server's held chunks, in order
	@field holdBytes     the bytes held: a server's chunks, or a client's held messages
	@field lastTick      the last reliable tick sent (server) or received (client); -1 for none
	@field asking        the requests this side asked, by slot
	@field queued        requests waiting for a free slot, oldest first
	@field epochs        the asking slots' epochs, by slot + 1
	@field answering     the asks this side read and has not answered, by slot
	@field buckets       a server's inbound buckets: reliable frames and bytes, unreliable frames
	                     and bytes, elements
	@field limits        a server's `limit` buckets by definition
]=]
export type Connection = {
	player: Player?,
	key: buffer?,
	cover: number,
	count: number,
	pendingKey: buffer?,
	rekeyAt: number,
	failures: number,
	hasTagged: boolean,
	isWelcomed: boolean,
	seq: number,
	window: Replay.Window,
	waiting: { Waiting },
	asked: { Namespace },
	hashByName: { [string]: string },
	welcomed: { [number]: true },
	refused: { [number]: true },
	sending: { [number]: true },
	holds: { Held },
	holdBytes: number,
	lastTick: number,
	asking: { [number]: Request },
	queued: { Request },
	epochs: { number },
	answering: { [number]: Answering },
	buckets: { Buckets.Bucket },
	limits: { [Definition]: Buckets.Bucket },
}

--[=[
	A live set of players, `Lync.group(players?)`; leaving players are removed (v5.md §3.5).

	@field kind        marks a group among targets
	@field members     the players in it
	@field memberCount how many
]=]
export type Group = {
	kind: "group",
	members: { [Player]: true },
	memberCount: number,
}

--[=[
	Who a server send goes to (v5.md §3.5): a player, an array of players, a group, `Lync.all`
	or `Lync.except(target)`.
]=]
export type Target = any

--- How a side's scheduler flushes (v5.md §5.1).
export type Mode = "automatic" | "manual"

--[=[
	One side's runtime.

	@field side             which side it runs
	@field host             its engine
	@field config           its options
	@field pinnedKey        the test seam's tag key, server only
	@field facts            its facts
	@field counters         its counters
	@field console          its console
	@field namespaces       its namespaces by name
	@field namespaceByIndex its namespaces by server-wide index
	@field permutationSeed  the server's id permutation seed; a client's from its first `WELCOME`
	@field epoch            the state tick epoch, `GetServerTimeNow()` seconds
	@field stateRate        state ticks per second
	@field isRateChanged    a server's `state.rate` changed; `RATE` goes at the next state tick
	@field lastTick         the state tick of the server's last flush
	@field connections      a server's connections by player
	@field connection       a client's connection to the server
	@field knownPlayers     every player a server has seen, as targets recognise them
	@field pending          messages in call order, waiting for the next flush
	@field mode             the scheduler's mode
	@field isFlushing       whether a flush is running
	@field accumulated      a client's time since its last automatic flush
	@field pendingSteps     steps data has waited under the manual scheduler
	@field isMissedReported whether that wait was reported
	@field firstUseAt       when a client was first used, for `remotesMissing`
	@field isRemotesReported whether `remotesMissing` was reported
	@field dispatchTick     on a client, the tick of the frame being dispatched
	@field decodeReportedAt when `decoderRaised` was last reported natively
	@field validatorThread  the thread validators run in, and whether a validator is running in it
	@field answer           queues an answer (`Outbox.answer`)
	@field control          queues a control message (`Outbox.control`)
	@field slotByName       the counters this runtime adds to, by name
	@field disconnects      what `close` disconnects
]=]
export type Runtime = {
	side: "server" | "client",
	host: Host.Host,
	config: Config,
	pinnedKey: buffer?,
	facts: Facts.State,
	counters: Counters.State,
	console: Console.State,
	namespaces: { [string]: Namespace },
	namespaceByIndex: { [number]: Namespace },
	permutationSeed: number,
	epoch: number,
	stateRate: number,
	isRateChanged: boolean,
	lastTick: number,
	connections: { [Player]: Connection },
	connection: Connection,
	knownPlayers: { [any]: true },
	pending: { Message },
	mode: Mode,
	isFlushing: boolean,
	accumulated: number,
	pendingSteps: number,
	isMissedReported: boolean,
	firstUseAt: number,
	isRemotesReported: boolean,
	dispatchTick: number?,
	decodeReportedAt: number,
	validatorThread: thread?,
	validatorState: { isRunning: boolean },
	answer: (
		rt: Runtime,
		definition: Definition,
		player: Player?,
		slot: number,
		epoch: number,
		outcome: number,
		value: any
	) -> (),
	control: (rt: Runtime, player: Player?, kind: number, row: any) -> (),
	slotByName: { [string]: number },
	disconnects: { () -> () },
}

-- Constants ---------------------------------------------------------------------------------------

const EMPTY_PAYLOAD: Payload = table.freeze({
	bits = buffer.create(0),
	bitLength = 0,
	tail = buffer.create(0),
	instances = table.freeze({}),
	bytes = 0,
})

-- Public ------------------------------------------------------------------------------------------

--- `Lync.all`: every player.
State.ALL = table.freeze({ kind = "all" })

--- The payload of a message that carries none.
State.EMPTY_PAYLOAD = EMPTY_PAYLOAD

--- The protocol version `HELLO` carries (v5.md §4.6).
State.VERSION = 1

--- The build seed of the runtime path (v5.md §3.2).
State.BUILD_SEED = 0

--- The join hold, per player on a server and per connection on a client (v5.md §5.3).
State.MAX_HOLD_BYTES = 32_768

--- How long a `HELLO` for a namespace not loaded yet waits, and a client waits for remotes.
State.WAIT_SECONDS = 10

--- Request slots per direction per connection (v5.md §5.2).
State.SLOT_COUNT = 16

--- The `limit` slack, in seconds of `perSecond` (v5.md §5.4).
State.LIMIT_SLACK = 2

--- A client's decode element allowance per frame (v5.md §4.8, §4.9).
State.CLIENT_ALLOWANCE = 4_194_304

--- Reliable and unreliable chunk sizes (v5.md §4.1, §4.9).
State.MAX_RELIABLE_CHUNK = 16_256
State.MAX_UNRELIABLE_CHUNK = 960

--- The remotes, as `Host.Lane`.
State.RELIABLE = 0
State.UNRELIABLE = 1

--- Answer outcomes (v5.md §5.2).
State.OUTCOME_VALUE = 0
State.OUTCOME_REJECTED = 1
State.OUTCOME_UNANSWERED = 2

--[=[
	Adds to one of the runtime's counters, naming it on first use.

	@param rt     the runtime
	@param name   the counter, such as `lateAnswers`
	@param player the player it concerns, if any
	@param n      the amount
]=]
function State.count(rt: Runtime, name: string, player: Player?, n: number)
	local slot = rt.slotByName[name]
	if slot == nil then
		slot = Counters.slot(rt.counters, name)
		rt.slotByName[name] = slot
	end

	Counters.add(rt.counters, slot, player, n)
end

--[=[
	Records a fact about a definition, or about none.

	@param rt         the runtime
	@param reason     the fact's code
	@param player     the sender, or the player concerned; nil for a client's own
	@param definition the definition it concerns, if any
	@param e1         the evidence, in the registry's order
]=]
function State.fact(
	rt: Runtime,
	reason: any,
	player: Player?,
	definition: Definition?,
	e1: number?,
	e2: number?,
	e3: number?,
	e4: number?,
	e5: number?
)
	if definition == nil then
		Facts.record(rt.facts, reason, player, nil, nil, e1, e2, e3, e4, e5)
		return
	end

	local namespace = definition.namespace.ir.name
	Facts.record(rt.facts, reason, player, namespace, definition.ir.name, e1, e2, e3, e4, e5)
end

return table.freeze(State)
