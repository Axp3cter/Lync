--!strict

--[=[
	Facts

	Records what happened (v5.md §7.3) and delivers it to observers as frozen facts, within the
	delivery limits that protect the server; the limits never hide an occurrence.

	- **Coalescing.** A key is (player, reason, namespace, definition). Its first occurrence is
	  delivered at once and opens a window of `observe.window` s; if more occur, one fact at the
	  window's close carries their count and the last one's evidence.
	- **Caps.** At most `observe.perPlayerEvents` facts per player and `observe.serverEvents` per
	  server, each per window, a window opening at the first occurrence after the last closed.
	  Occurrences past a cap are counted per player and reason, and each such player gets one
	  `suppressed` at the close of its window, exempt from the caps.
	- **Memory.** A player holds at most `perPlayerEvents` keys plus one count per reason, until
	  `forget`, or until a sweep finds it holding nothing.

	Each observer gets each fact through `host.spawn`, so a throwing observer is a native report
	and a yielding one holds only itself. Windows are `os.clock()` seconds; `first` and `last`
	are `GetServerTimeNow()`. Facts also feed the console, every occurrence.
]=]

-- Imports -----------------------------------------------------------------------------------------

local Codes = require("./codes")
local Console = require("./console")
local Host = require("../host/host")

-- Module ------------------------------------------------------------------------------------------

local Facts = {}

-- Types -------------------------------------------------------------------------------------------

--- What happened, frozen when delivered; `evidence` holds the reason's fields (Codes.evidence).
export type Fact = {
	reason: Codes.Code,
	player: Player?,
	namespace: string?,
	definition: string?,
	count: number,
	first: number,
	last: number,
	evidence: { [string]: number },
}

-- An open coalescing window. `count`, `first`, `last` and the evidence cover the occurrences
-- after the delivered first one.
type Key = {
	reason: Codes.Code,
	namespace: string?,
	definition: string?,
	closesAt: number,
	count: number,
	first: number,
	last: number,
	e1: number?,
	e2: number?,
	e3: number?,
	e4: number?,
	e5: number?,
}

-- What one player, or the local side when `player` is nil, holds.
type Sender = {
	player: Player?,
	keys: { Key },
	capClosesAt: number?,
	deliveredCount: number,
	suppressedByReason: { [string]: number },
	suppressedCount: number,
	suppressedFirst: number,
	suppressedLast: number,
}

type Observer = { notify: (fact: Fact) -> () }

--- One side's facts.
export type State = {
	host: Host.Host,
	console: Console.State,
	window: number,
	perPlayer: number,
	server: number,
	observers: { Observer },
	senderByPlayer: { [Player]: Sender },
	localSender: Sender?,
	serverClosesAt: number?,
	serverDeliveredCount: number,
}

-- Constants ---------------------------------------------------------------------------------------

const DEFAULT_WINDOW = 30
const DEFAULT_PER_PLAYER = 16
const DEFAULT_SERVER = 256

-- Private -----------------------------------------------------------------------------------------

local function newSender(player: Player?): Sender
	return {
		player = player,
		keys = {},
		capClosesAt = nil,
		deliveredCount = 0,
		suppressedByReason = {},
		suppressedCount = 0,
		suppressedFirst = 0,
		suppressedLast = 0,
	}
end

local function senderOf(s: State, player: Player?): Sender
	if player == nil then
		local localSender = s.localSender
		if localSender ~= nil then
			return localSender
		end

		local created = newSender(nil)
		s.localSender = created
		return created
	end

	local sender = s.senderByPlayer[player]
	if sender ~= nil then
		return sender
	end

	local created = newSender(player)
	s.senderByPlayer[player] = created
	return created
end

local function keyOf(sender: Sender, reason: Codes.Code, namespace: string?, definition: string?): Key?
	for _, key in sender.keys do
		if key.reason == reason and key.definition == definition and key.namespace == namespace then
			return key
		end
	end

	return nil
end

local function openWindows(s: State, sender: Sender, clock: number)
	if sender.capClosesAt == nil then
		sender.capClosesAt = clock + s.window
		sender.deliveredCount = 0
	end

	if s.serverClosesAt == nil then
		s.serverClosesAt = clock + s.window
		s.serverDeliveredCount = 0
	end
