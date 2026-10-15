--!strict

--[=[
	Network

	The in-process transport of the simulated engine: the three lanes between one server and any
	number of clients, in which every frame has a fate.

	A fate is the list of delays, in seconds after the send, at which copies of the frame arrive.
	`{}` loses the frame, `{0}` delivers it at once, `{0, 0.05}` delivers it twice and `{0.2}`
	delays it, and a frame given a smaller delay than an earlier one overtakes it. The unreliable
	lane obeys its fates. The reliable and handshake lanes take only the delays: they deliver every
	frame once and in the order it was sent, and a delayed frame holds back the frames after it.

	A plan chooses the fate of each frame from the lane, the direction and the number of the frame
	among those sent that way, so one plan and one timeline give one delivery trace.

	Delivery runs on the virtual time of a Timeline, so nothing arrives until a test advances it.

	The records that Lync takes as its `transport` seam come from `server` and `client`. They are
	records of plain functions and signals, called as `transport.reliable.send(recipient, frame)`.
]=]


-- Imports -----------------------------------------------------------------------------------------

local Signal   = require("./Signal")
local Timeline = require("./Timeline")


-- Module ------------------------------------------------------------------------------------------

local Network   = {}
Network.__index = Network


-- Types -------------------------------------------------------------------------------------------

type Pending = {
	read ordinal:       number,
	read frame:         buffer,
	read instances:     { Instance },
	read instanceCount: number,
	read connection:    unknown,

	isReady:            boolean,
}


type Stream = {
	read pending:   { [number]: Pending },

	highestOrdinal: number,
	sentCount:      number,
	deliveredCount: number,
}


--- The name of a lane, which is also its field on a transport.
export type LaneName =
	| "reliable"
	| "unreliable"
	| "handshake"


--- Which way a frame travels.
export type Direction =
	| "ToClient"
	| "ToServer"


--- The delays, in seconds after the send, at which copies of a frame arrive.
export type Fate = { read number }


--- Chooses the fate of a frame from its lane, its direction and its number among those sent so.
export type Plan = (lane: LaneName, direction: Direction, ordinal: number) -> Fate


--[=[
	The fates of an explicit plan, listed by lane, and under it by direction, in the order the
	frames are sent.

	A frame past the end of its list, and a frame whose lane or direction has no list, has the
	perfect fate `{0}`.
]=]
export type Schedule = { read [LaneName]: Fates? }


--- The fates of one lane, by direction: the frames to clients and the frames from clients.
export type Fates = { read [Direction]: { read Fate }? }


--[=[
	What a lane has done in one direction.

	The record `tally` returns is a copy.

	@field callCount       how many frames were sent
	@field payloadBytes    how many bytes those frames held, including frames that never arrived
	@field lostCount       how many frames the unreliable lane lost to a fate of `{}`
	@field duplicatedCount how many extra copies the unreliable lane made
	@field reorderedCount  how many copies arrived after a frame sent later had arrived
	@field delayedCount    how many frames had a first delay above 0
	@field oversizeCount   how many unreliable frames were dropped for passing the size limit
	@field unroutedCount   how many frames had no connected player to go to or to come from
]=]
export type Tally = {
	callCount:       number,
	payloadBytes:    number,
	lostCount:       number,
	duplicatedCount: number,
	reorderedCount:  number,
	delayedCount:    number,
	oversizeCount:   number,
	unroutedCount:   number,
}


--[=[
	One copy of a frame, delivered.

	@field at        the virtual time of the delivery
	@field lane      the lane the frame travelled on
	@field direction which way it travelled
	@field ordinal   the number of the frame among those sent on that lane in that direction
	@field byteCount how many bytes the frame held
]=]
export type Delivery = {
	read at:        number,
	read lane:      LaneName,
	read direction: Direction,
	read ordinal:   number,
	read byteCount: number,
}


--[=[
	A lane of frames that can carry instances, as the transport seam of Lync has it.

	@field send     sends a frame and its instances to `recipient`, a player on a server, else nil
	@field received fires `(sender, frame, ...)` per copy, `sender` being a player on a server
]=]
export type FrameLane<TPlayer> = {
	read send:     (recipient: TPlayer?, frame: buffer, ...Instance) -> (),
	read received: Signal.Signal<TPlayer?, buffer, ...Instance>,
}


