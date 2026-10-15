--!strict

--[=[
	Recorder

	Captures what a test body causes besides its assertions: the observer events a test hands it,
	the output that Lync prints, and the errors that no code caught. It then says which of the last
	two the test did not claim.

	Output and faults arrive through two signals that the runner gives it, `LogService.MessageOut`
	and `ScriptContext.Error` in the engine, so that a test of the recorder can fire stand-ins.
	Only output that begins with Lync's marker `[Lync] `, after any position the engine put before
	it, counts as Lync's. A test declares such output with `check:expectOutput(pattern)`, and
	claims an uncaught error with `world:expectFault(pattern)`. Anything not claimed is a problem,
	so Lync is silent in normal operation and no error passes unseen.

	The engine echoes an uncaught error to Output as well. An echo of a claimed error is claimed
	with it, so a test does not declare the same moment twice.

	A pattern is a Lua pattern. A claim that nothing matches is not a problem.

	One recorder at a time is the current one, from `start` to `destroy`. That is how a world finds
	the recorder of the test that is running.

	Nothing here yields.
]=]


-- Imports -----------------------------------------------------------------------------------------

local Check  = require("./Check")
local Signal = require("./Signal")


-- Module ------------------------------------------------------------------------------------------

local Recorder   = {}
Recorder.__index = Recorder


-- Types -------------------------------------------------------------------------------------------

type Hearing<TArgs...> = {
	Connect: (self: any, listener: (TArgs...) -> ()) -> Signal.Connection,
}


type Phase =
	| "Idle"
	| "Recording"
	| "Destroyed"


type ProblemKind =
	| "UnclaimedFault"
	| "UnclaimedOutput"
	| "BadPattern"


--[=[
	The two signals that a recorder listens to.

	@field output fires each line of Output: its text, its kind and its context
	@field faults fires each uncaught error: its message, its traceback and the script it came from
]=]
export type Sources = {
	read output: Hearing<string, unknown, unknown>,
	read faults: Hearing<string, string, unknown>,
}


--[=[
	An error that no code caught.

	@field message   the error's text, with its position
	@field traceback the stack where it was raised
]=]
export type Fault = {
	read message:   string,
	read traceback: string,
}


--[=[
	Something a test did that it did not claim.

	@field kind      an unclaimed error, unclaimed Lync output, or a pattern that is not a pattern
	@field message   what the test must have done, and what it got instead
	@field traceback the stack of an uncaught error, nil for the other kinds
]=]
export type Problem = {
	read kind:      ProblemKind,
	read message:   string,
	read traceback: string?,
}


type Fields = {
	read events:         { Check.Event },
	read _sources:       Sources,
	read _outputs:       { string },
	read _faults:        { Fault },
	read _faultPatterns: { string },
	read _connections:   { Signal.Connection },

	_phase:              Phase,
}


--- What a test body leaves behind: its events, Lync's output and the errors nobody caught.
export type Recorder = setmetatable<Fields, typeof(Recorder)>


-- Constants ---------------------------------------------------------------------------------------

--- The text that begins every message that Lync prints or throws.
const MARKER = "[Lync] "


--- Matches the position that the engine puts before an error's text: a chunk, a line and a colon.
const POSITION_PATTERN = "^%S+:%d+: "


--- The longest text that a message shows whole; a longer text is cut and its remainder counted.
const MAX_SHOWN_BYTES = 200


-- State -------------------------------------------------------------------------------------------

--- The recorder that is recording, which a world finds with `current`.
local currentRecorder: Recorder? = nil


-- Private -----------------------------------------------------------------------------------------

local function isPattern(pattern: string): boolean
	local ok = pcall(string.find, "", pattern, 1, false)

	return ok
end


local function isLyncOutput(message: string): boolean
	local markerLength = #MARKER
	if string.sub(message, 1, markerLength) == MARKER then
		return true
	end

	local position = string.match(message, POSITION_PATTERN)
	if position == nil then
		return false
	end

	local start = #position + 1

	return string.sub(message, start, start + markerLength - 1) == MARKER
end


local function shown(text: string): string
	if #text <= MAX_SHOWN_BYTES then
		return `"{text}"`
	end

	local cut         = string.sub(text, 1, MAX_SHOWN_BYTES)
	local hiddenCount = #text - MAX_SHOWN_BYTES

	return `"{cut}"+{hiddenCount}`
end


local function isMatchedByAny(message: string, patterns: { string }): boolean
	for _, pattern in patterns do
		if string.find(message, pattern) ~= nil then
			return true
		end
	end

	return false
end


local function isEchoOfAny(output: string, faults: { Fault }): boolean
	for _, fault in faults do
		if string.find(output, fault.message, 1, true) ~= nil then
			return true
		end
	end

	return false
end


local function problemOf(kind: ProblemKind, message: string, traceback: string?): Problem
	return {
		kind      = kind,
		message   = message,
		traceback = traceback,
	}
end


local function claimedFaultsOf(self: Recorder): { Fault }
	local claimed: { Fault } = {}
	for _, fault in self._faults do
		if isMatchedByAny(fault.message, self._faultPatterns) then
			table.insert(claimed, fault)
		end
	end

	return claimed
end


-- Handlers ----------------------------------------------------------------------------------------

local function onOutput(self: Recorder, message: string): ()
	if isLyncOutput(message) then
		table.insert(self._outputs, message)
	end
