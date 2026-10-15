--!strict

--[=[
	Host

	The seam between a runtime and the engine (m2-plan.md §2): everything a runtime needs from
	Roblox comes through one `Host` record, so one process can hold a server and many clients.

	`Roblox.host` builds the record from the engine's services; `test/support/world.luau` builds
	it over a virtual clock and a simulated network. Types only.
]=]

-- Module ------------------------------------------------------------------------------------------

local Host = {}

-- Types -------------------------------------------------------------------------------------------

--- A remote: 0 reliable, 1 unreliable, the encoding facts use as evidence (v5.md §7.3).
export type Lane = number

--- What `observe` and the host's own signals return.
export type Connection = {
	disconnect: (self: Connection) -> (),
}

--- The two remotes, Lync's only way across the network (v5.md §4.1).
export type Transport = {
	-- server: create the remotes; client: start watching for them
	open: () -> (),
	-- client: both remotes found; server: true after `open`
	ready: () -> boolean,
	-- `player` is nil on a client; `instances` nil sends the buffer alone
	send: (player: Player?, lane: Lane, frame: buffer, instances: { Instance? }?) -> (),
	-- server only: one `FireAllClients`
	broadcast: (lane: Lane, frame: buffer, instances: { Instance? }?) -> (),
	-- the remote's arguments, untouched; `player` is nil on a client
	onReceive: (handler: (player: Player?, lane: Lane, ...unknown) -> ()) -> (),
}

--- The engine, as a runtime sees it.
export type Host = {
	side: "server" | "client",
	-- `GetServerTimeNow()`: fact times, epochs and ticks
	now: () -> number,
	-- `os.clock()`: buckets, timeouts and windows
	clock: () -> number,
	-- a uniform integer in [0, 2^32 - 1]: keys and seeds
	entropy32: () -> number,
	-- `task.spawn`: an error in `f` is a native report
	spawn: (f: (...any) -> (), ...any) -> thread,
	-- a native report of Lync's own: an error raised in its own thread (v5.md §7.2)
	report: (message: string) -> (),
	-- a console line with constant text; `context` holds numbers and strings only (v5.md §7.4)
	warn: (template: string, context: { [string]: any }) -> (),
	-- after every simulation step; returns the disconnect
	onStep: (f: (dt: number) -> ()) -> () -> (),
	-- server: `BindToClose`
	onClose: (f: () -> ()) -> (),
	players: () -> { Player },
	onPlayerAdded: (f: (player: Player) -> ()) -> () -> (),
	onPlayerRemoving: (f: (player: Player) -> ()) -> () -> (),
	-- client only
	localPlayer: Player?,
	transport: Transport,
}

return table.freeze(Host)
