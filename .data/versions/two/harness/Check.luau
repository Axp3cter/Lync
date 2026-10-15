--!strict

--[=[
	Check

	The assertions that a test body is given, and the record of how its assertions went.

	An assertion that does not hold records a failure on its check and throws the failure's message
	at the line in the test that made the assertion. A runner reads the failure back from the check,
	which tells a failed assertion from any other error without a thrown table.

	A check also keeps the golden values that did not match, for tooling to write as updates, and
	the output patterns that the test declared.

	Nothing here yields except `throws`, which takes the time of the action it runs.
]=]


-- Module ------------------------------------------------------------------------------------------

local Check   = {}
Check.__index = Check


-- Types -------------------------------------------------------------------------------------------

type Entries = { read [unknown]: unknown }

type ExpectedByActual = { [unknown]: unknown }


--[=[
	One assertion that did not hold, as its check recorded it.

	@field message   what the assertion required and what it got, without a position
	@field traceback the stack at the assertion, starting at the line in the test that made it
]=]
export type Failure = {
	read message:   string,
	read traceback: string,
}


--[=[
	A value that a golden assertion could not match, as the test produced it.

	@field name  the name the test gave the golden
	@field value the value the test produced, which tooling can store as the golden
]=]
export type GoldenCandidate = {
	read name:  string,
	read value: unknown,
}


--- An observer event as a recorder holds it: a frozen table with a `kind` and that kind's fields.
export type Event = { read [string]: unknown }


--[=[
	The part of a recorder that assertions read.

	@field events the observer events the recorder captured, oldest first
]=]
export type Recording = {
	read events: { read Event },
}


--[=[
	What `throws` requires of the text of a thrown error.

	@field subject the user's own name for what the message is about, such as `Chat:fire`
	@field path    the path into the value that the message names, nil when it names none
]=]
export type Expectation = {
	read subject: string,
	read path:    string?,
}


type Fields = {
	read _goldens:        { read [string]: unknown },
	read _chunkName:      string,

	read _candidates:     { GoldenCandidate },
	read _failures:       { Failure },
	read _outputPatterns: { string },
}


--- The assertions of one test body and the record of how they went.
export type Check = setmetatable<Fields, typeof(Check)>


-- Constants ---------------------------------------------------------------------------------------

--- The longest text that a message shows whole; a longer text is cut and its remainder counted.
const MAX_SHOWN_BYTES = 200


--- How many bytes of a buffer a message shows from its start.
const BUFFER_PREVIEW_BYTES = 8


--- How many bytes a message shows on each side of the first differing byte.
const WINDOW_RADIUS_BYTES = 6


--- How many event kinds a message lists when it reports what a recording held.
const MAX_LISTED_KINDS = 8


--- Matches the text that can follow a dot in a path: letters, digits and underscores.
const IDENTIFIER_PATTERN = "^[%a_][%w_]*$"


--- Matches one control character, such as a newline, which a message shows escaped.
const CONTROL_PATTERN = "%c"


--- Matches the line number and the colon after it in a position, and captures the text after them.
const LINE_TEXT_PATTERN = "^%d+: (.*)$"


--- Prints a number with enough digits to read back as the same number.
const ROUND_TRIP_FORMAT = "%.17g"


-- Private -----------------------------------------------------------------------------------------

local differenceBetween: (
	actual:           unknown,
	expected:         unknown,
	path:             string,
	expectedByActual: ExpectedByActual
) -> string?


local function isNegativeZero(value: number): boolean
	if value ~= 0 then
		return false
	end

	return 1 / value < 0
end


-- NaN equals NaN and -0 differs from 0, because the wire writes each of those as different bits.
local function isSameNumber(left: number, right: number): boolean
	if math.isnan(left) then
		return math.isnan(right)
	end

	if left ~= right then
		return false
	end

	return isNegativeZero(left) == isNegativeZero(right)
end


local function byteText(bytes: buffer, offset: number): string
	return string.format("%02X", buffer.readu8(bytes, offset))
end


local function escapeControl(character: string): string
	return string.format("\\x%02X", string.byte(character))
end


