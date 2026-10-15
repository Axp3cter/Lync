--!strict

--[=[
	Reports

	The record of a run that the harness sends out, and its JSON text.

	A report has exactly the fields that `scripts/project/Reports.luau` reads: `kind`, `runId`,
	`buildId`, `seed`, `profile`, `filter`, `isComplete` and `outcomes`, each outcome with `id`,
	`dataModel`, `verdict`, `claims` and, for a test that did not pass, `failure`, or, for a test
	that was skipped, `reason`. Any other field of a value given to `build` is dropped, so the
	text is the schema and nothing else.

	The text is compact JSON in a fixed order of fields, and holds ASCII only: a character outside
	ASCII is written as a `\u` escape, and text that is not valid UTF-8 is read one byte to a
	character. The same report therefore always gives the same bytes, and those bytes are the same
	in UTF-8 and in any other encoding that agrees with ASCII.

	A NUL character is written as U+2400, the symbol for null, and never as `\u0000`, because the
	JSON reader that the terminal runs, `@std/json` of Lute 1.0.0, reads that escape as a backslash.

	A report holds one outcome for each test id and DataModel, so a test is named once in each
	DataModel it ran in.

	This module uses no engine global, so that the scripts may require it.
]=]


-- Imports -----------------------------------------------------------------------------------------

local Properties   = require("./Properties")
local RandomSource = require("./RandomSource")


-- Module ------------------------------------------------------------------------------------------

local Reports = {}


-- Types -------------------------------------------------------------------------------------------

--- What a report is about: a run of the tests, or of the benchmarks.
export type Kind =
	| "test"
	| "bench"


--- A profile as a report spells it, in lowercase.
export type ProfileWord = Properties.ProfileWord


--- How a test ended in one DataModel.
export type Verdict =
	| "Passed"
	| "Failed"
	| "Crashed"
	| "TimedOut"
	| "Skipped"


--[=[
	What one test did in one DataModel.

	@field id        the test's name, which names the test in the run
	@field dataModel the DataModel that ran it, such as "Server"
	@field verdict   how it ended
	@field claims    the ids of the claims it cites
	@field failure   what went wrong, nil for a test that passed or was skipped
	@field reason    why a test was skipped, nil for a test that ran
]=]
export type Outcome = {
	read id:        string,
	read dataModel: string,
	read verdict:   Verdict,
	read claims:    { read string },
	read failure:   string?,
	read reason:    string?,
}


--[=[
	A report of a run.

	@field kind       whether the run was of the tests or of the benchmarks
	@field runId      the run's name, 8 lowercase hexadecimal digits, the same on every copy of it
	@field buildId    the hash of the build that ran, which says whether reports are of one build
	@field seed       the seed that the run drew from, a whole number from 0 to 4294967295
	@field profile    how many cases the run drew, as a report spells it
	@field filter     the filter that narrowed the run, empty when every test ran
	@field isComplete whether every planned work item reported
	@field outcomes   what each test did in each DataModel
]=]
export type Report = {
	read kind:       Kind,
	read runId:      string,
	read buildId:    string,
	read seed:       number,
	read profile:    ProfileWord,
	read filter:     string,
	read isComplete: boolean,
	read outcomes:   { read Outcome },
}


--[=[
	What `build` needs to make a report.

	@field kind       whether the run was of the tests or of the benchmarks
	@field runId      the run's name, 8 lowercase hexadecimal digits
	@field buildId    the hash of the build that ran
	@field seed       the seed that the run drew from, a whole number from 0 to 4294967295
	@field profile    how many cases the run drew
	@field filter     the filter that narrowed the run, empty when every test ran
	@field isComplete whether every planned work item reported
	@field outcomes   what each test did in each DataModel
]=]
export type Options = {
	read kind:       Kind,
	read runId:      string,
	read buildId:    string,
	read seed:       number,
	read profile:    Properties.Profile,
	read filter:     string,
	read isComplete: boolean,
	read outcomes:   { read Outcome },
}


-- Constants ---------------------------------------------------------------------------------------

--- The number of hexadecimal digits in a run id.
const RUN_ID_LENGTH = 8


--- Matches text made only of digits and the letters "a" to "f" in lowercase.
const LOWERCASE_HEX_PATTERN = "^[0-9a-f]+$"