--[=[
	The handshake lane, which carries no instances.

	@field send     sends a frame to `recipient`, a player on a server and nil on a client
	@field received fires `(sender, frame)` for each copy that arrives
]=]
export type HandshakeLane<TPlayer> = {
	read send:     (recipient: TPlayer?, frame: buffer) -> (),
	read received: Signal.Signal<TPlayer?, buffer>,
}


--[=[
	The record that Lync takes as its `transport` seam, for the server or for one client.

	@field reliable   the lane of frames that arrive once and in order
	@field unreliable the lane of frames that may be lost, repeated or reordered
	@field handshake  the lane of the handshake
]=]
export type Transport<TPlayer> = {
	read reliable:   FrameLane<TPlayer>,
	read unreliable: FrameLane<TPlayer>,
	read handshake:  HandshakeLane<TPlayer>,
}


type LaneState = {
	read lane:         LaneName,
	read direction:    Direction,
	read counts:       Tally,
	read streamByPeer: { [unknown]: Stream },

	ordinal:           number,
}


type Fields<TPlayer> = {
	read _timeline:       Timeline.Timeline,
	read _plan:           Plan,
	read _statesByLane:   { [LaneName]: { [Direction]: LaneState } },
	read _clientByPlayer: { [TPlayer]: Transport<TPlayer> },
	read _trace:          { Delivery },

	_server:              Transport<TPlayer>?,
}


--- The lanes between a server and its clients.
export type Network<TPlayer> = setmetatable<Fields<TPlayer>, typeof(Network)>


type Limit = {
	read frameBytes:    number,
	read instanceBytes: number,
}


-- Constants ---------------------------------------------------------------------------------------

--- The lanes, in the order a network lists them.
const LANE_NAMES: { read LaneName } = {
	"reliable",
	"unreliable",
	"handshake",
}
table.freeze(LANE_NAMES)


--- The directions, in the order a network lists them.
const DIRECTIONS: { read Direction } = { "ToClient", "ToServer" }
table.freeze(DIRECTIONS)


--- What the engine lets an unreliable call carry: 985 bytes less 6 for each instance argument.
const UNRELIABLE_LIMIT: Limit = {
	frameBytes    = 985,
	instanceBytes = 6,
}


--- The fate of a frame that suffers no fault.
const PERFECT_FATE: Fate = { 0 }
table.freeze(PERFECT_FATE)


--- What a send raises when a server gives no recipient.
const SERVER_RECIPIENT_MESSAGE = "recipient must be a player on a server, got nil"


--- What a send raises when a client gives a recipient.
const CLIENT_RECIPIENT_MESSAGE = "recipient must be nil on a client, got a player"


-- Private -----------------------------------------------------------------------------------------

local function problemWithFate(fate: Fate, subject: string): string?
	for i, delay in fate do
		if not Timeline.isDuration(delay) then
			return `{subject} must hold delays of 0 seconds or more, got {delay} at delay {i}`
		end
	end

	return nil
end


local function earliestDelay(fate: Fate): number
	if #fate == 0 then
		return 0
	end

	local earliest = math.huge
	for _, delay in fate do
		earliest = math.min(earliest, delay)
	end

	return earliest
end


local function isOversize(lane: LaneName, frameBytes: number, instanceCount: number): boolean
	if lane ~= "unreliable" then
		return false
	end

	local instancesBytes = UNRELIABLE_LIMIT.instanceBytes * instanceCount
	local limitBytes     = UNRELIABLE_LIMIT.frameBytes - instancesBytes

	return frameBytes > limitBytes
end


local function newLaneState(lane: LaneName, direction: Direction): LaneState
	return {
		lane         = lane,
		direction    = direction,
		streamByPeer = {},

		counts       = {
			callCount       = 0,
			payloadBytes    = 0,
			lostCount       = 0,
			duplicatedCount = 0,
			reorderedCount  = 0,
			delayedCount    = 0,
			oversizeCount   = 0,
			unroutedCount   = 0,
		},

		ordinal      = 0,
	}
end


local function stateOf<TPlayer>(
	self:      Network<TPlayer>,
	lane:      LaneName,
	direction: Direction
): LaneState
	return self._statesByLane[lane][direction]
end


local function streamOf(state: LaneState, peer: unknown): Stream
	local existing = state.streamByPeer[peer]
	if existing ~= nil then
		return existing
	end

	local created: Stream = {
		pending        = {},
		highestOrdinal = 0,
		sentCount      = 0,
		deliveredCount = 0,
	}

	state.streamByPeer[peer] = created

	return created
