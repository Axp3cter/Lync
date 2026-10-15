--!strict

--[=[
	Timeline

	Virtual time for the simulated engine: a clock that moves only when a test advances it, with
	timers and a frame signal.

	`advance` fires what falls due in the order of the time it falls due and, for equal times, of
	the order it was scheduled in. A frame falls due at every multiple of the frame duration, and
	at an equal time it comes after every timer, since a frame closes the moment it ends.

	Time is kept as a whole number of ticks, 60,000,000 to the second, and not as seconds, so that
	two times are equal when they are the same instant. A frame of 1/60 second is 1,000,000 ticks,
	so frame k falls due at tick k * 1,000,000 exactly. In seconds it would not: `k / 60` and
	`k * (1 / 60)` differ in the last bit for 49 of the first 600 frames, which put a timer at
	`k / 60` after frame k, and a hundred steps of 0.1 fall short of 10, which lost a frame. A time
	or a duration is rounded to the nearest tick, a 60-millionth of a second, so two that differ by
	less are due together and fire in the order they were scheduled. A frame duration that is not
	a whole number of ticks is rounded the same way, and a tick is the shortest frame.

	Nothing here reads real time, and nothing yields: a callback runs on the stack of `advance`.

	The clock that Lync takes as its `clock` seam comes from `clock`: a record of plain functions,
	called as `clock.now()` and not as `clock:now()`, as the seam in the spec is written.
]=]


-- Imports -----------------------------------------------------------------------------------------

local Signal = require("./Signal")


-- Module ------------------------------------------------------------------------------------------

local Timeline   = {}
Timeline.__index = Timeline


-- Types -------------------------------------------------------------------------------------------

--[=[
	What `delay` gives back, to cancel the timer with.

	@field dueAt    the virtual time at which the timer falls due
	@field sequence the number of the timer among those scheduled, which orders equal times
]=]
export type Handle = {
	read dueAt:    number,
	read sequence: number,
}


type Event = {
	read dueAt:    number,
	read dueTicks: number,
	read sequence: number,
	read run:      () -> (),
}


type Fields = {
	read _frameDuration: number,
	read _frameTicks:    number,
	read _heap:          { Event },
	read _isPending:     { [Handle]: true },
	read _frame:         Signal.Signal<number>,

	_nowTicks:           number,
	_sequence:           number,
	_pendingCount:       number,
	_clock:              Clock?,
}


--- Virtual time, its timers and its frames.
export type Timeline = setmetatable<Fields, typeof(Timeline)>


--[=[
	The record that Lync takes as its `clock` seam.

	@field now    the virtual time in seconds
	@field delay  schedules `callback` with its arguments after `seconds`, and returns the handle
	@field cancel stops a timer that has not fallen due, and does nothing for one that has
	@field frame  fires the seconds a frame lasted, at every frame
]=]
export type Clock = {
	read now:    () -> number,
	read delay:  <TArgs...>(seconds: number, callback: (TArgs...) -> (), TArgs...) -> Handle,
	read cancel: (handle: Handle) -> (),
	read frame:  Signal.Signal<number>,
}


-- Constants ---------------------------------------------------------------------------------------

--- How long a frame lasts when a timeline is given no other duration: 60 frames a second.
const FRAME_DURATION = 1 / 60


--- How many ticks make a second: a whole number of them make a frame at 60 frames a second.
const TICKS_PER_SECOND = 60_000_000


--- The number of children each node of the timer heap has.
const HEAP_ARITY = 2


--- The sequence number of a frame, which no timer reaches, so that a frame follows an equal time.
const FRAME_SEQUENCE = math.huge


-- Private -----------------------------------------------------------------------------------------

local function isDuration(seconds: number): boolean
	return math.isfinite(seconds) and seconds >= 0
end


local function ticksOf(seconds: number): number
	return math.round(seconds * TICKS_PER_SECOND)
end


local function secondsOf(ticks: number): number
	return ticks / TICKS_PER_SECOND
end