--- Matches a control, a quote, a backslash or a byte outside ASCII, which JSON text must escape.
const UNSAFE_PATTERN = '[%c"\\\x80-\xFF]'


--- The NUL character, and what the text writes in its place.
const NUL_CODE_POINT  = 0
const NUL_REPLACEMENT = "\\u2400"


--- The first code point that JSON writes as two surrogate escapes.
const SUPPLEMENTARY_START = 0x10000


--- The first code point of the high surrogates and of the low ones, in UTF-16.
const HIGH_SURROGATE_START = 0xD800
const LOW_SURROGATE_START  = 0xDC00


--- How many code points one surrogate covers.
const SURROGATE_SPAN = 0x400


--- The first and last code points of printable ASCII, which JSON text holds as they are.
const FIRST_PRINTABLE = 0x20
const LAST_PRINTABLE  = 0x7E


--- The short escape that JSON gives each code point that has one.
const ESCAPE_BY_CODE_POINT: { read [number]: string } = {
	[8]  = "\\b",
	[9]  = "\\t",
	[10] = "\\n",
	[12] = "\\f",
	[13] = "\\r",
	[34] = '\\"',
	[92] = "\\\\",
}
table.freeze(ESCAPE_BY_CODE_POINT)


-- Private -----------------------------------------------------------------------------------------

local function isRunId(text: string): boolean
	if #text ~= RUN_ID_LENGTH then
		return false
	end

	return string.find(text, LOWERCASE_HEX_PATTERN) ~= nil
end


local function escapeCodePoint(codePoint: number): string
	if codePoint == NUL_CODE_POINT then
		return NUL_REPLACEMENT
	end

	local escape = ESCAPE_BY_CODE_POINT[codePoint]
	if escape ~= nil then
		return escape
	end

	if codePoint >= FIRST_PRINTABLE and codePoint <= LAST_PRINTABLE then
		return string.char(codePoint)
	end

	if codePoint < SUPPLEMENTARY_START then
		return string.format("\\u%04x", codePoint)
	end

	local offset = codePoint - SUPPLEMENTARY_START
	local high   = HIGH_SURROGATE_START + offset // SURROGATE_SPAN
	local low    = LOW_SURROGATE_START + offset % SURROGATE_SPAN

	return string.format("\\u%04x\\u%04x", high, low)
end


local function escapeText(text: string): string
	local parts: { string } = {}
	if utf8.len(text) == nil then
		for i = 1, #text do
			local byte = string.byte(text, i)
			table.insert(parts, escapeCodePoint(byte))
		end

		return table.concat(parts)
	end

	for _, codePoint in utf8.codes(text) do
		table.insert(parts, escapeCodePoint(codePoint))
	end

	return table.concat(parts)
end


local function quote(text: string): string
	if string.find(text, UNSAFE_PATTERN) == nil then
		return `"{text}"`
	end

	local escaped = escapeText(text)

	return `"{escaped}"`
end