end


-- A player's connection is the transport its client was given, so a player who leaves and joins
-- again is not the one that frames already on the way were sent to or from.
local function connectionOf<TPlayer>(
	self:    Network<TPlayer>,
	peer:    TPlayer,
	pending: Pending
): Transport<TPlayer>?
	local client = self._clientByPlayer[peer]
	if client ~= pending.connection then
		return nil
	end

	return client
end


local function serverOf<TPlayer>(self: Network<TPlayer>): Transport<TPlayer>
	return assert(self._server, "a network must hold its server")
end


local function fireFrameLane<TPlayer>(
	lane:    FrameLane<TPlayer>,
	sender:  TPlayer?,
	frame:   buffer,
	pending: Pending
): ()
	-- The checker cannot match arguments that end in a variadic tail to a signal's generic pack.
	local received = lane.received :: any
	received:fire(sender, frame, table.unpack(pending.instances, 1, pending.instanceCount))
end


local function fireReceived<TPlayer>(
	receiver: Transport<TPlayer>,
	lane:     LaneName,
	sender:   TPlayer?,
	frame:    buffer,
	pending:  Pending
): ()
	if lane == "reliable" then
		fireFrameLane(receiver.reliable, sender, frame, pending)
	elseif lane == "unreliable" then
		fireFrameLane(receiver.unreliable, sender, frame, pending)
	elseif lane == "handshake" then
		receiver.handshake.received:fire(sender, frame)
	else
		local _: never = lane
	end
end


local function deliverNow<TPlayer>(
	self:    Network<TPlayer>,
	state:   LaneState,
	peer:    TPlayer,
	pending: Pending
): ()
	local counts = state.counts
	local client = connectionOf(self, peer, pending)
	if client == nil then
		counts.unroutedCount += 1
		return
	end

	local stream = streamOf(state, peer)
	if pending.ordinal >= stream.highestOrdinal then
		stream.highestOrdinal = pending.ordinal
	else
		counts.reorderedCount += 1
	end

	local byteCount = buffer.len(pending.frame)
	local delivery  = table.freeze({
		at        = self._timeline:now(),
		lane      = state.lane,
		direction = state.direction,
		ordinal   = pending.ordinal,
		byteCount = byteCount,
	})

	table.insert(self._trace, delivery)

	local copy = buffer.create(byteCount)
	buffer.copy(copy, 0, pending.frame)

	if state.direction == "ToClient" then
		fireReceived(client, state.lane, nil, copy, pending)
	elseif state.direction == "ToServer" then
		fireReceived(serverOf(self), state.lane, peer, copy, pending)
	else
		local _: never = state.direction
	end
end


--[=[
	Marks a frame on an ordered lane as due, and delivers it, and the due frames after it, once
	every frame sent before it has been delivered.

	@param state   the lane and direction the frame travels in
	@param peer    the player at the other end of the connection
	@param stream  the frames of this connection in this lane, in the order they were sent
	@param pending the frame that has come due
]=]
local function markReady<TPlayer>(
	self:    Network<TPlayer>,
	state:   LaneState,
	peer:    TPlayer,
	stream:  Stream,
	pending: Pending
): ()
	pending.isReady = true

	while true do
		local head = stream.pending[stream.deliveredCount + 1]
		if head == nil then
			break
		end

		if not head.isReady then
			break
		end

		stream.pending[stream.deliveredCount + 1] = nil
		stream.deliveredCount                    += 1
		deliverNow(self, state, peer, head)
	end
end


local function scheduleCopies<TPlayer>(
	self:    Network<TPlayer>,
	state:   LaneState,
	peer:    TPlayer,
	pending: Pending,
	fate:    Fate
): ()
	local counts    = state.counts
	local copyCount = #fate
	if copyCount == 0 then
		counts.lostCount += 1
	end

	if copyCount > 1 then
		counts.duplicatedCount += copyCount - 1
	end

	if earliestDelay(fate) > 0 then
		counts.delayedCount += 1
	end

	for _, delay in fate do
		self._timeline:delay(delay, deliverNow, self, state, peer, pending)
	end
end


