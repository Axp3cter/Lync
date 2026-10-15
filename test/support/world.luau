--!strict

--[=[
	World

	One process holding a server and many clients (m2-plan.md §2, §6): each side gets a `Host`
	over one virtual clock, a fake roster and transports joined by the network model of
	`net.luau`.

	`world:step(dt)` advances the clock to each due step in time order: at each, it delivers
	every frame that has arrived, then runs that side's `onStep` callbacks. The server steps at
	`serverFps`, each client at its link's `fps`. Frames are copied when sent, as the engine
	serializes them, and a frame reaches a side only once it has opened its transport and set
	its handler.

	Runtimes are built through an `Endpoint`: `Runtime.new`'s signature and `Runtime.observe`.
	The world observes every runtime's facts, and records every native report (an error in a
	`spawn`ed function, or `report`) and every console line. A test claims what it expects, and
	`expectQuiet` fails on anything unclaimed (v5.md §9).

	Players are frozen tables with `UserId`, `Name` and a `Kick` that records the call in
	`world.kicks`, cast to `Player`. Every remote call is recorded in `world.calls`; a
	`FireAllClients` is one call.
]=]

-- Imports -----------------------------------------------------------------------------------------

local Check = require("./check")
local Facts = require("../../src/diag/facts")
local Host = require("../../src/host/host")
local Net = require("./net")

-- Module ------------------------------------------------------------------------------------------

local World = {}
World.__index = World

-- Types -------------------------------------------------------------------------------------------

--- What builds runtimes: `Runtime.new` and `Runtime.observe`, or a stub with their signatures.
export type Endpoint = {
	new: (side: "server" | "client", host: Host.Host, options: any?) -> any,
	observe: (runtime: any, notify: (fact: Facts.Fact) -> ()) -> Host.Connection,
}

--- A console line a host printed.
export type Line = { template: string, context: { [string]: any } }

type Arguments = { n: number, [number]: any }

--- One side: its host, its runtime, and the output nobody has claimed yet.
export type Peer = {
	side: "server" | "client",
	host: Host.Host,
	runtime: any,
	player: Player?,
	fps: number,
	facts: { Facts.Fact },
	reports: { string },
	lines: { Line },
	hasLeft: boolean,
	up: Net.Link?,
	down: Net.Link?,
	isOpen: boolean,
	handler: ((player: Player?, lane: Host.Lane, ...any) -> ())?,
	steps: { (dt: number) -> () },
	closes: { () -> () },
	added: { (player: Player) -> () },
	removing: { (player: Player) -> () },
	startedAt: number,
	stepCount: number,
}

--- A remote call: `send` (`FireClient`/`FireServer`), `broadcast` (`FireAllClients`) or `raw`.
export type Call = {
	at: number,
	from: Peer,
	to: Peer?,
	kind: "send" | "broadcast" | "raw",
	lane: Host.Lane,
	bytes: number,
}

--- A kick, which Lync never makes.
export type Kick = { player: Player, message: string? }

type Delivery = {
	at: number,
	order: number,
	from: Peer,
	to: Peer,
	lane: Host.Lane,
	arguments: Arguments,
}

type Fields = {
	now: number,
	server: Peer,
	clients: { Peer },
	calls: { Call },
	kicks: { Kick },
	_seed: number,
	_params: Net.Params,
	_endpoint: Endpoint?,
	_peers: { Peer },
	_roster: { Player },
	_peerByPlayer: { [Player]: Peer },
	_queue: { Delivery },
	_deliveryCount: number,
	_nextUserId: number,
}

export type World = setmetatable<Fields, typeof(World)>

--- World options: `seed`, the world's network settings `net` (over the honest model), the
--- server's step rate and the server runtime's `pin`.
export type Options = {
	seed: number,
	endpoint: Endpoint?,
	net: { [string]: any }?,
	serverFps: number?,
	pin: any?,
}

--- Join options: the client's network settings `net` (over the world's), its name and `pin`.
export type JoinOptions = {
	net: { [string]: any }?,
	name: string?,
	pin: any?,
}