local function jsonOfClaims(claims: { read string }): string
	local quoted = table.create(#claims) :: { string }
	for i, claim in claims do
		quoted[i] = quote(claim)
	end

	local joined = table.concat(quoted, ",")

	return `[{joined}]`
end


local function jsonOfOutcome(outcome: Outcome): string
	local id        = quote(outcome.id)
	local dataModel = quote(outcome.dataModel)
	local verdict   = quote(outcome.verdict)
	local claims    = jsonOfClaims(outcome.claims)

	local fields = {
		`"id":{id}`,
		`"dataModel":{dataModel}`,
		`"verdict":{verdict}`,
		`"claims":{claims}`,
	}

	if outcome.failure ~= nil then
		local failure = quote(outcome.failure)
		table.insert(fields, `"failure":{failure}`)
	end

	if outcome.reason ~= nil then
		local reason = quote(outcome.reason)
		table.insert(fields, `"reason":{reason}`)
	end

	local joined = table.concat(fields, ",")

	return `\{{joined}}`
end


local function copyOutcome(outcome: Outcome): Outcome
	return table.freeze({
		id        = outcome.id,
		dataModel = outcome.dataModel,
		verdict   = outcome.verdict,
		claims    = table.freeze(table.clone(outcome.claims)),
		failure   = outcome.failure,
		reason    = outcome.reason,
	})
end


-- Public ------------------------------------------------------------------------------------------

--[=[
	Makes a report of a run, keeping only the fields of the schema.

	The outcomes are copied, so a later change to them does not change the report.

	@param  options what the report holds
	@return the report, frozen
	@error  when `options.runId` is not 8 lowercase hexadecimal digits
	@error  when `options.seed` is not a whole number from 0 to 4294967295
	@error  when two outcomes have the same test id and DataModel
]=]
function Reports.build(options: Options): Report
	if not isRunId(options.runId) then
		local requirement = `runId must be {RUN_ID_LENGTH} lowercase hexadecimal digits`
		error(`{requirement}, got "{options.runId}"`, 2)
	end

	if not RandomSource.isWord(options.seed) then
		local requirement = `seed must be a whole number from 0 to {RandomSource.MAX_WORD}`
		error(`{requirement}, got {options.seed}`, 2)
	end

	local outcomes                               = table.create(#options.outcomes) :: { Outcome }
	local seen: { [string]: { [string]: true } } = {}
	for i, outcome in options.outcomes do
		local seenIn = seen[outcome.id]
		if seenIn == nil then
			seenIn           = {}
			seen[outcome.id] = seenIn
		end

		if seenIn[outcome.dataModel] then
			local requirement = "outcomes must hold one outcome for each test id and DataModel"
			error(`{requirement}, got "{outcome.id}" in {outcome.dataModel} twice`, 2)
		end

		seenIn[outcome.dataModel] = true

		outcomes[i] = copyOutcome(outcome)
	end

	return table.freeze({
		kind       = options.kind,
		runId      = options.runId,
		buildId    = options.buildId,
		seed       = options.seed,
		profile    = Properties.wordOf(options.profile),
		filter     = options.filter,
		isComplete = options.isComplete,
		outcomes   = table.freeze(outcomes),
	})
end


--[=[
	Tells whether `text` can be the id of a run.

	@param  text the text to test
	@return true when `text` is 8 lowercase hexadecimal digits
]=]
function Reports.isRunId(text: string): boolean
	return isRunId(text)
end


--[=[
	Returns the run id that spells a 32-bit word in hexadecimal.

	@param  word the word to spell, such as one drawn from a source of entropy
	@return the 8 lowercase hexadecimal digits of `word`
	@error  when `word` is not a whole number from 0 to 4294967295
]=]
function Reports.runIdOf(word: number): string
	if not RandomSource.isWord(word) then
		local requirement = `word must be a whole number from 0 to {RandomSource.MAX_WORD}`
		error(`{requirement}, got {word}`, 2)
	end

	return string.format("%08x", word)
end


--[=[
	Writes a report as compact JSON text.

	The fields come in the order of the schema: `kind`, `runId`, `buildId`, `seed`, `profile`,
	`filter`, `isComplete` and `outcomes`, and in each outcome `id`, `dataModel`, `verdict` and
	`claims`, then `failure` and then `reason`, each only when the outcome has one. Every character
	outside printable ASCII is escaped, so the text is the same on every host.

	@param  report the report to write
	@return the JSON text of `report`
]=]
function Reports.toJson(report: Report): string
	local outcomeTexts = table.create(#report.outcomes) :: { string }
	for i, outcome in report.outcomes do
		outcomeTexts[i] = jsonOfOutcome(outcome)
	end

	local kind       = quote(report.kind)
	local runId      = quote(report.runId)
	local buildId    = quote(report.buildId)
	local profile    = quote(report.profile)
	local filter     = quote(report.filter)
	local outcomes   = table.concat(outcomeTexts, ",")
	local isComplete = if report.isComplete then "true" else "false"

	local fields = {
		`"kind":{kind}`,
		`"runId":{runId}`,
		`"buildId":{buildId}`,
		`"seed":{string.format("%d", report.seed)}`,
		`"profile":{profile}`,
		`"filter":{filter}`,
		`"isComplete":{isComplete}`,
		`"outcomes":[{outcomes}]`,
	}

	local joined = table.concat(fields, ",")

	return `\{{joined}}`
end


return table.freeze(Reports)
