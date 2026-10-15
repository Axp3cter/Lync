--!strict

--[=[
	Ticks

	The state tick T = ⌊(`GetServerTimeNow()` − epoch) × `stateRate`⌋ (v5.md §5.1), the
	downstream reliable tick header against the last reliable frame a client received (§4.1),
	and `state.rate` changes: a new rate takes effect at the next state tick, with an epoch that
	keeps T continuous, and every welcomed client gets it in `RATE` (§7.5).
]=]

-- Imports -----------------------------------------------------------------------------------------

local Control = require("../transport/control")
local State = require("../session/state")

-- Module ------------------------------------------------------------------------------------------

local Ticks = {}

-- Constants ---------------------------------------------------------------------------------------

const MODE_UNCHANGED = 0
const MODE_NEXT = 1
const MODE_FULL = 2

-- Public ------------------------------------------------------------------------------------------

--[=[
	Starts a server flush's tick: applies a changed `state.rate` once T has advanced since the
	last flush, sending `RATE` to every client already welcomed.

	@param  rt the server's runtime
	@return T for the flush
]=]
function Ticks.advance(rt: State.Runtime): number
	local tick = Ticks.current(rt)
	local stateRate = rt.config.stateRate
	if stateRate ~= rt.stateRate and tick > rt.lastTick then
		rt.epoch = rt.host.now() - tick / stateRate
		rt.stateRate = stateRate
		for _, conn in rt.connections do
			if conn.isWelcomed then
				rt.control(rt, conn.player, Control.RATE, { epoch = rt.epoch, stateRate = stateRate })
			end
		end
	end

	rt.lastTick = tick
	return tick
end

--[=[
	Returns the current state tick: the server's own, or a client's estimate of the server's.

	@param  rt the runtime
	@return T
]=]
function Ticks.current(rt: State.Runtime): number
	return math.floor((rt.host.now() - rt.epoch) * rt.stateRate)
end

--[=[
	Returns a downstream reliable frame's tick mode.

	@param  lastTick the last tick the recipients received, -1 for none or when they differ
	@param  tick     the frame's tick
	@return 0 unchanged, 1 plus one, 2 full
]=]
function Ticks.mode(lastTick: number, tick: number): number
	if lastTick < 0 then
		return MODE_FULL
	end

	if tick == lastTick then
		return MODE_UNCHANGED
	end

	return if tick == lastTick + 1 then MODE_NEXT else MODE_FULL
end

return table.freeze(Ticks)
