--!strict

--[=[
	Reports

	Reads a report that a Studio run sent back, and says where the claims stand after it.

	A report is a JSON object. Its header names the run: `kind` ("test" or "bench"), `runId`, which
	is 8 lowercase hexadecimal digits (H-60), `buildId`, `seed`, `profile` ("quick", "standard" or
	"deep"), `filter`, which is empty for a run of every test, and `isComplete`, whether every
	planned work item reported.

	Its `outcomes` list what each test did in each DataModel: `id`, `dataModel`, `verdict`
	("Passed", "Failed", "Crashed", "TimedOut" or "Skipped"), `claims`, the ids the test cites,
	`failure`, the text of what went wrong for a test that failed, crashed or timed out, and
	`reason`, why a test was skipped. A test is named once for each DataModel, so `id` and
	`dataModel` together are unique.

	Any other field is for people and is not read.

	After a run of every test that finished, a claim that a test proves is in one state. It is
	Failing when a test that cites it failed, crashed or timed out, Proved when one passed, Skipped
	when every one that cites it was skipped, and Untested when none cites it. A claim that is
	waived is Waived. A skipped test proves nothing.

	A run with a filter, or one that did not finish, proves nothing, so no claim has a state.

	A test that cites a claim that does not exist, is withdrawn, or is not proved by tests, is a
	problem. A claim that a file under `test/` cites but the report lacks is stale: the report was
	made by another build.

	The ruling on a report is Fail for a failing test or a problem, then Incomplete for a run that
	proves nothing, has stale claims, skipped a claim, or proved no claim, and otherwise Pass.

	Nothing here yields, because the operations reach nothing outside the process.

	A failure outside the scripts, such as a report that is not valid, comes back as a Result.
]=]


-- Imports -----------------------------------------------------------------------------------------

local Citations = require("./Citations")
local json      = require("@std/json")
local Paths     = require("./Paths")
local Spec      = require("./Spec")
local stringext = require("@std/stringext")
local Types     = require("../Types")


-- Module ------------------------------------------------------------------------------------------

local Reports = {}


-- Types -------------------------------------------------------------------------------------------

--- What a report is about: a run of the tests, or of the benchmarks.
type Kind =
	| "test"
	| "bench"


--- How many cases a run draws for each property, and how long it fuzzes.
type Profile =
	| "quick"
	| "standard"
	| "deep"


--- What one test did in one DataModel.
export type Verdict =
	| "Passed"
	| "Failed"
	| "Crashed"
	| "TimedOut"
	| "Skipped"


--- What a verdict does to the claims that its test cites: it proves them, fails them or skips them.
type Effect =
	| "Proves"
	| "Fails"
	| "Skips"


--- Where one claim stands after a run.
export type ClaimState =
	| "Proved"
	| "Failing"
	| "Untested"
	| "Skipped"
	| "Waived"


--- What a run comes to: a failure, a run that proved nothing yet, or a pass.
export type Ruling =
	| "Pass"
	| "Fail"
	| "Incomplete"


--[=[
	What one test did in one DataModel.

	@field id        the test's name, unique within the run together with `dataModel`
	@field dataModel the DataModel that ran it, such as "Server"
	@field verdict   how it ended
	@field claims    the ids of the claims it cites
	@field failure   what went wrong, nil for a test that did not fail, crash or time out
	@field reason    why the test was skipped, nil for a test that ran
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
	A report of a run, apart from the fields that are for people.

	@field kind       whether the run was of the tests or of the benchmarks
	@field runId      the run's name, 8 lowercase hexadecimal digits, the same on every copy of it
	@field buildId    the hash of the build that ran, which says whether reports are of one build
	@field seed       the seed that the run drew from
	@field profile    how many cases the run drew
	@field filter     the filter that narrowed the run, empty when every test ran
	@field isComplete whether every planned work item reported
	@field outcomes   what each test did in each DataModel
]=]
export type Report = {
	read kind:       Kind,
	read runId:      string,
	read buildId:    string,
	read seed:       number,
	read profile:    Profile,
	read filter:     string,
	read isComplete: boolean,
	read outcomes:   { read Outcome },
}