local function showText(text: string): string
	local shown   = string.sub(text, 1, MAX_SHOWN_BYTES)
	local escaped = string.gsub(shown, CONTROL_PATTERN, escapeControl)
	if #text > MAX_SHOWN_BYTES then
		local hiddenCount = #text - MAX_SHOWN_BYTES
		return `"{escaped}"+{hiddenCount}`
	end

	return `"{escaped}"`
end


-- A number is shown with as many digits as it takes to read back as the same number.
local function showNumber(value: number): string
	if math.isnan(value) then
		return "nan"
	end

	if isNegativeZero(value) then
		return "-0"
	end

	local text = tostring(value)
	if tonumber(text) == value then
		return text
	end

	return string.format(ROUND_TRIP_FORMAT, value)
end


local function showBuffer(bytes: buffer): string
	local sizeBytes  = buffer.len(bytes)
	local shownCount = math.min(sizeBytes, BUFFER_PREVIEW_BYTES)
	local byteTexts  = table.create(shownCount) :: { string }
	for i = 1, shownCount do
		byteTexts[i] = byteText(bytes, i - 1)
	end

	local ending = if sizeBytes > shownCount then " ..." else ""

	return `buffer({sizeBytes}) {table.concat(byteTexts, " ")}{ending}`
end


-- The datatypes that a codec rounds, as the numbers their members name in order.
local function componentsOf(value: unknown): { number }?
	if typeof(value) == "vector" then
		return {
			value.x,
			value.y,
			value.z,
		}
	end

	if typeof(value) == "Vector2" then
		return { value.X, value.Y }
	end

	if typeof(value) == "Vector3" then
		return {
			value.X,
			value.Y,
			value.Z,
		}
	end

	if typeof(value) == "Color3" then
		return {
			value.R,
			value.G,
			value.B,
		}
	end

	if typeof(value) == "CFrame" then
		return { value:GetComponents() }
	end

	return nil
end


local function show(value: unknown): string
	if typeof(value) == "string" then
		return showText(value)
	end

	if typeof(value) == "number" then
		return showNumber(value)
	end

	if typeof(value) == "buffer" then
		return showBuffer(value)
	end

	local components = componentsOf(value)
	if components ~= nil then
		return `{typeof(value)}({table.concat(components, ", ")})`
	end

	-- These print as an address, which differs from run to run.
	local kind = typeof(value)
	if
		kind == "table"
		or kind == "function"
		or kind == "thread"
	then
		return kind
	end

	return tostring(value)
end


local function childPath(path: string, key: unknown): string
	if typeof(key) == "number" then
		return `{path}[{showNumber(key)}]`
	end

	if typeof(key) ~= "string" then
		return `{path}[{show(key)}]`
	end

	if string.find(key, IDENTIFIER_PATTERN) == nil then
		return `{path}[{showText(key)}]`
	end

	return `{path}.{key}`
end


-- Keys sort by the name of their type and then by value, so the first difference that a message
-- names does not depend on the order in which the engine happens to traverse a table.
local function isKeyBefore(left: unknown, right: unknown): boolean
	if typeof(left) ~= typeof(right) then
		return typeof(left) < typeof(right)
	end

	if
		typeof(left) == "number"
		and typeof(right) == "number"
	then
		return left < right
	end

	return tostring(left) < tostring(right)
end


local function sortedKeysOf(first: Entries, second: Entries): { unknown }
	local uniqueKeys: { [unknown]: true } = {}
	for key in first do
		uniqueKeys[key] = true
	end

	for key in second do
		uniqueKeys[key] = true
	end

	local sortedKeys: { unknown } = {}
	for key in uniqueKeys do
		table.insert(sortedKeys, key)
	end

	table.sort(sortedKeys, isKeyBefore)

	return sortedKeys
end


local function mismatch(path: string, actual: unknown, expected: unknown): string
	return `{path} must equal {show(expected)}, got {show(actual)}`
end


local function windowOf(bytes: buffer, offset: number): string
	local sizeBytes = buffer.len(bytes)
	local first     = math.max(0, offset - WINDOW_RADIUS_BYTES)
	local last      = math.min(sizeBytes - 1, offset + WINDOW_RADIUS_BYTES)

	local byteTexts: { string } = {}
	for i = first, last do
		local text   = byteText(bytes, i)
		local marked = if i == offset then `[{text}]` else text
		table.insert(byteTexts, marked)
	end

	if offset >= sizeBytes then
		table.insert(byteTexts, "[end]")
	end

	return table.concat(byteTexts, " ")