local function isBefore(left: Event, right: Event): boolean
	if left.dueTicks ~= right.dueTicks then
		return left.dueTicks < right.dueTicks
	end

	return left.sequence < right.sequence
end


local function swap(heap: { Event }, first: number, second: number): ()
	heap[first], heap[second] = heap[second], heap[first]
end


local function push(heap: { Event }, event: Event): ()
	table.insert(heap, event)

	local child = #heap
	while child > 1 do
		local parent = child // HEAP_ARITY
		if not isBefore(heap[child], heap[parent]) then
			break
		end

		swap(heap, child, parent)
		child = parent
	end
end


local function earlierOf(heap: { Event }, size: number, current: number, candidate: number): number
	if candidate > size then
		return current
	end

	if isBefore(heap[candidate], heap[current]) then
		return candidate
	end

	return current
end


--[=[
	Removes the event that comes first from a heap and returns it.

	@param  heap the heap to take the event from, which must hold one
	@return the event that was first in (time, insertion) order
]=]
local function pop(heap: { Event }): Event
	local size = #heap
	local top  = heap[1]
	heap[1]    = heap[size]
	heap[size] = nil
	size      -= 1

	local parent = 1
	repeat
		local first    = parent * HEAP_ARITY
		local earliest = earlierOf(heap, size, parent, first)
		earliest       = earlierOf(heap, size, earliest, first + 1)

		local isSettled = earliest == parent
		if not isSettled then
			swap(heap, parent, earliest)
			parent = earliest
		end
	until isSettled

	return top
end


--[=[
	Finds the next event that has not been cancelled, and drops the cancelled ones before it.

	A frame is always scheduled, so there always is one.

	@return the event that comes first, left in the heap
]=]
local function nextEvent(self: Timeline): Event
	local heap = self._heap
	while not self._isPending[heap[1]] do
		pop(heap)
	end

	return assert(heap[1], "a timeline must hold its next frame")
end


local function scheduleFrame(self: Timeline, index: number): ()
	local dueTicks = index * self._frameTicks
	local event: Event = {
		dueAt    = secondsOf(dueTicks),
		dueTicks = dueTicks,
		sequence = FRAME_SEQUENCE,
		run      = function(): ()
			scheduleFrame(self, index + 1)
			self._frame:fire(self._frameDuration)
		end,
	}

	push(self._heap, event)
	self._isPending[event] = true
end


local function now(self: Timeline): number
	return secondsOf(self._nowTicks)
end


local function delay<TArgs...>(
	self:     Timeline,
	seconds:  number,
	callback: (TArgs...) -> (),
	...:      TArgs...
): Handle
	local argumentCount = select("#", ...)
	local arguments     = { ... }

	-- The arguments are stored apart from the callback, which the checker cannot pair with them.
	local stored = callback :: any

	local sequence = self._sequence + 1
	self._sequence = sequence

	local dueTicks = self._nowTicks + ticksOf(seconds)
	local event: Event = {
		dueAt    = secondsOf(dueTicks),
		dueTicks = dueTicks,
		sequence = sequence,
		run      = function(): ()
			self._pendingCount -= 1
			stored(table.unpack(arguments, 1, argumentCount))
		end,
	}

	push(self._heap, event)
	self._isPending[event] = true
	self._pendingCount    += 1

	return event
end


local function cancel(self: Timeline, handle: Handle): ()
	if not self._isPending[handle] then
		return
	end

	self._isPending[handle] = nil
	self._pendingCount     -= 1
end


-- Public ------------------------------------------------------------------------------------------