--[=[
	Where the claims stand after a report, and what the report comes to.

	@field claimsByState the claims by state, empty after a run that proves nothing
	@field failures      the outcomes that failed, crashed or timed out
	@field skips         the outcomes that were skipped, which carry their reasons
	@field problems      what is wrong with the report's citations, one finding each
	@field staleClaims   the claims that a file under `test/` cites and that the report lacks
	@field isFull        whether the run was of every test and finished
	@field ruling        what the run comes to
]=]
export type Standing = {
	read claimsByState: { read [ClaimState]: { Spec.Claim } },
	read failures:      { Outcome },
	read skips:         { Outcome },
	read problems:      { string },
	read staleClaims:   { Spec.Claim },
	read isFull:        boolean,
	read ruling:        Ruling,
}


-- Constants ---------------------------------------------------------------------------------------

--- Matches text made only of digits and the letters "a" to "f" in lowercase.
const LOWERCASE_HEX_PATTERN = "^[0-9a-f]+$"


--- The number of hexadecimal digits in a run id.
const RUN_ID_LENGTH = 8


--- Every state of a claim, in the order that the spec names them.
const CLAIM_STATES: { read ClaimState } = {
	"Proved",
	"Failing",
	"Untested",
	"Skipped",
	"Waived",
}
table.freeze(CLAIM_STATES)


--- The kind that each word in a report names.
const KIND_BY_WORD: { read [string]: Kind } = {
	test  = "test",
	bench = "bench",
}
table.freeze(KIND_BY_WORD)


--- The profile that each word in a report names.
const PROFILE_BY_WORD: { read [string]: Profile } = {
	quick    = "quick",
	standard = "standard",
	deep     = "deep",
}
table.freeze(PROFILE_BY_WORD)


--- The verdict that each word in a report names.
const VERDICT_BY_WORD: { read [string]: Verdict } = {
	Passed   = "Passed",
	Failed   = "Failed",
	Crashed  = "Crashed",
	TimedOut = "TimedOut",
	Skipped  = "Skipped",
}
table.freeze(VERDICT_BY_WORD)


--- What a test that ends with the verdict does to the claims that it cites.
const EFFECT_BY_VERDICT: Types.Complete<{ read [Verdict]: Effect }> = {
	Passed   = "Proves",

	Failed   = "Fails",
	Crashed  = "Fails",
	TimedOut = "Fails",

	Skipped  = "Skips",
}
table.freeze(EFFECT_BY_VERDICT)


-- Private -----------------------------------------------------------------------------------------

local function toText(value: unknown): string?
	if typeof(value) ~= "string" then
		return nil
	end

	return value
end


local function toNumber(value: unknown): number?
	if typeof(value) ~= "number" then
		return nil
	end

	return value
end


local function descriptionOf(value: unknown): string
	if typeof(value) == "string" then
		return `"{value}"`
	end

	return typeof(value)
end


local function toKind(value: unknown): Kind?
	local word = toText(value)
	if word == nil then
		return nil
	end

	return KIND_BY_WORD[word]
end


local function toProfile(value: unknown): Profile?
	local word = toText(value)
	if word == nil then
		return nil
	end

	return PROFILE_BY_WORD[word]
end


local function toRunId(value: unknown): string?
	local text = toText(value)
	if text == nil then
		return nil
	end

	if #text ~= RUN_ID_LENGTH then
		return nil
	end

	if string.find(text, LOWERCASE_HEX_PATTERN) == nil then
		return nil
	end

	return text
end


local function toBoolean(value: unknown): boolean?
	if typeof(value) ~= "boolean" then
		return nil
	end

	return value
end