end

local function isUnderCaps(s: State, sender: Sender): boolean
	return sender.deliveredCount < s.perPlayer and s.serverDeliveredCount < s.server
end

local function emit(s: State, fact: Fact)
	for _, observer in s.observers do
		s.host.spawn(observer.notify, fact)
	end
end

local function evidenceOf(
	reason: Codes.Code,
	e1: number?,
	e2: number?,
	e3: number?,
	e4: number?,
	e5: number?
): { [string]: number }
	local values = { e1, e2, e3, e4, e5 }
	local evidence = {}
	for i, name in Codes.evidence[reason] do
		evidence[name] = values[i]
	end

	return table.freeze(evidence) :: any
end

local function deliver(
	s: State,
	sender: Sender,
	reason: Codes.Code,
	namespace: string?,
	definition: string?,
	count: number,
	first: number,
	last: number,
	evidence: { [string]: number }
)
	sender.deliveredCount += 1
	s.serverDeliveredCount += 1
	emit(
		s,
		table.freeze({
			reason = reason,
			player = sender.player,
			namespace = namespace,
			definition = definition,
			count = count,
			first = first,
			last = last,
			evidence = evidence,
		})
	)
end

local function suppress(
	s: State,
	sender: Sender,
	reason: Codes.Code,
	count: number,
	first: number,
	last: number,
	clock: number
)
	openWindows(s, sender, clock)
	if sender.suppressedCount == 0 then
		sender.suppressedFirst = first
	end

	sender.suppressedByReason[reason] = (sender.suppressedByReason[reason] or 0) + count
	sender.suppressedCount += count
	sender.suppressedLast = last
end

