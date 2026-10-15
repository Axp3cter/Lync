--!strict

--[=[
	Link

	The channel between the halves of a pair test: the server half and the client halves meet
	through `barrier`, `post` and `await`.

	A pair has one server half and one or more client halves. The server talks to every client and
	each client talks to the server only. A client does not hear another client.

	Every wait has a real timeout. A wait that runs out records why in the link and raises, so
	that the runner, which reads `timeoutReason`, can tell a test that waited in vain, `TimedOut`,
	from one that failed an assertion, `Failed`, without a thrown table.

	A message belongs to one test, named by its item, so a late message from an earlier test is
	ignored. A message that is not a link message is ignored too: a client chooses what it sends.

	A posted value crosses a remote, so it must be a value that a remote carries.

	Every wait yields. This module is itself a small scheduler, so it suspends a thread with
	`coroutine.yield` and resumes it with `task.spawn`.
]=]


-- Imports -----------------------------------------------------------------------------------------

local Types  = require("./Types")
local Values = require("./Values")


-- Module ------------------------------------------------------------------------------------------

local Link   = {}
Link.__index = Link


-- Types -------------------------------------------------------------------------------------------

--- Which half of a pair a link belongs to.
export type Role =
	| "Server"
	| "Client"


type Kind =
	| "Arrived"
	| "Posted"
	| "Released"


--[=[
	What one half says to the others.

	@field item  the id of the test the message belongs to
	@field kind  a post, an arrival at a barrier, or the server's release of the clients from it
	@field name  the topic of a posted value, or the name of a barrier
	@field value the posted value, nil for the other kinds
]=]
export type Message = {
	read item:  string,
	read kind:  Kind,
	read name:  string,
	read value: unknown,
}


--[=[
	How a link reaches the other halves.

	The server's messages go to every client and a client's to the server. What arrives is not
	trusted: a client chooses what it sends.

	@field send   sends a message to the other halves
	@field listen calls the listener with each message and its sender; returns the function to stop
]=]
export type Wire = {
	read send:   (message: Message) -> (),
	read listen: (listener: (message: unknown, sender: unknown) -> ()) -> () -> (),
}


--[=[
	What `new` needs to make a link.

	@field item        the id of the test, which every message of the pair carries
	@field role        which half this link is
	@field clientCount how many client halves the pair has, at least 1
	@field wire        how this link reaches the other halves
	@field timeout     how long a wait lasts before it gives up, in seconds; 10 when omitted
]=]
export type Options = {
	read item:        string,
	read role:        Role,
	read clientCount: number,
	read wire:        Wire,
	read timeout:     number?,
}


type Entry = {
	read value: unknown,
}


type Waiter = {
	read thread: thread,
	read needed: number,

	timer:       thread?,
}


type Fields = {
	read _item:         string,
	read _role:         Role,
	read _clientCount:  number,
	read _timeout:      number,
	read _wire:         Wire,
	read _entriesByKey: { [string]: { Entry } },
	read _waitersByKey: { [string]: { Waiter } },

	_stopListening:     (() -> ())?,
	_timeoutReason:     string?,
}


--- One half's end of the channel between the halves of a pair test.
export type Link = setmetatable<Fields, typeof(Link)>


-- Constants ---------------------------------------------------------------------------------------

--- How long a wait lasts when the options give no other time, in seconds.
const WAIT_TIMEOUT = 10


--- The kind that each word in a message names.
const KIND_BY_WORD: { read [string]: Kind } = {
	Arrived  = "Arrived",
	Posted   = "Posted",
	Released = "Released",
}
table.freeze(KIND_BY_WORD)


--- The kinds that each half accepts: a server hears the clients, a client hears the server.
const IS_ACCEPTED_BY_ROLE: Types.Complete<{ read [Role]: { read [Kind]: true } }> = {
	Server = { Arrived = true, Posted = true },
	Client = { Released = true, Posted = true },
}
table.freeze(IS_ACCEPTED_BY_ROLE)


-- Private -----------------------------------------------------------------------------------------

local function isWhole(value: number): boolean
	if not math.isfinite(value) then
		return false
	end

	return math.floor(value) == value
end


local function keyOf(kind: Kind, name: string): string
	return `{kind}:{name}`
end


local function toMessage(value: unknown): Message?
	local entries = Values.toEntries(value)
	if entries == nil then
		return nil
	end

	local item = Values.toText(entries.item)
	if item == nil then
		return nil
	end

	local word = Values.toText(entries.kind)
	if word == nil then
		return nil
	end

	local name = Values.toText(entries.name)
	if name == nil then
		return nil
	end

	local kind = KIND_BY_WORD[word]
	if kind == nil then
		return nil
	end

	return {
		item  = item,
		kind  = kind,
		name  = name,
		value = entries.value,
	}
end


local function entriesOf(self: Link, key: string): { Entry }
	local entries = self._entriesByKey[key]
	if entries == nil then
		entries                 = {}
		self._entriesByKey[key] = entries
	end

	return entries