--[=[
	Reads the claim ids that one outcome lists.

	@param  value    the JSON value of the outcome's `claims`
	@param  place    where the outcome is, which a problem names
	@param  problems where what is wrong with the list is reported
	@return the ids, empty when `value` is not a list of strings
]=]
local function readClaims(value: json.Value, place: string, problems: { string }): { string }
	local list = json.asArray(value)
	if list == nil then
		table.insert(problems, `{place}: claims must be a list of ids, got {typeof(value)}`)
		return {}
	end

	local claims: { string } = {}
	for _, item in list do
		local claimId = toText(item)
		if claimId == nil then
			table.insert(problems, `{place}: claims must hold only ids, got a {typeof(item)}`)
			continue
		end

		table.insert(claims, claimId)
	end

	return claims
end


--[=[
	Reads a field that a report may leave out, and that holds text when it is there.

	@param  object   the JSON object that may hold the field
	@param  key      the field's name
	@param  place    where the object is, which a problem names
	@param  problems where a field that holds something else is reported
	@return the text, nil when the field is absent or wrong
	@return whether the field is acceptable: absent, or text
]=]
local function readOptionalText(
	object:   json.Object,
	key:      string,
	place:    string,
	problems: { string }
): (string?, boolean)
	local value = object[key]
	if value == nil then
		return nil, true
	end

	local text = toText(value)
	if text == nil then
		local requirement = `{place}: {key} must be a string`
		table.insert(problems, `{requirement}, got {typeof(value)}`)
		return nil, false
	end

	return text, true
end


local function readOutcome(value: json.Value, index: number, problems: { string }): Outcome?
	local place  = `outcome {index}`
	local object = json.asObject(value)
	if object == nil then
		table.insert(problems, `{place} must be an object, got {typeof(value)}`)
		return nil
	end

	local id = toText(object.id)
	if id == nil then
		table.insert(problems, `{place}: id must be a string, got {typeof(object.id)}`)
		return nil
	end

	local dataModel = toText(object.dataModel)
	if dataModel == nil then
		local requirement = `{place} ({id}): dataModel must be a string`
		table.insert(problems, `{requirement}, got {typeof(object.dataModel)}`)
		return nil
	end

	local verdictWord = toText(object.verdict)
	if verdictWord == nil then
		local requirement = `{place} ({id}): verdict must be a string`
		table.insert(problems, `{requirement}, got {typeof(object.verdict)}`)
		return nil
	end

	local verdict = VERDICT_BY_WORD[verdictWord]
	if verdict == nil then
		table.insert(problems, `{place} ({id}): verdict must be a known one, got "{verdictWord}"`)
		return nil
	end

	local described = `{place} ({id})`

	local failure, isFailureAcceptable = readOptionalText(object, "failure", described, problems)
	local reason, isReasonAcceptable   = readOptionalText(object, "reason", described, problems)
	if
		not isFailureAcceptable
		or not isReasonAcceptable
	then
		return nil
	end

	return {
		id        = id,
		dataModel = dataModel,
		verdict   = verdict,
		claims    = readClaims(object.claims, described, problems),
		failure   = failure,
		reason    = reason,
	}
end


local function readOutcomes(value: json.Value, problems: { string }): { Outcome }
	local list = json.asArray(value)
	if list == nil then
		table.insert(problems, `outcomes must be a list, got {typeof(value)}`)
		return {}
	end

	local outcomes:         { Outcome }                        = {}
	local firstIndexesById: { [string]: { [string]: number } } = {}
	for i, item in list do
		local outcome = readOutcome(item, i, problems)
		if outcome == nil then
			continue
		end

		local firstIndexes = firstIndexesById[outcome.id]
		if firstIndexes == nil then
			firstIndexes                 = {}
			firstIndexesById[outcome.id] = firstIndexes
		end

		local firstIndex = firstIndexes[outcome.dataModel]
		if firstIndex ~= nil then
			local requirement = `outcome {i} ({outcome.id}): test must appear once for a DataModel`
			local repeated    = `"{outcome.dataModel}" again after outcome {firstIndex}`
			table.insert(problems, `{requirement}, got {repeated}`)
			continue
		end

		firstIndexes[outcome.dataModel] = i
		table.insert(outcomes, outcome)
	end

	return outcomes
end