end


-- The offset where the buffers first differ, which is the end of the shorter one when it is a
-- prefix of the other.
local function firstDifferingOffset(left: buffer, right: buffer): number?
	local leftSizeBytes   = buffer.len(left)
	local rightSizeBytes  = buffer.len(right)
	local commonSizeBytes = math.min(leftSizeBytes, rightSizeBytes)
	for offset = 0, commonSizeBytes - 1 do
		if buffer.readu8(left, offset) ~= buffer.readu8(right, offset) then
			return offset
		end
	end

	if leftSizeBytes ~= rightSizeBytes then
		return commonSizeBytes
	end

	return nil
end


local function sizeText(byteCount: number): string
	local noun = if byteCount == 1 then "byte" else "bytes"
	return `{byteCount} {noun}`
end


local function bytesDifference(actual: buffer, expected: buffer, path: string): string?
	local offset = firstDifferingOffset(actual, expected)
	if offset == nil then
		return nil
	end

	local expectedSizeBytes = buffer.len(expected)
	local actualSizeBytes   = buffer.len(actual)
	local requirement       = `equal {sizeText(expectedSizeBytes)}`
	local actualText        = `{sizeText(actualSizeBytes)}, differing at byte {offset}`
	local actualWindow      = windowOf(actual, offset)
	local expectedText      = windowOf(expected, offset)

	return `{path} must {requirement}, got {actualText}: {actualWindow}, expected {expectedText}`
end


local function tableDifference(
	actual:           Entries,
	expected:         Entries,
	path:             string,
	expectedByActual: ExpectedByActual
): string?
	if expectedByActual[actual] == expected then
		return nil
	end

	expectedByActual[actual] = expected

	for _, key in sortedKeysOf(actual, expected) do
		local keyPath       = childPath(path, key)
		local actualValue   = actual[key]
		local expectedValue = expected[key]
		if expectedValue == nil then
			return `{keyPath} must be absent, got {show(actualValue)}`
		end

		if actualValue == nil then
			return `{keyPath} must equal {show(expectedValue)}, got nothing`
		end

		local difference = differenceBetween(actualValue, expectedValue, keyPath, expectedByActual)
		if difference ~= nil then
			return difference
		end
	end

	return nil
end


--[=[
	Finds the first difference between two values, as a sentence in the requirement mold.

	A pair of tables that is already being compared higher up counts as equal, which ends a cycle.

	@param  actual           the value the code under test produced
	@param  expected         the value it should equal
	@param  path             the path to the two values, which opens the sentence
	@param  expectedByActual the pairs of tables being compared, which is how a cycle ends
	@return the sentence, nil when the two values are equal
]=]
function differenceBetween(
	actual:           unknown,
	expected:         unknown,
	path:             string,
	expectedByActual: ExpectedByActual
): string?
	if typeof(actual) ~= typeof(expected) then
		return mismatch(path, actual, expected)
	end

	if
		typeof(actual) == "number"
		and typeof(expected) == "number"
	then
		if isSameNumber(actual, expected) then
			return nil
		end

		return mismatch(path, actual, expected)
	end

	if
		typeof(actual) == "buffer"
		and typeof(expected) == "buffer"
	then
		return bytesDifference(actual, expected, path)
	end

	local actualComponents   = componentsOf(actual)
	local expectedComponents = componentsOf(expected)
	if
		actualComponents ~= nil
		and expectedComponents ~= nil
	then
		for i, component in actualComponents do
			if not isSameNumber(component, expectedComponents[i]) then
				return mismatch(path, actual, expected)
			end
		end

		return nil
	end

	if
		typeof(actual) == "table"
		and typeof(expected) == "table"
	then
		-- The test narrows only to the opaque `table`, which nothing can index, so the entries stay
		-- unknown.
		local actualEntries   = actual :: Entries
		local expectedEntries = expected :: Entries
		return tableDifference(actualEntries, expectedEntries, path, expectedByActual)
	end

	if actual == expected then
		return nil
	end

	return mismatch(path, actual, expected)