-- Constants ---------------------------------------------------------------------------------------

const SERVER_TIME_ORIGIN = 1000
const SERVER_FPS = 60
const FIRST_USER_ID = 1001
const TIME_EPSILON = 1e-9

-- Private -----------------------------------------------------------------------------------------

local function isBefore(a: Delivery, b: Delivery): boolean
	return a.at < b.at or (a.at == b.at and a.order < b.order)
end

local function push(queue: { Delivery }, delivery: Delivery)
	table.insert(queue, delivery)
	local i = #queue
	while i > 1 do
		local parent = i // 2
		if not isBefore(queue[i], queue[parent]) then
			return
		end

		queue[i], queue[parent] = queue[parent], queue[i]
		i = parent
	end
end

local function pop(queue: { Delivery }): Delivery
	local top = queue[1]
	queue[1] = queue[#queue]
	queue[#queue] = nil

	local count = #queue
	local i = 1
	while true do
		local smallest = i
		local left = 2 * i
		local right = left + 1
		if left <= count and isBefore(queue[left], queue[smallest]) then
			smallest = left
		end
		if right <= count and isBefore(queue[right], queue[smallest]) then
			smallest = right
		end
		if smallest == i then
			return top
		end

		queue[i], queue[smallest] = queue[smallest], queue[i]
		i = smallest
	end
end

local function copyOf(value: any): any
	if typeof(value) == "buffer" then
		local copy = buffer.create(buffer.len(value))
		buffer.copy(copy, 0, value)
		return copy
	end

	if typeof(value) == "table" then
		return table.clone(value)
	end

	return value
end

local function packCopies(...: any): Arguments
	local arguments = table.pack(...)
	for i = 1, arguments.n do
		arguments[i] = copyOf(arguments[i])
	end

	return arguments
end

local function bytesOf(arguments: Arguments): number
	local bytes = 0
	for i = 1, arguments.n do
		local value = arguments[i]
		if typeof(value) == "buffer" then
			bytes += buffer.len(value)
		elseif typeof(value) == "string" then
			bytes += #value
		end
	end

	return bytes
end

local function isReady(self: World, peer: Peer): boolean
	return peer.isOpen and self.server.isOpen
end

local function record(self: World, from: Peer, to: Peer?, kind: "send" | "broadcast" | "raw", lane: Host.Lane, bytes: number)
	table.insert(self.calls, {
		at = self.now,
		from = from,
		to = to,
		kind = kind,
		lane = lane,
		bytes = bytes,
	})
end

local function enqueue(self: World, at: number, from: Peer, to: Peer, lane: Host.Lane, arguments: Arguments)
	self._deliveryCount += 1
	push(self._queue, {
		at = at,
		order = self._deliveryCount,
		from = from,
		to = to,
		lane = lane,
		arguments = arguments,
	})
end

local function schedule(self: World, from: Peer, to: Peer, link: Net.Link, lane: Host.Lane, arguments: Arguments)
	local first, second = Net.schedule(link, self.now, lane, bytesOf(arguments))
	if first ~= nil then
		enqueue(self, first, from, to, lane, arguments)
	end
	if second ~= nil then
		enqueue(self, second, from, to, lane, arguments)
	end
end

local function deliverDue(self: World)
	local queue = self._queue
	while #queue > 0 and queue[1].at <= self.now + TIME_EPSILON do
		local delivery = pop(queue)
		local to = delivery.to
		local handler = to.handler
		if delivery.from.hasLeft or to.hasLeft or handler == nil or not isReady(self, to) then
			continue
		end

		local player = if to.side == "server" then delivery.from.player else nil
		local arguments = delivery.arguments
		handler(player, delivery.lane, table.unpack(arguments, 1, arguments.n))
	end
end

local function remover<T>(list: { T }, item: T): () -> ()
	return function()
		local index = table.find(list, item)
		if index ~= nil then
			table.remove(list, index)
		end
	end
end

local function transportOf(self: World, peer: Peer): Host.Transport
	local function open()
		peer.isOpen = true
	end

	local function ready(): boolean
		return isReady(self, peer)
	end

	local function send(player: Player?, lane: Host.Lane, frame: buffer, instances: { Instance? }?)
		local arguments = packCopies(frame, instances)
		if peer.side == "client" then
			assert(isReady(self, peer), "a client must not send before its transport is ready")
			record(self, peer, self.server, "send", lane, bytesOf(arguments))
			schedule(self, peer, self.server, peer.up :: Net.Link, lane, arguments)
			return
		end

		local to = self._peerByPlayer[player :: Player]
		record(self, peer, to, "send", lane, bytesOf(arguments))
		if to ~= nil and not to.hasLeft then
			schedule(self, peer, to, to.down :: Net.Link, lane, arguments)
		end
	end

	local function broadcast(lane: Host.Lane, frame: buffer, instances: { Instance? }?)
		assert(peer.side == "server", "only the server broadcasts")
		local arguments = packCopies(frame, instances)
		record(self, peer, nil, "broadcast", lane, bytesOf(arguments))
		for _, client in self.clients do
			schedule(self, peer, client, client.down :: Net.Link, lane, arguments)
		end
	end

	local function onReceive(handler: (player: Player?, lane: Host.Lane, ...unknown) -> ())
		peer.handler = handler
	end

	return {
		open = open,
		ready = ready,
		send = send,
		broadcast = broadcast,
		onReceive = onReceive,
	}
end

local function hostOf(self: World, peer: Peer, seed: number): Host.Host
	local random = Net.random(seed)

	local function now(): number
		return SERVER_TIME_ORIGIN + self.now
	end

	local function clock(): number
		return self.now
	end

	local function spawn(f: (...any) -> (), ...: any): thread
		local thread = coroutine.create(function(...: any)
			local ok, message = pcall(f, ...)
			if not ok then
				table.insert(peer.reports, tostring(message))
			end
		end)
		coroutine.resume(thread, ...)

		return thread
	end

	local function report(message: string)
		table.insert(peer.reports, message)
	end

	local function warn(template: string, context: { [string]: any })
		table.insert(peer.lines, { template = template, context = context })
	end

	local function onStep(f: (dt: number) -> ()): () -> ()
		table.insert(peer.steps, f)
		return remover(peer.steps, f)
	end

	local function onClose(f: () -> ())
		table.insert(peer.closes, f)
	end

	local function players(): { Player }
		return table.clone(self._roster)
	end

	local function onPlayerAdded(f: (player: Player) -> ()): () -> ()
		table.insert(peer.added, f)
		return remover(peer.added, f)
	end

	local function onPlayerRemoving(f: (player: Player) -> ()): () -> ()
		table.insert(peer.removing, f)
		return remover(peer.removing, f)
	end

	return {
		side = peer.side,
		now = now,
		clock = clock,
		entropy32 = random,
		spawn = spawn,
		report = report,
		warn = warn,
		onStep = onStep,
		onClose = onClose,
		players = players,
		onPlayerAdded = onPlayerAdded,
		onPlayerRemoving = onPlayerRemoving,
		localPlayer = peer.player,
		transport = transportOf(self, peer),
	}
end

local function newPeer(self: World, side: "server" | "client", player: Player?, fps: number): Peer
	local peer: Peer = {
		side = side,
		host = nil :: any,
		runtime = nil,
		player = player,
		fps = fps,
		facts = {},
		reports = {},
		lines = {},
		hasLeft = false,
		up = nil,
		down = nil,
		isOpen = false,
		handler = nil,
		steps = {},
		closes = {},
		added = {},
		removing = {},
		startedAt = self.now,
		stepCount = 0,
	}
	local index = #self._peers + 1
	peer.host = hostOf(self, peer, self._seed * 7919 + index * 3)
	table.insert(self._peers, peer)

	return peer
end

local function startRuntime(self: World, peer: Peer, pin: any?)
	local endpoint = self._endpoint
	if endpoint == nil then
		return
	end

	local options = if pin == nil then nil else { pin = pin }
	peer.runtime = endpoint.new(peer.side, peer.host, options)
	endpoint.observe(peer.runtime, function(fact: Facts.Fact)
		table.insert(peer.facts, fact)
	end)
end

local function playerOf(self: World, userId: number, name: string): Player
	local player = {
		UserId = userId,
		Name = name,
	} :: any
	function player.Kick(_player: any, message: string?)
		table.insert(self.kicks, { player = player, message = message })
	end
	table.freeze(player)

	return player :: Player
end

-- The peer whose next step comes first, server first on a tie, and when it comes.
local function nextStepper(self: World): (Peer?, number)
	local nextPeer: Peer? = nil
	local nextAt = math.huge
	for _, peer in self._peers do
		if peer.hasLeft then
			continue
		end

		local at = peer.startedAt + (peer.stepCount + 1) / peer.fps
		if at < nextAt - TIME_EPSILON then
			nextPeer = peer
			nextAt = at
		end
	end

	return nextPeer, nextAt
end

local function describe(peer: Peer): string
	local parts = {}
	for _, fact in peer.facts do
		table.insert(parts, `fact {fact.reason}`)
	end
	for _, message in peer.reports do
		table.insert(parts, `report {message}`)
	end
	for _, line in peer.lines do
		table.insert(parts, `line {line.template}`)
	end

	local name = if peer.player == nil then "server" else peer.player.Name
	return `{name}: {table.concat(parts, "; ")}`
end

-- Public ------------------------------------------------------------------------------------------

--[=[
	Creates a world holding only the server, its runtime started when an endpoint is given.

	@param  options the seed, and optionally the endpoint, network settings, server step rate
	                and the server runtime's `pin`
	@return the world, at virtual time 0
]=]
function World.new(options: Options): World
	local self = setmetatable({
		now = 0,
		server = nil :: any,
		clients = {},
		calls = {},
		kicks = {},
		_seed = options.seed,
		_params = Net.params(Net.HONEST, options.net),
		_endpoint = options.endpoint,
		_peers = {},
		_roster = {},
		_peerByPlayer = {},
		_queue = {},
		_deliveryCount = 0,
		_nextUserId = FIRST_USER_ID,
	}, World)

	self.server = newPeer(self, "server", nil, options.serverFps or SERVER_FPS)
	startRuntime(self, self.server, options.pin)

	return self
end

--[=[
	Claims every console line of one code a side printed.

	@param  peer the side
	@param  code the line's code
	@return the claimed lines, in print order
]=]
function World.claimLines(self: World, peer: Peer, code: string): { Line }
	local prefix = `[Lync] {code}:`
	local claimed = {}
	local kept = {}
	for _, line in peer.lines do
		local isClaimed = string.sub(line.template, 1, #prefix) == prefix
		table.insert(if isClaimed then claimed else kept, line)
	end
	peer.lines = kept

	return claimed
end

--[=[
	Claims every native report of a side that contains `needle` as plain text.

	@param  peer   the side
	@param  needle `[Lync] <code>:` for Lync's own reports, or a test's own error text
	@return how many were claimed
]=]
function World.claimReports(self: World, peer: Peer, needle: string): number
	local kept = {}
	for _, message in peer.reports do
		if string.find(message, needle, 1, true) == nil then
			table.insert(kept, message)
		end
	end

	local claimedCount = #peer.reports - #kept
	peer.reports = kept

	return claimedCount
end

--[=[
	Runs the server's `onClose` callbacks, as `BindToClose` does.
]=]
function World.close(self: World)
	for _, f in table.clone(self.server.closes) do
		f()
	end
end

--[=[
	Claims a side's earliest unclaimed fact with `want.reason`, and checks it against `want`.

	@param  peer the side that observed it
	@param  want `reason`, and optionally `player` (nil: any), `count`, `definition` and the
	             whole `evidence`
	@return the fact
	@error  when no such fact was observed, or it differs from `want`
]=]
function World.expectFact(
	self: World,
	peer: Peer,
	want: { reason: string, player: Player?, count: number?, definition: string?, evidence: { [string]: number }? }
): Facts.Fact
	for i, fact in peer.facts do
		if fact.reason ~= want.reason or (want.player ~= nil and fact.player ~= want.player) then
			continue
		end

		table.remove(peer.facts, i)
		if want.count ~= nil then
			Check.expectEqual(fact.count, want.count, `{want.reason} count`)
		end
		if want.definition ~= nil then
			Check.expectEqual(fact.definition, want.definition, `{want.reason} definition`)
		end
		if want.evidence ~= nil then
			Check.expectEqual(fact.evidence, want.evidence, `{want.reason} evidence`)
		end

		return fact
	end

	error(`expected a {want.reason} fact; unclaimed: {describe(peer)}`, 2)
end

--[=[
	Fails if any side holds an unclaimed fact, native report or console line.

	@error naming everything unclaimed
]=]
function World.expectQuiet(self: World)
	local noisy = {}
	for _, peer in self._peers do
		if #peer.facts + #peer.reports + #peer.lines > 0 then
			table.insert(noisy, describe(peer))
		end
	end

	if #noisy > 0 then
		error(`expected no output, got {table.concat(noisy, " | ")}`, 2)
	end
end

--[=[
	Adds a client: a player in the roster, announced to the server's `onPlayerAdded`, with a
	link each way, and its runtime started when the world has an endpoint.

	@param  options its network settings over the world's, its name and its runtime's `pin`
	@return the client
]=]
function World.join(self: World, options: JoinOptions?): Peer
	local net = if options == nil then nil else options.net
	local params = Net.params(self._params, net)
	local userId = self._nextUserId
	self._nextUserId += 1

	local name = if options ~= nil and options.name ~= nil then options.name else `Player{userId}`
	local player = playerOf(self, userId, name)
	local client = newPeer(self, "client", player, params.fps)
	client.up = Net.link(params, self._seed * 104729 + userId * 2, self.now)
	client.down = Net.link(params, self._seed * 104729 + userId * 2 + 1, self.now)
	table.insert(self.clients, client)
	table.insert(self._roster, player)
	self._peerByPlayer[player] = client

	for _, f in table.clone(self.server.added) do
		f(player)
	end
	startRuntime(self, client, if options == nil then nil else options.pin)

	return client
end

--[=[
	Removes a client: announced to the server's `onPlayerRemoving` while still in the roster,
	then gone, with every frame in flight to or from it dropped.

	@param client the client
]=]
function World.leave(self: World, client: Peer)
	local player = client.player :: Player
	for _, f in table.clone(self.server.removing) do
		f(player)
	end

	client.hasLeft = true
	table.remove(self.clients, table.find(self.clients, client) :: number)
	table.remove(self._roster, table.find(self._roster, player) :: number)
end

--[=[
	Sends anything a modified client could pass to `FireServer`, on its link.

	@param client the sending client
	@param lane   the remote: 0 `Reliable`, 1 `Unreliable`
	@param ...    the call's arguments, copied as sent
]=]
function World.raw(self: World, client: Peer, lane: Host.Lane, ...: any)
	local arguments = packCopies(...)
	record(self, client, self.server, "raw", lane, bytesOf(arguments))
	schedule(self, client, self.server, client.up :: Net.Link, lane, arguments)
end

--[=[
	Advances virtual time by `dt`, delivering frames and running every side's steps due in it,
	in time order.

	@param dt seconds
]=]
function World.step(self: World, dt: number)
	local target = self.now + dt
	while true do
		local peer, at = nextStepper(self)
		if peer == nil or at > target + TIME_EPSILON then
			break
		end

		self.now = math.max(self.now, at)
		deliverDue(self)
		peer.stepCount += 1
		for _, f in table.clone(peer.steps) do
			f(1 / peer.fps)
		end
	end

	self.now = target
	deliverDue(self)
end

return table.freeze(World)