end


local function waitersOf(self: Link, key: string): { Waiter }
	local waiters = self._waitersByKey[key]
	if waiters == nil then
		waiters                 = {}
		self._waitersByKey[key] = waiters
	end

	return waiters
end


local function removeEntries(entries: { Entry }, count: number): { unknown }
	local values = table.create(count) :: { unknown }
	for i = 1, count do
		local entry = table.remove(entries, 1)
		assert(entry, "a wait is served only when the entries it needs are there")

		values[i] = entry.value
	end

	return values
end


local function send(self: Link, kind: Kind, name: string, value: unknown): ()
	self._wire.send({
		item  = self._item,
		kind  = kind,
		name  = name,
		value = value,
	})
end


--[=[
	Resumes the waiters of a key, oldest first, for as long as the entries that arrived cover them.

	@param key the kind and name that the entries arrived under
]=]
local function serve(self: Link, key: string): ()
	local waiters = waitersOf(self, key)
	local entries = entriesOf(self, key)
	while
		#waiters > 0
		and #entries >= waiters[1].needed
	do
		local waiter = table.remove(waiters, 1)
		assert(waiter, "a waiter is served only when one is waiting")

		local values = removeEntries(entries, waiter.needed)
		if waiter.timer ~= nil then
			task.cancel(waiter.timer)
		end

		task.spawn(waiter.thread, true, values)
	end
end


-- In Private, not Handlers: `take`, a private function, starts the timer, and Handlers sits below
-- Private (the same recorded deviation as `onCaseError` in Properties).
local function onWaitTimeout(self: Link, key: string, waiter: Waiter): ()
	local waiters  = waitersOf(self, key)
	local position = table.find(waiters, waiter)
	if position ~= nil then
		table.remove(waiters, position)
	end

	task.spawn(waiter.thread, false)
end


--[=[
	Suspends the running thread until `needed` entries have arrived under `key`.

	@param  key    the kind and name that the entries arrive under
	@param  needed how many entries to wait for, at least 1
	@return the values of the entries, oldest first, or nil when the wait timed out
]=]
local function take(self: Link, key: string, needed: number): { unknown }?
	local entries = entriesOf(self, key)
	if #entries >= needed then
		return removeEntries(entries, needed)
	end

	local waiter: Waiter = {
		thread = coroutine.running(),
		needed = needed,
		timer  = nil,
	}

	table.insert(waitersOf(self, key), waiter)

	-- The waiter is listed before the timer starts, so that a timer finds it in the list.
	waiter.timer = task.delay(self._timeout, onWaitTimeout, self, key, waiter)

	local didArrive: boolean, values: { unknown }? = coroutine.yield()
	if not didArrive then
		return nil
	end

	return values
end


local function isOpen(self: Link): boolean
	return self._stopListening ~= nil
end


local function recordTimeout(self: Link, reason: string): ()
	if self._timeoutReason == nil then
		self._timeoutReason = reason
	end
end


-- Handlers ----------------------------------------------------------------------------------------

local function onMessage(self: Link, received: unknown, _: unknown): ()
	local message = toMessage(received)
	if message == nil then
		return
	end

	if message.item ~= self._item then
		return
	end

	if not IS_ACCEPTED_BY_ROLE[self._role][message.kind] then
		return
	end

	local key = keyOf(message.kind, message.name)
	table.insert(entriesOf(self, key), { value = message.value })

	serve(self, key)
end


-- Public ------------------------------------------------------------------------------------------

--[=[
	Creates a link that listens on a wire.

	@param  options the test, the half, the pair's size and the wire
	@return an open link
	@error  when `options.item` is empty
	@error  when `options.clientCount` is not a whole number of at least 1
	@error  when `options.timeout` is not a finite number above 0
]=]
function Link.new(options: Options): Link
	if options.item == "" then
		error('item must not be empty, got ""', 2)
	end

	if
		not isWhole(options.clientCount)
		or options.clientCount < 1
	then
		error(`clientCount must be a whole number of at least 1, got {options.clientCount}`, 2)
	end

	local timeout = options.timeout or WAIT_TIMEOUT
	if
		not math.isfinite(timeout)
		or timeout <= 0
	then
		error(`timeout must be a finite number above 0, got {timeout}`, 2)
	end

	local link: Link = setmetatable({
		_item          = options.item,
		_role          = options.role,
		_clientCount   = options.clientCount,
		_timeout       = timeout,
		_wire          = options.wire,
		_entriesByKey  = {},
		_waitersByKey  = {},
		_stopListening = nil,
		_timeoutReason = nil,
	}, Link)

	link._stopListening = options.wire.listen(function(received: unknown, sender: unknown): ()
		onMessage(link, received, sender)
	end)

	return link
end