end


local function onFault(self: Recorder, message: string, traceback: string): ()
	table.insert(self._faults, { message = message, traceback = traceback })
end


-- Public ------------------------------------------------------------------------------------------

--[=[
	Creates a recorder that has captured nothing and listens to nothing yet.

	@param  sources the signals of Output and of uncaught errors, which `start` listens to
	@return an idle recorder
]=]
function Recorder.new(sources: Sources): Recorder
	return setmetatable({
		events         = {},
		_sources       = sources,
		_outputs       = {},
		_faults        = {},
		_faultPatterns = {},
		_connections   = {},
		_phase         = "Idle",
	}, Recorder)
end


--[=[
	Claims every uncaught error whose message matches `pattern`, so that it does not fail the test.

	@param pattern the Lua pattern that the claimed errors' messages match, not empty
	@error when `pattern` is empty or is not a Lua pattern
]=]
function Recorder.claimFault(self: Recorder, pattern: string): ()
	if pattern == "" then
		error('pattern must not be empty, got ""', 2)
	end

	if not isPattern(pattern) then
		error(`pattern must be a valid Lua pattern, got "{pattern}"`, 2)
	end

	table.insert(self._faultPatterns, pattern)
end


--[=[
	Returns the recorder that is recording.

	@return the recorder between its `start` and its `destroy`, nil when none is
]=]
function Recorder.current(): Recorder?
	return currentRecorder
end


--[=[
	Returns the uncaught errors captured so far.

	@return the errors in the order they came, as a copy
]=]
function Recorder.faults(self: Recorder): { Fault }
	return table.clone(self._faults)
end


--[=[
	Tells whether `pattern` is a Lua pattern, as far as a search of an empty text can tell.

	@param  pattern the text to test
	@return false when that search raises, as it does for `%` at the end or an unclosed `[`
]=]
function Recorder.isPattern(pattern: string): boolean
	return isPattern(pattern)
end


--[=[
	Returns a function that records the observer events it is given, to pass to `Lync.observe`.

	@return the function, which appends each event to `events`
]=]
function Recorder.observer(self: Recorder): (event: Check.Event) -> ()
	return function(event: Check.Event): ()
		table.insert(self.events, event)
	end
end


--[=[
	Returns the Lync output captured so far.

	@return the lines of Output that began with Lync's marker, in order, as a copy
]=]
function Recorder.outputs(self: Recorder): { string }
	return table.clone(self._outputs)
end


--[=[
	Lists what the test did not claim: uncaught errors, then Lync output.

	An error is claimed by a pattern given to `claimFault`. A line of output is claimed by one of
	`outputPatterns`, or by being the engine's echo of a claimed error.

	@param  outputPatterns the Lua patterns that the test declared with `check:expectOutput`
	@return a problem for each unclaimed error, line and bad pattern; none if all was claimed
]=]
function Recorder.problems(self: Recorder, outputPatterns: { string }): { Problem }
	local problems: { Problem } = {}
	for _, fault in self._faults do
		if isMatchedByAny(fault.message, self._faultPatterns) then
			continue
		end

		local requirement = "test must claim an uncaught error with world:expectFault"
		local message     = `{requirement}, got {shown(fault.message)}`
		table.insert(problems, problemOf("UnclaimedFault", message, fault.traceback))
	end

	local usablePatterns: { string } = {}
	for _, pattern in outputPatterns do
		if isPattern(pattern) then
			table.insert(usablePatterns, pattern)
			continue
		end

		local requirement = "check:expectOutput pattern must be a valid Lua pattern"
		local message     = `{requirement}, got {shown(pattern)}`
		table.insert(problems, problemOf("BadPattern", message, nil))
	end

	local claimedFaults = claimedFaultsOf(self)
	for _, output in self._outputs do
		if isMatchedByAny(output, usablePatterns) then
			continue
		end

		if isEchoOfAny(output, claimedFaults) then
			continue
		end

		local requirement = "test must declare the Lync output it causes with check:expectOutput"
		local message     = `{requirement}, got {shown(output)}`
		table.insert(problems, problemOf("UnclaimedOutput", message, nil))
	end

	return problems
end


--[=[
	Starts listening to Output and to uncaught errors, and becomes the current recorder.

	@error when this recorder has started before
	@error when another recorder is the current one
]=]
function Recorder.start(self: Recorder): ()
	if self._phase ~= "Idle" then
		error(`recorder must be idle to start, got {self._phase}`, 2)
	end

	if currentRecorder ~= nil then
		error("recorder must start while no other recorder is recording, got one", 2)
	end

	local output = self._sources.output
	local faults = self._sources.faults

	table.insert(self._connections, output:Connect(function(message: string): ()
		onOutput(self, message)
	end))

	table.insert(self._connections, faults:Connect(function(message: string, traceback: string): ()
		onFault(self, message, traceback)
	end))

	self._phase     = "Recording"
	currentRecorder = self
end


--[=[
	Stops listening and, if this recorder is the current one, makes no recorder current.

	What the recorder captured stays readable. Repeating `destroy` does nothing.
]=]
function Recorder.destroy(self: Recorder): ()
	for _, connection in self._connections do
		connection:Disconnect()
	end

	table.clear(self._connections)

	if currentRecorder == self then
		currentRecorder = nil
	end

	self._phase = "Destroyed"
end


return table.freeze(Recorder)