local function closeKeys(s: State, sender: Sender, clock: number)
	local keys = sender.keys
	local i = 1
	while i <= #keys do
		local key = keys[i]
		if clock < key.closesAt then
			i += 1
			continue
		end

		keys[i] = keys[#keys]
		keys[#keys] = nil
		if key.count == 0 then
			continue
		end

		openWindows(s, sender, clock)
		if not isUnderCaps(s, sender) then
			suppress(s, sender, key.reason, key.count, key.first, key.last, clock)
			continue
		end

		local evidence = evidenceOf(key.reason, key.e1, key.e2, key.e3, key.e4, key.e5)
		deliver(
			s,
			sender,
			key.reason,
			key.namespace,
			key.definition,
			key.count,
			key.first,
			key.last,
			evidence
		)
	end
end

local function closeCapWindow(s: State, sender: Sender)
	sender.capClosesAt = nil
	sender.deliveredCount = 0
	if sender.suppressedCount == 0 then
		return
	end

	local fact: Fact = {
		reason = "suppressed",
		player = sender.player,
		namespace = nil,
		definition = nil,
		count = sender.suppressedCount,
		first = sender.suppressedFirst,
		last = sender.suppressedLast,
		evidence = table.freeze(table.clone(sender.suppressedByReason)),
	}
	table.clear(sender.suppressedByReason)
	sender.suppressedCount = 0
	emit(s, table.freeze(fact))
end

-- Closes what has ended for one sender, and answers whether it now holds nothing.
local function sweepSender(s: State, sender: Sender, clock: number): boolean
	closeKeys(s, sender, clock)

	local capClosesAt = sender.capClosesAt
	if capClosesAt ~= nil and clock >= capClosesAt then
		closeCapWindow(s, sender)
	end

	return #sender.keys == 0 and sender.capClosesAt == nil
end

-- Public ------------------------------------------------------------------------------------------

--[=[
	Creates a side's facts, with the default limits (v5.md §7.5).

	@param  host    the side's host: clocks, and `spawn` for delivery
	@param  console the side's console, which counts every occurrence
	@return the facts
]=]
function Facts.new(host: Host.Host, console: Console.State): State
	return {
		host = host,
		console = console,
		window = DEFAULT_WINDOW,
		perPlayer = DEFAULT_PER_PLAYER,
		server = DEFAULT_SERVER,
		observers = {},
		senderByPlayer = {},
		localSender = nil,
		serverClosesAt = nil,
		serverDeliveredCount = 0,
	}
end

--[=[
	Sets the limits, for windows opened from now on; the console's window follows `window`.

	@param s         the facts
	@param window    `observe.window`, seconds
	@param perPlayer `observe.perPlayerEvents`
	@param server    `observe.serverEvents`
]=]
function Facts.configure(s: State, window: number, perPlayer: number, server: number)
	s.window = window
	s.perPlayer = perPlayer
	s.server = server
	Console.configure(s.console, window)
end

--[=[
	Frees what a player holds: its keys, counts and suppressed occurrences.

	@param s      the facts
	@param player the player, usually one leaving
]=]
function Facts.forget(s: State, player: Player)
	s.senderByPlayer[player] = nil
end

--[=[
	Delivers every fact from now on to `notify`, each in its own thread.

	@param  s      the facts
	@param  notify called with each fact
	@return the connection, whose `disconnect` stops deliveries
]=]
function Facts.observe(s: State, notify: (fact: Fact) -> ()): Host.Connection
	local observer: Observer = { notify = notify }
	local observers = table.clone(s.observers)
	table.insert(observers, observer)
	s.observers = observers

	local function disconnect(_connection: Host.Connection)
		local kept = table.clone(s.observers)
		local index = table.find(kept, observer)
		if index == nil then
			return
		end

		table.remove(kept, index)
		s.observers = kept
	end

	return { disconnect = disconnect }
end

--[=[
	Records one occurrence. An occurrence of an open key allocates nothing.

	@param s          the facts
	@param reason     the fact's code
	@param player     the sender on a server, the player concerned for a server-local fact, nil
	                  for a client's local facts
	@param namespace  the namespace's name in this side's schema, if any
	@param definition the definition's name in this side's schema, if any
	@param e1         the first evidence field in the reason's registry order, and so on
]=]
function Facts.record(
	s: State,
	reason: Codes.Code,
	player: Player?,
	namespace: string?,
	definition: string?,
	e1: number?,
	e2: number?,
	e3: number?,
	e4: number?,
	e5: number?
)
	local clock = s.host.clock()
	Console.fact(s.console, reason, player, definition, clock)

	local now = s.host.now()
	local sender = senderOf(s, player)
	local key = keyOf(sender, reason, namespace, definition)
	if key ~= nil then
		if key.count == 0 then
			key.first = now
		end

		key.count += 1
		key.last = now
		key.e1 = e1
		key.e2 = e2
		key.e3 = e3
		key.e4 = e4
		key.e5 = e5
		return
	end

	openWindows(s, sender, clock)
	if not isUnderCaps(s, sender) or #sender.keys >= s.perPlayer then
		suppress(s, sender, reason, 1, now, now, clock)
		return
	end

	table.insert(sender.keys, {
		reason = reason,
		namespace = namespace,
		definition = definition,
		closesAt = clock + s.window,
		count = 0,
		first = now,
		last = now,
		e1 = nil,
		e2 = nil,
		e3 = nil,
		e4 = nil,
		e5 = nil,
	})
	local evidence = evidenceOf(reason, e1, e2, e3, e4, e5)
	deliver(s, sender, reason, namespace, definition, 1, now, now, evidence)
end

--[=[
	Closes every window that has ended: delivers coalesced facts and `suppressed`, frees players
	holding nothing, and sweeps the console. Called once per flush.

	@param s   the facts
	@param now `os.clock()`
]=]
function Facts.sweep(s: State, now: number)
	for player, sender in s.senderByPlayer do
		if sweepSender(s, sender, now) then
			s.senderByPlayer[player] = nil
		end
	end

	local localSender = s.localSender
	if localSender ~= nil and sweepSender(s, localSender, now) then
		s.localSender = nil
	end

	local serverClosesAt = s.serverClosesAt
	if serverClosesAt ~= nil and now >= serverClosesAt then
		s.serverClosesAt = nil
		s.serverDeliveredCount = 0
	end

	Console.sweep(s.console, now)
end

return table.freeze(Facts)
