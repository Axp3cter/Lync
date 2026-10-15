--!strict

--[=[
	Scheduler

	When frames leave (v5.md §5.1). Automatically, a server flushes at every step, and a client
	once at least 1/60 s has accumulated since its last automatic flush, so a 240 FPS client sends
	at 60 Hz. Under the manual scheduler frames leave only on `Lync.flush()`, and data pending
	for more than 2 steps is reported once as `missedFlush`.

	Every step also answers waiting `HELLO`s, times out requests and checks handler threads,
	reports `remotesMissing` once on a client still without remotes 10 s after its first use, and
	sweeps the facts.
]=]

-- Imports -----------------------------------------------------------------------------------------

local Facts = require("../diag/facts")
local Handshake = require("../session/handshake")
local Outbox = require("./outbox")
local Requests = require("../session/requests")
local State = require("../session/state")

-- Module ------------------------------------------------------------------------------------------

local Scheduler = {}

-- Constants ---------------------------------------------------------------------------------------

const CLIENT_INTERVAL = 1 / 60
const INTERVAL_EPSILON = 1e-6
const MAX_PENDING_STEPS = 2

-- Private -----------------------------------------------------------------------------------------

local function flush(rt: State.Runtime)
	if not rt.config.profile or debug.profilebegin == nil then
		Outbox.flush(rt)
		return
	end

	debug.profilebegin("Lync.flush")
	Outbox.flush(rt)
	debug.profileend()
end

local function checkRemotes(rt: State.Runtime)
	if rt.isRemotesReported or rt.host.transport.ready() then
		return
	end

	if rt.host.clock() - rt.firstUseAt < State.WAIT_SECONDS then
		return
	end

	rt.isRemotesReported = true
	State.fact(rt, "remotesMissing", nil, nil, State.WAIT_SECONDS)
end

local function checkMissed(rt: State.Runtime)
	if #rt.pending == 0 then
		rt.pendingSteps = 0
		return
	end

	rt.pendingSteps += 1
	if rt.pendingSteps <= MAX_PENDING_STEPS or rt.isMissedReported then
		return
	end

	rt.isMissedReported = true
	State.fact(rt, "missedFlush", nil, nil, rt.pendingSteps)
end

local function step(rt: State.Runtime, dt: number)
	if rt.side == "server" then
		Handshake.sweep(rt)
	else
		checkRemotes(rt)
	end
	Requests.sweep(rt)

	if rt.mode == "manual" then
		checkMissed(rt)
	elseif rt.side == "server" then
		flush(rt)
	else
		rt.accumulated = math.min(rt.accumulated + dt, 2 * CLIENT_INTERVAL)
		if rt.accumulated + INTERVAL_EPSILON >= CLIENT_INTERVAL then
			rt.accumulated -= CLIENT_INTERVAL
			flush(rt)
		end
	end

	Facts.sweep(rt.facts, rt.host.clock())
end

-- Public ------------------------------------------------------------------------------------------

--[=[
	Sends everything pending now (`Lync.flush()`): idempotent, and safe in handlers.

	@param rt the runtime
]=]
function Scheduler.flush(rt: State.Runtime)
	flush(rt)
	rt.pendingSteps = 0
	rt.isMissedReported = false
end

--[=[
	Chooses the scheduler (`Lync.scheduler`).

	@param rt   the runtime
	@param mode "automatic", or "manual" for frames to leave only on `Lync.flush()`
]=]
function Scheduler.mode(rt: State.Runtime, mode: State.Mode)
	rt.mode = mode
	rt.pendingSteps = 0
	rt.isMissedReported = false
end

--[=[
	Starts stepping a runtime at every `PostSimulation`.

	@param rt the runtime
]=]
function Scheduler.start(rt: State.Runtime)
	table.insert(
		rt.disconnects,
		rt.host.onStep(function(dt: number)
			step(rt, dt)
		end)
	)
end

return table.freeze(Scheduler)