end


local function isBoundary(character: string): boolean
	return character == "" or character == " "
end


-- A name counts as named only when it stands alone between spaces or at an end of the text, so
-- `value.items[3]` is not found in `value.items[3].count`.
local function hasSubject(text: string, subject: string): boolean
	local subjectLength = #subject
	local first         = string.find(text, subject, 1, true)
	while first ~= nil do
		local afterOffset = first + subjectLength
		local before      = string.sub(text, first - 1, first - 1)
		local after       = string.sub(text, afterOffset, afterOffset)
		if
			isBoundary(before)
			and isBoundary(after)
		then
			return true
		end

		first = string.find(text, subject, first + 1, true)
	end

	return false
end


local function hasPosition(thrown: string, chunkName: string): boolean
	local prefix       = `{chunkName}:`
	local prefixLength = #prefix
	if string.sub(thrown, 1, prefixLength) ~= prefix then
		return false
	end

	local rest = string.sub(thrown, prefixLength + 1)

	return string.match(rest, LINE_TEXT_PATTERN) ~= nil
end


local function stripPosition(thrown: string, chunkName: string): string
	local prefixLength = #chunkName + 1
	local rest         = string.sub(thrown, prefixLength + 1)

	return string.match(rest, LINE_TEXT_PATTERN) or rest
end


local function problemWithThrow(
	chunkName:   string,
	ok:          boolean,
	thrown:      unknown,
	expectation: Expectation
): string?
	if ok then
		return "action must throw, got a normal return"
	end

	if typeof(thrown) ~= "string" then
		return `thrown value must be a string, got {typeof(thrown)}`
	end

	if not hasPosition(thrown, chunkName) then
		return `thrown text must start with a position in {chunkName}, got {showText(thrown)}`
	end

	local path   = expectation.path
	local needle = if path == nil then expectation.subject else `{expectation.subject} {path}`
	local text   = stripPosition(thrown, chunkName)
	if not hasSubject(text, needle) then
		return `thrown text must name {showText(needle)}, got {showText(text)}`
	end

	return nil
end


local function isMatchingEvent(event: Event, expected: Event): boolean
	for key, value in expected do
		if differenceBetween(event[key], value, "event", {}) ~= nil then
			return false
		end
	end

	return true
end


local function indexOfEvent(events: { read Event }, expected: Event): number?
	for i, event in events do
		if isMatchingEvent(event, expected) then
			return i
		end
	end

	return nil
end


-- An event pattern names the kind of event it wants, and never the text of a message.
local function isEventPattern(expected: Event): boolean
	if typeof(expected.kind) ~= "string" then
		return false
	end

	return expected.message == nil
end