--[=[
	Gathers the outcomes that cite each claim, and reports the citations that cannot prove anything.

	@param  report   the report whose outcomes are gathered
	@param  spec     the claims that an outcome may cite
	@param  problems where each citation that is dropped is reported
	@return the outcomes that cite each claim, by the claim's id
]=]
local function indexOutcomes(
	report:   Report,
	spec:     Spec.Contents,
	problems: { string }
): { [string]: { Outcome } }
	local outcomesByClaimId: { [string]: { Outcome } } = {}
	for _, outcome in report.outcomes do
		for _, claimId in outcome.claims do
			local claim = spec.claimById[claimId]
			if claim == nil then
				local requirement = `test {outcome.id} must cite a claim that exists`
				table.insert(problems, `{requirement}, got "{claimId}"`)
				continue
			end

			if claim.isWithdrawn then
				local requirement = `test {outcome.id} must not cite a withdrawn claim`
				table.insert(problems, `{requirement}, got {claimId}`)
				continue
			end

			if Spec.JUDGE_BY_KIND[claim.proofKind] ~= "Test" then
				local requirement = `test {outcome.id} must cite only claims that tests prove`
				table.insert(problems, `{requirement}, got {claimId}, a {claim.proofKind} claim`)
				continue
			end

			local outcomes = outcomesByClaimId[claimId]
			if outcomes == nil then
				outcomes                   = {}
				outcomesByClaimId[claimId] = outcomes
			end

			table.insert(outcomes, outcome)
		end
	end

	return outcomesByClaimId
end


local function stateOf(outcomes: { read Outcome }): ClaimState
	local passedCount  = 0
	local skippedCount = 0
	for _, outcome in outcomes do
		local effect = EFFECT_BY_VERDICT[outcome.verdict]
		if effect == "Fails" then
			return "Failing"
		elseif effect == "Proves" then
			passedCount += 1
		elseif effect == "Skips" then
			skippedCount += 1
		else
			local _: never = effect
		end
	end

	if passedCount > 0 then
		return "Proved"
	end

	if skippedCount > 0 then
		return "Skipped"
	end

	return "Untested"
end


local function testCitedIdsOf(cited: Citations.Contents): { [string]: true }
	local testFolderPrefix                 = `{Paths.FOLDER.test}/`
	local testCitedIds: { [string]: true } = {}
	for _, citation in cited.citations do
		if stringext.hasPrefix(citation.location, testFolderPrefix) then
			testCitedIds[citation.id] = true
		end
	end

	return testCitedIds
end


local function invalidReport(source: string, problems: { string }): Types.Result<never>
	local problemCount = #problems
	local noun         = if problemCount == 1 then "problem" else "problems"
	local problemList  = table.concat(problems, "; ")
	local requirement  = `"{source}" must be a report`
	return { ok = false, error = `{requirement}, got {problemCount} {noun}: {problemList}` }
end


-- Public ------------------------------------------------------------------------------------------

--- Every state of a claim, in the order that the spec names them.
Reports.CLAIM_STATES = CLAIM_STATES