local function scheduleOrdered<TPlayer>(
	self:    Network<TPlayer>,
	state:   LaneState,
	peer:    TPlayer,
	pending: Pending,
	fate:    Fate
): ()
	local stream = streamOf(state, peer)

	stream.sentCount                += 1
	stream.pending[stream.sentCount] = pending

	local earliest = earliestDelay(fate)
	if earliest > 0 then
		state.counts.delayedCount += 1
	end

	self._timeline:delay(earliest, markReady, self, state, peer, stream, pending)
end


local function sendFrame<TPlayer>(
	self:  Network<TPlayer>,
	state: LaneState,
	peer:  TPlayer,
	frame: buffer,
	...:   Instance
): ()
	state.ordinal += 1

	local ordinal    = state.ordinal
	local counts     = state.counts
	local frameBytes = buffer.len(frame)

	counts.callCount    += 1
	counts.payloadBytes += frameBytes

	local connection = self._clientByPlayer[peer]
	if connection == nil then
		counts.unroutedCount += 1
		return
	end

	local instanceCount = select("#", ...)
	if isOversize(state.lane, frameBytes, instanceCount) then
		counts.oversizeCount += 1
		return
	end

	local fate    = self._plan(state.lane, state.direction, ordinal)
	local problem = problemWithFate(fate, "the fate that the plan gave")
	if problem ~= nil then
		error(problem)
	end

	local snapshot = buffer.create(frameBytes)
	buffer.copy(snapshot, 0, frame)

	local pending: Pending = {
		ordinal       = ordinal,
		frame         = snapshot,
		instances     = { ... },
		instanceCount = instanceCount,
		connection    = connection,
		isReady       = false,
	}

	if state.lane == "unreliable" then
		scheduleCopies(self, state, peer, pending, fate)
	elseif state.lane == "reliable" or state.lane == "handshake" then
		scheduleOrdered(self, state, peer, pending, fate)
	else
		local _: never = state.lane
	end
end


local function serverFrameLane<TPlayer>(self: Network<TPlayer>, lane: LaneName): FrameLane<TPlayer>
	local state = stateOf(self, lane, "ToClient")

	return {
		send     = function(recipient: TPlayer?, frame: buffer, ...: Instance): ()
			if recipient == nil then
				error(SERVER_RECIPIENT_MESSAGE, 2)
			end

			sendFrame(self, state, recipient, frame, ...)
		end,
		received = Signal.new(),
	}
end


local function serverHandshakeLane<TPlayer>(self: Network<TPlayer>): HandshakeLane<TPlayer>
	local state = stateOf(self, "handshake", "ToClient")

	return {
		send     = function(recipient: TPlayer?, frame: buffer): ()
			if recipient == nil then
				error(SERVER_RECIPIENT_MESSAGE, 2)
			end

			sendFrame(self, state, recipient, frame)
		end,
		received = Signal.new(),
	}
end


local function clientFrameLane<TPlayer>(
	self:   Network<TPlayer>,
	lane:   LaneName,
	player: TPlayer
): FrameLane<TPlayer>
	local state = stateOf(self, lane, "ToServer")

	return {
		send     = function(recipient: TPlayer?, frame: buffer, ...: Instance): ()
			if recipient ~= nil then
				error(CLIENT_RECIPIENT_MESSAGE, 2)
			end

			sendFrame(self, state, player, frame, ...)
		end,
		received = Signal.new(),
	}
end


local function clientHandshakeLane<TPlayer>(
	self:   Network<TPlayer>,
	player: TPlayer
): HandshakeLane<TPlayer>
	local state = stateOf(self, "handshake", "ToServer")

	return {
		send     = function(recipient: TPlayer?, frame: buffer): ()
			if recipient ~= nil then
				error(CLIENT_RECIPIENT_MESSAGE, 2)
			end

			sendFrame(self, state, player, frame)
		end,
		received = Signal.new(),
	}
end


-- Public ------------------------------------------------------------------------------------------