local function describeEvent(expected: Event): string
	local names: { string } = {}
	for name in expected do
		table.insert(names, name)
	end

	table.sort(names)

	local fields = table.create(#names) :: { string }
	for i, name in names do
		fields[i] = `{name} = {show(expected[name])}`
	end

	return `\{ {table.concat(fields, ", ")} }`
end


local function describeEvents(events: { read Event }): string
	local count = #events
	if count == 0 then
		return "no events"
	end

	local listedCount = math.min(count, MAX_LISTED_KINDS)
	local kinds       = table.create(listedCount) :: { string }
	for i = 1, listedCount do
		kinds[i] = tostring(events[i].kind)
	end

	local noun = if count == 1 then "event" else "events"
	local more = if count > listedCount then ", ..." else ""

	return `{count} {noun} of kind {table.concat(kinds, ", ")}{more}`
end


local function bytesOf(value: unknown): buffer?
	if typeof(value) == "buffer" then
		return value
	end

	if typeof(value) == "string" then
		return buffer.fromstring(value)
	end

	return nil
end


-- Strings and buffers are both bytes, so a golden stored as a string matches a buffer.
local function goldenDifference(subject: string, golden: unknown, value: unknown): string?
	if golden == nil then
		return `{subject} must be stored, got no value; the update candidate holds {show(value)}`
	end

	local actualBytes   = bytesOf(value)
	local expectedBytes = bytesOf(golden)
	if
		actualBytes ~= nil
		and expectedBytes ~= nil
	then
		return bytesDifference(actualBytes, expectedBytes, subject)
	end

	return differenceBetween(value, golden, subject, {})
end


local function record(self: Check, message: string, traceback: string): ()
	local failure = table.freeze({ message = message, traceback = traceback })
	table.insert(self._failures, failure)
end


-- Public ------------------------------------------------------------------------------------------

--[=[
	Creates the check for one test body.

	@param  chunkName the name Luau gives the test's own file, which its error positions begin with
	@param  goldens   the stored golden values of the test's suite, by name
	@return a check that has recorded nothing
]=]
function Check.new(chunkName: string, goldens: { read [string]: unknown }): Check
	return setmetatable({
		_goldens        = goldens,
		_chunkName      = chunkName,

		_candidates     = {},
		_failures       = {},
		_outputPatterns = {},
	}, Check)
end


--[=[
	Asserts that `actual` is within `tolerance` of `expected`.

	Two equal infinities are within any tolerance, and NaN is within none.

	@param actual    the number the code under test produced
	@param expected  the number it should be close to
	@param tolerance the largest distance allowed between them, finite and 0 or more
	@error when the two numbers are further apart than `tolerance`
	@error when `tolerance` is not finite and 0 or more
]=]
function Check.approximates(self: Check, actual: number, expected: number, tolerance: number): ()
	if
		not math.isfinite(tolerance)
		or tolerance < 0
	then
		error(`tolerance must be a finite number of 0 or more, got {showNumber(tolerance)}`, 2)
	end

	if actual == expected then
		return
	end

	if math.abs(actual - expected) <= tolerance then
		return
	end

	local requirement = `be within {showNumber(tolerance)} of {showNumber(expected)}`
	local message     = `actual must {requirement}, got {showNumber(actual)}`
	record(self, message, debug.traceback(nil, 2))
	error(message, 2)
end


--[=[
	Asserts that `actual` equals `expected` in structure.

	Tables are compared by their entries, so identity and metatables do not matter, and a table
	that holds itself is compared once. NaN equals NaN, -0 differs from 0, and buffers are compared
	byte by byte.

	Exactly five datatypes are compared component by component, each component by the number rules:
	`vector` (x, y, z), Vector2 (X, Y), Vector3 (X, Y, Z), Color3 (R, G, B) and CFrame (the 12
	numbers of `GetComponents`). Any other value is compared with `==`.

	@param actual   the value the code under test produced
	@param expected the value it should equal
	@error when the values differ, naming the path to the first difference
]=]
function Check.equals(self: Check, actual: unknown, expected: unknown): ()
	local difference = differenceBetween(actual, expected, "actual", {})
	if difference == nil then
		return
	end

	record(self, difference, debug.traceback(nil, 2))
	error(difference, 2)
end


--[=[
	Asserts that a recorder holds no event that matches `expected`.

	An event matches when every field that `expected` gives equals the event's field, so the
	fields that `expected` leaves out are not compared.

	@param recorder the recorder whose captured events are searched
	@param expected the `kind` of the event and any other fields it must have, never `message`
	@error when the recorder holds a matching event
	@error when `expected` has no `kind` that is a string, or gives a `message`
]=]
function Check.excludesEvent(self: Check, recorder: Recording, expected: Event): ()
	if not isEventPattern(expected) then
		error(`expected must have a string kind and no message, got {describeEvent(expected)}`, 2)
	end

	local position = indexOfEvent(recorder.events, expected)
	if position == nil then
		return
	end

	local requirement = `not include an event {describeEvent(expected)}`
	local message     = `recorder must {requirement}, got one at position {position}`
	record(self, message, debug.traceback(nil, 2))
	error(message, 2)
end


--[=[
	Declares that the test expects output that matches `pattern`.

	The runner, not this check, compares the output a test caused with the patterns declared.

	@param pattern the Lua pattern that the expected output matches, not empty
	@error when `pattern` is empty
]=]
function Check.expectOutput(self: Check, pattern: string): ()
	if pattern == "" then
		error('pattern must not be empty, got ""', 2)
	end

	table.insert(self._outputPatterns, pattern)
end


--[=[
	Returns the first assertion that did not hold on this check.

	@return the failure, nil when every assertion held
]=]
function Check.failure(self: Check): Failure?
	return self._failures[1]
end


--[=[
	Returns the values that golden assertions of this check could not match.

	@return a copy of the candidates, oldest first
]=]
function Check.goldenCandidates(self: Check): { GoldenCandidate }
	return table.clone(self._candidates)
end


--[=[
	Asserts that `condition` is true.

	@param condition what must hold
	@param message   what failed, as `subject must requirement, got value`
	@error when `condition` is false, with `message`
]=]
function Check.holds(self: Check, condition: boolean, message: string): ()
	if condition then
		return
	end

	record(self, message, debug.traceback(nil, 2))
	error(message, 2)
end


--[=[
	Asserts that a recorder holds an event that matches `expected`.

	An event matches when every field that `expected` gives equals the event's field, so the
	fields that `expected` leaves out are not compared.

	@param recorder the recorder whose captured events are searched
	@param expected the `kind` of the event and any other fields it must have, never `message`
	@error when the recorder holds no matching event
	@error when `expected` has no `kind` that is a string, or gives a `message`
]=]
function Check.includesEvent(self: Check, recorder: Recording, expected: Event): ()
	if not isEventPattern(expected) then
		error(`expected must have a string kind and no message, got {describeEvent(expected)}`, 2)
	end

	if indexOfEvent(recorder.events, expected) ~= nil then
		return
	end

	local requirement = `include an event {describeEvent(expected)}`
	local message     = `recorder must {requirement}, got {describeEvents(recorder.events)}`
	record(self, message, debug.traceback(nil, 2))
	error(message, 2)
end


--[=[
	Asserts that `value` equals the golden stored under `name`.

	A golden that is a string or a buffer matches a value that is a string or a buffer with the
	same bytes, and any other golden matches as `equals` matches. A mismatch, or a golden that is
	not stored, adds a candidate that holds `value`, and a mismatch between bytes names the first
	differing byte with the bytes around it.

	@param name  the name the golden is stored under
	@param value what the code under test produced
	@error when `value` differs from the golden, or no golden is stored under `name`
]=]
function Check.matchesGolden(self: Check, name: string, value: unknown): ()
	local golden     = self._goldens[name]
	local difference = goldenDifference(`golden {showText(name)}`, golden, value)
	if difference == nil then
		return
	end

	local candidate = { name = name, value = value }
	table.insert(self._candidates, candidate)
	record(self, difference, debug.traceback(nil, 2))
	error(difference, 2)
end


--[=[
	Returns the output patterns that the test declared with `expectOutput`.

	@return a copy of the patterns, in the order they were declared
]=]
function Check.outputPatterns(self: Check): { string }
	return table.clone(self._outputPatterns)
end


--[=[
	Asserts that `action` throws an error whose position is in the test's own file and whose text
	names `expectation`.

	The position shows that the error was raised at the line in the test that made the mistake.
	The subject and path are looked for as whole words in the text after the position, and the
	wording around them is never compared.

	An assertion that fails inside `action` is thrown again as it was.

	@param  action      the call that must throw
	@param  expectation the subject, and the path, that the thrown text must name
	@return the thrown text without its position
	@error  when `action` returns, or throws a value that is not a string
	@error  when the thrown text has no position in the test's file or does not name `expectation`
	@error  when `expectation.subject` is empty
]=]
function Check.throws(self: Check, action: () -> (), expectation: Expectation): string
	if expectation.subject == "" then
		error('expectation.subject must not be empty, got ""', 2)
	end

	local failureCount = #self._failures
	local ok, thrown   = pcall(action)
	if
		not ok
		and #self._failures > failureCount
	then
		error(thrown, 0)
	end

	local problem = problemWithThrow(self._chunkName, ok, thrown, expectation)
	if problem ~= nil then
		record(self, problem, debug.traceback(nil, 2))
		error(problem, 2)
	end

	return stripPosition(tostring(thrown), self._chunkName)
end


return table.freeze(Check)
