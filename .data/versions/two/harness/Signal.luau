--!strict

--[=[
	Signal

	A signal that stands in for the engine's own, so that the simulated engine can offer Lync the
	same `Connect` it would call on a real one.

	Listeners run in the order they were connected, on the stack of whoever fires the signal, one
	after another. A listener that throws stops the firing, and the error reaches the firer.

	A listener connected while a signal is firing hears the next firing and not the one under way,
	and a listener disconnected while it is firing is not called after that.
]=]


-- Module ------------------------------------------------------------------------------------------

local Signal   = {}
Signal.__index = Signal


-- Types -------------------------------------------------------------------------------------------

--[=[
	One listener's hold on a signal.

	@field Connected  true until `Disconnect` runs, which a caller must not set itself
	@field Disconnect stops the listener from being called again, and does nothing when repeated
]=]
export type Connection = {
	Connected:  boolean,
	Disconnect: (self: Connection) -> (),
}


type Entry<TArgs...> = {
	read listener:   (TArgs...) -> (),
	read connection: Connection,
	read isOnce:     boolean,
}


type Fields<TArgs...> = {
	_entries: { Entry<TArgs...> },
}


--- A list of listeners that a firing calls with the arguments `TArgs...`.
export type Signal<TArgs...> = setmetatable<Fields<TArgs...>, typeof(Signal)>


-- Private -----------------------------------------------------------------------------------------

local function disconnect(self: Connection): ()
	self.Connected = false
end


local function add<TArgs...>(
	self:     Signal<TArgs...>,
	listener: (TArgs...) -> (),
	isOnce:   boolean
): Connection
	local connection: Connection = {
		Connected  = true,
		Disconnect = disconnect,
	}

	local entry: Entry<TArgs...> = {
		listener   = listener,
		connection = connection,
		isOnce     = isOnce,
	}

	table.insert(self._entries, entry)

	return connection
end


-- Public ------------------------------------------------------------------------------------------

--[=[
	Creates a signal with no listeners.

	@return a signal that has never fired
]=]
function Signal.new<TArgs...>(): Signal<TArgs...>
	return setmetatable({
		_entries = {},
	}, Signal)
end


--[=[
	Adds a listener that is called at every firing until it is disconnected.

	@param  listener what to call, with the arguments of the firing
	@return the connection, whose `Disconnect` stops the listener
]=]
function Signal.Connect<TArgs...>(self: Signal<TArgs...>, listener: (TArgs...) -> ()): Connection
	return add(self, listener, false)
end


--[=[
	Counts the listeners that are still connected.

	@return how many listeners a firing now would call
]=]
function Signal.connectedCount<TArgs...>(self: Signal<TArgs...>): number
	local count = 0
	for _, entry in self._entries do
		if entry.connection.Connected then
			count += 1
		end
	end

	return count
end


--[=[
	Calls the connected listeners in the order they were connected.

	@param ... the arguments to give each listener
	@error whatever a listener throws, unchanged, after which later listeners are not called
]=]
function Signal.fire<TArgs...>(self: Signal<TArgs...>, ...: TArgs...): ()
	local entries = self._entries
	local count   = #entries
	local hasDead = false
	for i = 1, count do
		local entry = entries[i]
		if not entry.connection.Connected then
			hasDead = true
			continue
		end

		if entry.isOnce then
			entry.connection.Connected = false
			hasDead                    = true
		end

		entry.listener(...)
	end

	if not hasDead then
		return
	end

	-- A new list replaces the old one, so that a firing under way keeps the list it began on.
	local alive: { Entry<TArgs...> } = {}
	for _, entry in self._entries do
		if entry.connection.Connected then
			table.insert(alive, entry)
		end
	end

	self._entries = alive
end


--[=[
	Adds a listener that is called at the next firing only.

	@param  listener what to call, with the arguments of that firing
	@return the connection, whose `Disconnect` stops the listener before it is called
]=]
function Signal.Once<TArgs...>(self: Signal<TArgs...>, listener: (TArgs...) -> ()): Connection
	return add(self, listener, true)
end


return table.freeze(Signal)