--[=[
	Creates a network with a server and no clients.

	@param  timeline the virtual time that delivery runs on
	@param  plan     chooses the fate of each frame
	@return a network that has carried nothing
]=]
function Network.new<TPlayer>(timeline: Timeline.Timeline, plan: Plan): Network<TPlayer>
	local statesByLane: { [LaneName]: { [Direction]: LaneState } } = {}
	for _, lane in LANE_NAMES do
		local stateByDirection: { [Direction]: LaneState } = {}
		for _, direction in DIRECTIONS do
			stateByDirection[direction] = newLaneState(lane, direction)
		end

		statesByLane[lane] = stateByDirection
	end

	local self: Network<TPlayer> = setmetatable({
		_timeline       = timeline,
		_plan           = plan,
		_statesByLane   = statesByLane,
		_clientByPlayer = {},
		_trace          = {},

		_server         = nil,
	}, Network)

	self._server = {
		reliable   = serverFrameLane(self, "reliable"),
		unreliable = serverFrameLane(self, "unreliable"),
		handshake  = serverHandshakeLane(self),
	}

	return self
end


--[=[
	Connects a client, or returns the one already connected for the player.

	@param  player the player the client belongs to, who the server sees as the sender of its frames
	@return the transport for that client, the same record on every call while it stays connected
]=]
function Network.client<TPlayer>(self: Network<TPlayer>, player: TPlayer): Transport<TPlayer>
	local existing = self._clientByPlayer[player]
	if existing ~= nil then
		return existing
	end

	local transport: Transport<TPlayer> = {
		reliable   = clientFrameLane(self, "reliable", player),
		unreliable = clientFrameLane(self, "unreliable", player),
		handshake  = clientHandshakeLane(self, player),
	}

	self._clientByPlayer[player] = transport

	return transport
end


--[=[
	Disconnects a client.

	Frames still on the way to the player or from the player are lost, and counted as unrouted when
	they would have arrived. A player who is connected again afterwards has a new connection.

	@param player the player whose client is disconnected; one that is not connected is left alone
]=]
function Network.detach<TPlayer>(self: Network<TPlayer>, player: TPlayer): ()
	self._clientByPlayer[player] = nil

	for _, lane in LANE_NAMES do
		for _, direction in DIRECTIONS do
			stateOf(self, lane, direction).streamByPeer[player] = nil
		end
	end
end


--[=[
	Returns the plan in which every frame has the perfect fate, `{0}`.

	It is a plan itself: pass `Network.perfectPlan` where a plan is wanted.

	@param  lane      the lane of the frame
	@param  direction which way the frame travels
	@param  ordinal   the number of the frame among those sent so
	@return `{0}`, whatever the frame
]=]
function Network.perfectPlan(lane: LaneName, direction: Direction, ordinal: number): Fate
	return PERFECT_FATE
end


--[=[
	Builds a plan from fates written out by lane and direction.

	@param  schedule the fates, in the order the frames are sent; it must not be changed afterwards
	@return a plan that gives each frame the fate listed for it, and the perfect fate past the list
	@error  when a fate holds a delay that is not a finite number of 0 or more
]=]
function Network.planOf(schedule: Schedule): Plan
	for _, lane in LANE_NAMES do
		local fatesByDirection = schedule[lane]
		if fatesByDirection == nil then
			continue
		end

		for _, direction in DIRECTIONS do
			local fates = fatesByDirection[direction]
			if fates == nil then
				continue
			end

			for ordinal, fate in fates do
				local subject = `schedule.{lane}.{direction}[{ordinal}]`
				local problem = problemWithFate(fate, subject)
				if problem ~= nil then
					error(problem, 2)
				end
			end
		end
	end

	return function(lane: LaneName, direction: Direction, ordinal: number): Fate
		local fatesByDirection = schedule[lane]
		if fatesByDirection == nil then
			return PERFECT_FATE
		end

		local fates = fatesByDirection[direction]
		if fates == nil then
			return PERFECT_FATE
		end

		return fates[ordinal] or PERFECT_FATE
	end
end


--[=[
	Returns the transport of the server.

	@return the transport for the server, the same record on every call
]=]
function Network.server<TPlayer>(self: Network<TPlayer>): Transport<TPlayer>
	return serverOf(self)
end


--[=[
	Returns what a lane has done in one direction.

	@param  lane      the lane to report
	@param  direction which way the frames travelled
	@return a copy of the tally as it stands
]=]
function Network.tally<TPlayer>(self: Network<TPlayer>, lane: LaneName, direction: Direction): Tally
	return table.clone(stateOf(self, lane, direction).counts)
end


--[=[
	Returns every delivery so far, in the order the copies arrived.

	@return a copy of the trace, whose records are frozen
]=]
function Network.trace<TPlayer>(self: Network<TPlayer>): { Delivery }
	return table.clone(self._trace)
end


return table.freeze(Network)