--[=[
	Waits for another half to post a value under a topic, and returns it.

	Values come in the order they were posted, each once.

	@param  topic the name the value was posted under, not empty
	@return the value, nil when it was posted as nil
	@error  when `topic` is empty, or the link is closed
	@error  when no value is posted within the timeout, after recording why for `timeoutReason`
]=]
function Link.await(self: Link, topic: string): unknown
	if topic == "" then
		error('topic must not be empty, got ""', 2)
	end

	if not isOpen(self) then
		error("link must be open to await, got closed", 2)
	end

	local values = take(self, keyOf("Posted", topic), 1)
	if values == nil then
		local requirement = `link:await("{topic}") must hear a post within {self._timeout} seconds`
		local reason      = `{requirement}, got none`
		recordTimeout(self, reason)
		error(reason, 2)
	end

	return values[1]
end


--[=[
	Waits until every half has reached the barrier of the same name.

	The server waits for all clients and then lets them through, and a client waits to be let
	through. A barrier can be reused: its arrivals are counted in order.

	@param name the name of the barrier, not empty
	@error when `name` is empty, or the link is closed
	@error when the halves do not all arrive within the timeout, after recording why
]=]
function Link.barrier(self: Link, name: string): ()
	if name == "" then
		error('name must not be empty, got ""', 2)
	end

	if not isOpen(self) then
		error("link must be open to reach a barrier, got closed", 2)
	end

	if self._role == "Server" then
		local arrivalKey = keyOf("Arrived", name)
		local arrivals   = take(self, arrivalKey, self._clientCount)
		if arrivals == nil then
			local arrivedCount = #entriesOf(self, arrivalKey)
			local expected     = self._clientCount
			local requirement  = `link:barrier("{name}") must see {expected} clients arrive`
			local reason       = `{requirement} within {self._timeout} seconds, got {arrivedCount}`
			recordTimeout(self, reason)
			error(reason, 2)
		end

		send(self, "Released", name, nil)
		return
	end

	send(self, "Arrived", name, nil)

	local releases = take(self, keyOf("Released", name), 1)
	if releases == nil then
		local requirement = `link:barrier("{name}") must be released by the server`
		local reason      = `{requirement} within {self._timeout} seconds, got no release`
		recordTimeout(self, reason)
		error(reason, 2)
	end
end


--[=[
	Stops listening and cancels the timers of the waits that are pending.

	A thread suspended in a wait stays suspended, for its owner to cancel. Repeating `close` does
	nothing.
]=]
function Link.close(self: Link): ()
	local stopListening = self._stopListening
	if stopListening ~= nil then
		stopListening()
		self._stopListening = nil
	end

	for _, waiters in self._waitersByKey do
		for _, waiter in waiters do
			if waiter.timer ~= nil then
				task.cancel(waiter.timer)
			end
		end
	end

	table.clear(self._waitersByKey)
end


--[=[
	Sends a value to the other halves under a topic, and does not wait.

	The server posts to every client, and a client posts to the server.

	@param topic the name to post under, not empty
	@param value the value to send, which a remote can carry
	@error when `topic` is empty, or the link is closed
]=]
function Link.post(self: Link, topic: string, value: unknown): ()
	if topic == "" then
		error('topic must not be empty, got ""', 2)
	end

	if not isOpen(self) then
		error("link must be open to post, got closed", 2)
	end

	send(self, "Posted", topic, value)
end


--[=[
	Tells why a wait of this link ran out.

	@return the requirement that the first wait to run out failed, nil while none has
]=]
function Link.timeoutReason(self: Link): string?
	return self._timeoutReason
end


--[=[
	Wraps the pair-test remote as the wire of a client half.

	@param  remote the remote that carries the messages of pair tests
	@return a wire that sends to the server and hears it
]=]
function Link.wrapAtClient(remote: RemoteEvent): Wire
	return {
		send = function(message: Message): ()
			remote:FireServer(message)
		end,

		listen = function(listener: (message: unknown, sender: unknown) -> ()): () -> ()
			local function onClientEvent(message: unknown): ()
				listener(message, nil)
			end

			local connection = remote.OnClientEvent:Connect(onClientEvent)

			return function(): ()
				connection:Disconnect()
			end
		end,
	}
end


--[=[
	Wraps the pair-test remote as the wire of the server half.

	A message from a player who is not one of `clients` is dropped.

	@param  remote  the remote that carries the messages of pair tests
	@param  clients the players whose client halves are in the pair
	@return a wire that sends to each of `clients` and hears them
]=]
function Link.wrapAtServer(remote: RemoteEvent, clients: { Player }): Wire
	local clientPlayers: { [Player]: true } = {}
	for _, client in clients do
		clientPlayers[client] = true
	end

	return {
		send = function(message: Message): ()
			for _, client in clients do
				remote:FireClient(client, message)
			end
		end,

		listen = function(listener: (message: unknown, sender: unknown) -> ()): () -> ()
			local function onServerEvent(player: Player, message: unknown): ()
				if clientPlayers[player] then
					listener(message, player)
				end
			end

			local connection = remote.OnServerEvent:Connect(onServerEvent)

			return function(): ()
				connection:Disconnect()
			end
		end,
	}
end


return table.freeze(Link)