--[=[
	Reads a report from its JSON text.

	@param  text   the report as the run sent it
	@param  source where `text` came from, which a failure names
	@return the report, or the clause that names what is wrong with it
]=]
function Reports.parse(text: string, source: string): Types.Result<Report>
	local ok, result = pcall(json.deserialize, text)
	if not ok then
		return { ok = false, error = `"{source}" must be JSON, got {tostring(result)}` }
	end

	local object = json.asObject(result)
	if object == nil then
		return { ok = false, error = `"{source}" must be a JSON object, got {typeof(result)}` }
	end

	local kind = toKind(object.kind)
	if kind == nil then
		local problem = `kind must be "test" or "bench", got {descriptionOf(object.kind)}`
		return invalidReport(source, { problem })
	end

	local profile = toProfile(object.profile)
	if profile == nil then
		local requirement = 'profile must be "quick", "standard" or "deep"'
		local problem     = `{requirement}, got {descriptionOf(object.profile)}`
		return invalidReport(source, { problem })
	end

	local runId = toRunId(object.runId)
	if runId == nil then
		local requirement = `runId must be {RUN_ID_LENGTH} lowercase hexadecimal digits`
		local problem     = `{requirement}, got {descriptionOf(object.runId)}`
		return invalidReport(source, { problem })
	end

	local buildId = toText(object.buildId)
	if buildId == nil then
		local problem = `buildId must be a string, got {typeof(object.buildId)}`
		return invalidReport(source, { problem })
	end

	local seed = toNumber(object.seed)
	if seed == nil then
		local problem = `seed must be a number, got {typeof(object.seed)}`
		return invalidReport(source, { problem })
	end

	local filter = toText(object.filter)
	if filter == nil then
		local problem = `filter must be a string, got {typeof(object.filter)}`
		return invalidReport(source, { problem })
	end

	local isComplete = toBoolean(object.isComplete)
	if isComplete == nil then
		local problem = `isComplete must be a boolean, got {typeof(object.isComplete)}`
		return invalidReport(source, { problem })
	end

	local problems: { string } = {}
	local outcomes             = readOutcomes(object.outcomes, problems)
	if #problems > 0 then
		return invalidReport(source, problems)
	end

	local report: Report = {
		kind       = kind,
		runId      = runId,
		buildId    = buildId,
		seed       = seed,
		profile    = profile,
		filter     = filter,
		isComplete = isComplete,
		outcomes   = outcomes,
	}

	return { ok = true, value = report }
end


--[=[
	Says where the claims stand after `report`, and what it comes to.

	@param  report the report to judge, of a run of the tests
	@param  spec   the claims that the report's tests cite
	@param  cited  what the tests under `test/` cite, which tells which claims the report lacks
	@return the standing of the claims, the failures, the problems and the ruling
]=]
function Reports.standingOf(
	report: Report,
	spec:   Spec.Contents,
	cited:  Citations.Contents
): Standing
	local problems: { string } = {}
	local outcomesByClaimId    = indexOutcomes(report, spec, problems)

	local failures: { Outcome } = {}
	local skips: { Outcome }    = {}
	for _, outcome in report.outcomes do
		local effect = EFFECT_BY_VERDICT[outcome.verdict]
		if effect == "Proves" then
			continue
		end

		if effect == "Fails" then
			table.insert(failures, outcome)
		elseif effect == "Skips" then
			table.insert(skips, outcome)
		else
			local _: never = effect
		end
	end

	local isFull = report.filter == "" and report.isComplete

	local claimsByState: { [ClaimState]: { Spec.Claim } } = {
		Proved   = {},
		Failing  = {},
		Untested = {},
		Skipped  = {},
		Waived   = {},
	}

	local staleClaims: { Spec.Claim } = {}
	if isFull then
		local testCitedIds = testCitedIdsOf(cited)
		for _, claim in spec.claims do
			if claim.isWithdrawn then
				continue
			end

			if claim.proofKind == "Waived" then
				table.insert(claimsByState.Waived, claim)
				continue
			end

			if Spec.JUDGE_BY_KIND[claim.proofKind] ~= "Test" then
				continue
			end

			local state = stateOf(outcomesByClaimId[claim.id] or {})
			table.insert(claimsByState[state], claim)

			local isTestCited = testCitedIds[claim.id] ~= nil
			if
				state == "Untested"
				and isTestCited
			then
				table.insert(staleClaims, claim)
			end
		end
	end

	local ruling: Ruling = "Pass"
	if
		#failures > 0
		or #problems > 0
	then
		ruling = "Fail"
	elseif
		not isFull
		or #staleClaims > 0
		or #claimsByState.Skipped > 0
		or #claimsByState.Proved == 0
	then
		ruling = "Incomplete"
	end

	return {
		claimsByState = claimsByState,
		failures      = failures,
		skips         = skips,
		problems      = problems,
		staleClaims   = staleClaims,
		isFull        = isFull,
		ruling        = ruling,
	}
end


return table.freeze(Reports)