--[=[
	Creates a timeline at virtual time 0, with its first frame scheduled.

	@param  frameDuration how long a frame lasts in seconds, 1/60 when omitted
	@return a timeline with no timers
	@error  when `frameDuration` is not a finite number above 0
]=]
function Timeline.new(frameDuration: number?): Timeline
	frameDuration = frameDuration or FRAME_DURATION
	if
		not math.isfinite(frameDuration)
		or frameDuration <= 0
	then
		error(`frameDuration must be a finite number above 0, got {frameDuration}`, 2)
	end

	local self: Timeline = setmetatable({
		_frameDuration = frameDuration,
		_frameTicks    = math.max(1, ticksOf(frameDuration)),
		_heap          = {},
		_isPending     = {},
		_frame         = Signal.new(),

		_nowTicks      = 0,
		_sequence      = 0,
		_pendingCount  = 0,
		_clock         = nil,
	}, Timeline)

	scheduleFrame(self, 1)

	return self
end


--[=[
	Moves virtual time forward, firing what falls due on the way.

	Every timer and frame due by the end of `duration` fires in the order of its time and, for equal
	times, of its scheduling, with `now` at its time while it runs. Timers that a callback schedules
	for a time within `duration` fire in the same call. Afterwards `now` is `duration` later.

	@param duration how far to move, in seconds, 0 or more
	@error when `duration` is not a finite number of 0 or more
	@error whatever a callback throws, unchanged, with the time left at that callback's
]=]
function Timeline.advance(self: Timeline, duration: number): ()
	if not isDuration(duration) then
		error(`duration must be a finite number of 0 or more, got {duration}`, 2)
	end

	local targetTicks = self._nowTicks + ticksOf(duration)
	while true do
		local event = nextEvent(self)
		if event.dueTicks > targetTicks then
			break
		end

		pop(self._heap)
		self._isPending[event] = nil
		self._nowTicks         = event.dueTicks
		event.run()
	end

	self._nowTicks = targetTicks
end


--[=[
	Cancels a timer that has not fallen due.

	@param handle the handle that `delay` gave; one that has fired or been cancelled is left alone
]=]
function Timeline.cancel(self: Timeline, handle: Handle): ()
	cancel(self, handle)
end


--[=[
	Returns the record that Lync takes as its `clock` seam.

	@return the same record on every call, whose functions work on this timeline
]=]
function Timeline.clock(self: Timeline): Clock
	local existing = self._clock
	if existing ~= nil then
		return existing
	end

	local clock: Clock = {
		now    = function(): number
			return now(self)
		end,
		delay  = function<TArgs...>(
			seconds:  number,
			callback: (TArgs...) -> (),
			...:      TArgs...
		): Handle
			if not isDuration(seconds) then
				error(`seconds must be a finite number of 0 or more, got {seconds}`, 2)
			end

			return delay(self, seconds, callback, ...)
		end,
		cancel = function(handle: Handle): ()
			cancel(self, handle)
		end,
		frame  = self._frame,
	}

	self._clock = clock

	return clock
end


--[=[
	Schedules a callback to run after some virtual time, as `task.delay` does after real time.

	@param  seconds  how long to wait in seconds, 0 or more; 0 runs in the next `advance`
	@param  callback what to call when the time comes
	@param  ...      the arguments to call it with
	@return the handle that cancels the timer
	@error  when `seconds` is not a finite number of 0 or more
]=]
function Timeline.delay<TArgs...>(
	self:     Timeline,
	seconds:  number,
	callback: (TArgs...) -> (),
	...:      TArgs...
): Handle
	if not isDuration(seconds) then
		error(`seconds must be a finite number of 0 or more, got {seconds}`, 2)
	end

	return delay(self, seconds, callback, ...)
end


--[=[
	Tells whether `seconds` can be a delay or a duration.

	@param  seconds the number to test
	@return true when `seconds` is a finite number of 0 or more
]=]
function Timeline.isDuration(seconds: number): boolean
	return isDuration(seconds)
end


--[=[
	Returns the virtual time.

	@return seconds since the timeline was created, moved only by `advance`
]=]
function Timeline.now(self: Timeline): number
	return now(self)
end


--[=[
	Counts the timers that have not fired and have not been cancelled.

	@return how many timers are waiting, not counting frames
]=]
function Timeline.pendingCount(self: Timeline): number
	return self._pendingCount
end


return table.freeze(Timeline)
