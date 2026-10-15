--!strict

--[=[
	Net

	The simulated network of m2-plan.md §6.1: per client link and direction, it decides when each
	frame arrives, or that it never does. It holds no clock and no queue; `world.luau` asks it for
	arrival times and delivers on its virtual clock.

	- **Reliable** frames arrive in order: a frame never arrives before the one sent ahead of it,
	  and a stall holds every frame due during it until its end, then releases them in order.
	  Stalls start as a Poisson process of `stall.chance` per second and last `stall.seconds`.
	- **Unreliable** frames over `unreliableLimit` bytes are dropped, as the engine drops them.
	  The rest pass a Gilbert–Elliott burst state (entered with chance `burst.enter` per frame,
	  left with `burst.leave`, dropping every frame while in it), then `loss`; a frame that
	  survives arrives after `latency` plus its own uniform jitter, so frames reorder, and with
	  chance `duplicate` a second copy arrives with jitter of its own.

	Randomness is xorshift128 seeded through murmur3's finalizer, so a link's draws depend only
	on its seed and the calls made to it.
]=]

-- Module ------------------------------------------------------------------------------------------

local Net = {}

-- Types -------------------------------------------------------------------------------------------

--- A link's settings (m2-plan.md §6.1). `fps` is the client's step rate, used by the world.
export type Params = {
	latency: number,
	jitter: number,
	loss: number,
	burst: { enter: number, leave: number },
	duplicate: number,
	stall: { chance: number, seconds: number },
	fps: number,
	unreliableLimit: number,
}

--- A source of uniform 32-bit integers.
export type Random = () -> number

--- One direction of one client's connection.
export type Link = {
	params: Params,
	random: Random,
	stallRandom: Random,
	lastReliableAt: number,
	isBursting: boolean,
	stallStartsAt: number,
	stallEndsAt: number,
}

-- Constants ---------------------------------------------------------------------------------------

const RELIABLE = 0

const TWO_32 = 2 ^ 32
const WARM_UP_DRAWS = 16

-- Private -----------------------------------------------------------------------------------------

-- a × b mod 2^32, exact in doubles: each partial product stays below 2^48.
local function multiply32(a: number, b: number): number
	local high = bit32.rshift(a, 16)
	local low = bit32.band(a, 0xFFFF)
	return (low * b + bit32.band(high * b, 0xFFFF) * 0x10000) % TWO_32
end

local function mix32(x: number): number
	x = bit32.bxor(x, bit32.rshift(x, 16))
	x = multiply32(x, 0x85EBCA6B)
	x = bit32.bxor(x, bit32.rshift(x, 13))
	x = multiply32(x, 0xC2B2AE35)
	return bit32.bxor(x, bit32.rshift(x, 16))
end

local function uniformOf(random: Random): number
	return random() / TWO_32
end

local function exponentialOf(random: Random, rate: number): number
	return -math.log(1 - uniformOf(random)) / rate
end

local function startNextStall(link: Link, after: number)
	local stall = link.params.stall
	if stall.chance <= 0 then
		link.stallStartsAt = math.huge
		link.stallEndsAt = math.huge
		return
	end

	link.stallStartsAt = after + exponentialOf(link.stallRandom, stall.chance)
	link.stallEndsAt = link.stallStartsAt + stall.seconds
end

local function reliableArrival(link: Link, now: number): number
	local params = link.params
	local arrival = now + params.latency + params.jitter * uniformOf(link.random)
	arrival = math.max(arrival, link.lastReliableAt)
	while link.stallEndsAt <= arrival do
		startNextStall(link, link.stallEndsAt)
	end

	if arrival >= link.stallStartsAt then
		arrival = link.stallEndsAt
	end

	link.lastReliableAt = arrival
	return arrival
end

local function unreliableArrivals(link: Link, now: number, bytes: number): (number?, number?)
	local params = link.params
	if bytes > params.unreliableLimit then
		return nil, nil
	end

	local burst = params.burst
	local transition = uniformOf(link.random)
	if link.isBursting then
		link.isBursting = transition >= burst.leave
	else
		link.isBursting = transition < burst.enter
	end

	if link.isBursting or uniformOf(link.random) < params.loss then
		return nil, nil
	end

	local arrival = now + params.latency + params.jitter * uniformOf(link.random)
	if uniformOf(link.random) >= params.duplicate then
		return arrival, nil
	end

	return arrival, now + params.latency + params.jitter * uniformOf(link.random)
end

-- Public ------------------------------------------------------------------------------------------

--- The honest model's settings.
Net.HONEST = table.freeze({
	latency = 0.05,
	jitter = 0.02,
	loss = 0.05,
	burst = table.freeze({ enter = 0, leave = 1 }),
	duplicate = 0,
	stall = table.freeze({ chance = 0.05, seconds = 0.3 }),
	fps = 60,
	unreliableLimit = 1000,
}) :: Params

--[=[
	Creates one direction of a link.

	@param  params its settings
	@param  seed   any integer; equal seeds give equal draws
	@param  now    the virtual time it opens, from which its stalls are drawn
	@return the link
]=]
function Net.link(params: Params, seed: number, now: number): Link
	local link: Link = {
		params = params,
		random = Net.random(seed),
		stallRandom = Net.random(seed + 1),
		lastReliableAt = now,
		isBursting = false,
		stallStartsAt = now,
		stallEndsAt = now,
	}
	startNextStall(link, now)

	return link
end

--[=[
	Settings with some replaced: each field of `overrides` replaces the whole field.

	@param  base      the settings to start from
	@param  overrides the fields to replace, if any
	@return new settings
]=]
function Net.params(base: Params, overrides: { [string]: any }?): Params
	local params = table.clone(base) :: any
	for name, value in overrides or {} do
		assert(params[name] ~= nil, `{name} must be a network setting`)
		params[name] = value
	end

	return table.freeze(params)
end

--[=[
	A seeded source of uniform integers in [0, 2^32 - 1] (xorshift128).

	@param  seed any integer
	@return the source; each call draws the next integer
]=]
function Net.random(seed: number): Random
	local x = mix32(seed % TWO_32)
	local y = mix32(x + 0x9E3779B9)
	local z = mix32(y + 0x9E3779B9)
	local w = mix32(z + 0x9E3779B9)
	if x + y + z + w == 0 then
		w = 1
	end

	local function draw(): number
		local t = bit32.bxor(x, bit32.lshift(x, 11))
		x = y
		y = z
		z = w
		w = bit32.bxor(w, bit32.rshift(w, 19), t, bit32.rshift(t, 8))
		return w
	end

	for _ = 1, WARM_UP_DRAWS do
		draw()
	end

	return draw
end

--[=[
	Decides when a frame sent now arrives.

	@param  link  the link it is sent on
	@param  now   the virtual time it is sent
	@param  lane  0 reliable, 1 unreliable
	@param  bytes its size, for the unreliable limit
	@return the arrival time, or nil when it is lost; and a duplicate's arrival time, or nil
]=]
function Net.schedule(link: Link, now: number, lane: number, bytes: number): (number?, number?)
	if lane == RELIABLE then
		return reliableArrival(link, now), nil
	end

	return unreliableArrivals(link, now, bytes)
end

return table.freeze(Net)
