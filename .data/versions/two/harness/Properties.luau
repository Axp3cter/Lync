--!strict

--[=[
	Properties

	Checks a property on generated cases, and shrinks the first case that breaks it into the
	smallest case it can find.

	Each case draws its value from a RandomSource that is seeded from the seed of the run, the id of
	the test and the number of the case, so one case replays alone. A failing case is replayed from
	its tape, shrunk by Tapes, and reported with the seeds, the case number, the shrunk tape and a
	line that replays it.

	Checking a property yields when `pauseIfDue`, a generator or a property does, and not otherwise.
]=]


-- Imports -----------------------------------------------------------------------------------------

local Check        = require("./Check")
local RandomSource = require("./RandomSource")
local Tapes        = require("./Tapes")
local Types        = require("./Types")


-- Module ------------------------------------------------------------------------------------------

local Properties = {}


-- Types -------------------------------------------------------------------------------------------

type Budget = {
	read caseCount:       number,
	read shrinkCallLimit: number,
}


type Origin = {
	read runSeed:    number,
	read caseSeed:   number,
	read caseNumber: number,
}


type HeldTrial = { read kind: "Held" }


type FaultedTrial = {
	read kind:      "Failed" | "Crashed",
	read message:   string,
	read traceback: string,
}


type Trial = HeldTrial | FaultedTrial


type Completion = { read kind: "Returned" }


type Exception = {
	read kind:      "Threw",
	read message:   string,
	read traceback: string,
}


type Unwinding = Completion | Exception


--- How hard a property is checked: how many cases it runs and how many replays a shrink may spend.
export type Profile =
	| "Quick"
	| "Standard"
	| "Deep"


--- A profile as the command line, a message and a report spell it, in lowercase.
export type ProfileWord =
	| "quick"
	| "standard"
	| "deep"


--[=[
	What `verify` needs to check one property.

	@field id             the test's id, which seeds every case and names the test in a replay line
	@field generator      builds the value of one case from the draws of its source
	@field property       checks one case's value, failing its check or throwing if it does not hold
	@field seed           the seed of the whole run, a whole number from 0 to 4294967295
	@field profile        how many cases to run and how many replays a shrink may spend
	@field tape           one tape to replay alone instead of the cases, nil to run the cases
	@field pauseIfDue     called before each case and replay, and given to a property; free to yield
	@field outputPatterns where the patterns of `check:expectOutput` are added once each
]=]
export type Options<T> = {
	read id:             string,
	read generator:      RandomSource.Generator<T>,
	read property:       (check: Check.Check, caseValue: T, pauseIfDue: () -> ()) -> (),
	read seed:           number,
	read profile:        Profile,
	read tape:           { number }?,
	read pauseIfDue:     () -> (),
	read outputPatterns: { string }?,
}


--[=[
	A property that held on every case it was checked on.

	@field kind      which outcome this is, always "Passed"
	@field caseCount how many cases ran
]=]
export type Passed = {
	read kind:      "Passed",
	read caseCount: number,
}


--[=[
	A case that broke a property, shrunk as far as the budget allowed.

	@field kind            "Failed" when a check failed, or "Crashed" when anything else threw
	@field origin          the run seed, case seed and case number, nil for a tape replayed alone
	@field tape            the tape of the shrunk case
	@field tapeLiteral     `tape` written as a Luau literal
	@field replayLine      the words that replay the shrunk case, `filter=<id> tape={...}`
	@field message         the message of the shrunk case's failure or error
	@field traceback       the stack where the shrunk case failed
	@field shrinkCallCount how many replays the shrinker spent, 0 when it did not run
]=]
export type Counterexample = {
	read kind:            "Failed" | "Crashed",
	read origin:          Origin?,
	read tape:            { number },
	read tapeLiteral:     string,
	read replayLine:      string,
	read message:         string,
	read traceback:       string,
	read shrinkCallCount: number,
}


--- What checking a property found.
export type Outcome = Passed | Counterexample


-- Constants ---------------------------------------------------------------------------------------

--- The run seed that a run uses when the user gives none, kept fixed so that runs agree.
const DEFAULT_SEED = 0x4C796E63


--- What each profile spends: Standard runs 300 cases, Quick a tenth of them and Deep 20 times them.
const BUDGET_BY_PROFILE: Types.Complete<{ read [Profile]: Budget }> = {
	Quick    = { caseCount = 30, shrinkCallLimit = 1000 },
	Standard = { caseCount = 300, shrinkCallLimit = 1000 },
	Deep     = { caseCount = 6000, shrinkCallLimit = 10_000 },
}
table.freeze(BUDGET_BY_PROFILE)


--- How a profile is spelled in lowercase, the one table that every spelling comes from.
const WORD_BY_PROFILE: Types.Complete<{ read [Profile]: ProfileWord }> = {
	Quick    = "quick",
	Standard = "standard",
	Deep     = "deep",
}
table.freeze(WORD_BY_PROFILE)


--- The goldens of a case, of which there are none: a golden belongs to a test body, not to a case.
const NO_GOLDENS: { read [string]: unknown } = {}
table.freeze(NO_GOLDENS)


const HELD: HeldTrial = { kind = "Held" }
table.freeze(HELD)


const COMPLETION: Completion = { kind = "Returned" }
table.freeze(COMPLETION)


-- Private -----------------------------------------------------------------------------------------

-- In Private, not Handlers: four private attempt sites call it (recorded deviation in v5-goals).
-- Runs where the error happened, so level 2 starts the traceback at the function that failed.
local function onCaseError(failure: unknown): Exception
	return {
		kind      = "Threw",
		message   = tostring(failure),
		traceback = debug.traceback(nil, 2),
	}
end


local function checkCase<T>(
	options: Options<T>,
	source:  RandomSource.RandomSource,
	check:   Check.Check
): Unwinding
	local caseValue = options.generator(source)
	options.property(check, caseValue, options.pauseIfDue)

	return COMPLETION
end


local function keepOutputPatterns(sink: { string }?, check: Check.Check): ()
	if sink == nil then
		return
	end

	for _, pattern in check:outputPatterns() do
		if not table.find(sink, pattern) then
			table.insert(sink, pattern)
		end
	end
end


-- A check that failed outranks an error, because a property can catch the throw of an assertion
-- and carry on.
local function attemptCase<T>(options: Options<T>, source: RandomSource.RandomSource): Trial
	local check        = Check.new(debug.info(options.property, "s"), NO_GOLDENS)
	local _, unwinding = xpcall(checkCase, onCaseError, options, source, check)

	keepOutputPatterns(options.outputPatterns, check)

	local failure = check:failure()
	if failure ~= nil then
		return {
			kind      = "Failed",
			message   = failure.message,
			traceback = failure.traceback,
		}
	end

	if unwinding.kind == "Threw" then
		return {
			kind      = "Crashed",
			message   = unwinding.message,
			traceback = unwinding.traceback,
		}
	elseif unwinding.kind == "Returned" then
		return HELD
	end

	local unhandled: never = unwinding
	return unhandled
end


local function toFaultedTrial(trial: Trial, wantedKind: "Failed" | "Crashed"): FaultedTrial?
	if trial.kind == "Held" then
		return nil
	end

	if trial.kind ~= wantedKind then
		return nil
	end

	return trial
end


local function counterexampleOf(
	id:              string,
	fault:           FaultedTrial,
	tape:            { number },
	origin:          Origin?,
	shrinkCallCount: number
): Counterexample
	local tapeLiteral = Tapes.literalOf(tape)

	return {
		kind            = fault.kind,
		origin          = origin,
		tape            = tape,
		tapeLiteral     = tapeLiteral,
		replayLine      = `filter={id} tape={tapeLiteral}`,
		message         = fault.message,
		traceback       = fault.traceback,
		shrinkCallCount = shrinkCallCount,
	}
end


-- The failure is reported as it first happened, since a tape that does not fail again has nothing
-- to shrink toward.
local function unreproducibleOf(
	id:     string,
	fault:  FaultedTrial,
	tape:   { number },
	origin: Origin
): Counterexample
	local requirement = "give the same outcome for the same draws"
	local got         = `a {fault.kind} case that did not fail again on replay: {fault.message}`
	local unreproduced: FaultedTrial = {
		kind      = "Crashed",
		message   = `{id} must {requirement}, got {got}`,
		traceback = fault.traceback,
	}

	return counterexampleOf(id, unreproduced, tape, origin, 0)
end


local function shrunkOf<T>(
	options: Options<T>,
	fault:   FaultedTrial,
	tape:    { number },
	origin:  Origin,
	budget:  Budget
): Counterexample
	local replayed = attemptCase(options, RandomSource.fromTape(tape))
	if replayed.kind == "Held" then
		return unreproducibleOf(options.id, fault, tape, origin)
	end

	local wantedKind  = replayed.kind
	local shrunkFault = replayed

	local shrunkTape, callCount = Tapes.shrink(tape, budget.shrinkCallLimit, function(
		candidate: { number }
	): boolean
		options.pauseIfDue()

		local source = RandomSource.fromTape(candidate)
		local trial  = attemptCase(options, source)
		if source:hasOverrun() then
			return false
		end

		local repeated = toFaultedTrial(trial, wantedKind)
		if repeated == nil then
			return false
		end

		shrunkFault = repeated

		return true
	end)

	return counterexampleOf(options.id, shrunkFault, shrunkTape, origin, callCount)
end


local function replayAlone<T>(options: Options<T>, tape: { number }): Outcome
	options.pauseIfDue()

	local trial = attemptCase(options, RandomSource.fromTape(tape))
	if trial.kind == "Held" then
		return { kind = "Passed", caseCount = 1 }
	end

	return counterexampleOf(options.id, trial, tape, nil, 0)
end


-- Public ------------------------------------------------------------------------------------------

Properties.DEFAULT_SEED = DEFAULT_SEED


--[=[
	Returns the profile that a lowercase word names.

	@param  word the word, such as "quick" typed on the command line
	@return the profile, nil when the word names none
]=]
function Properties.toProfile(word: string): Profile?
	for profile, profileWord in WORD_BY_PROFILE do
		if profileWord == word then
			return profile
		end
	end

	return nil
end


--[=[
	Checks a property on generated cases, and shrinks the first case that breaks it.

	The cases run in order, each drawing from a source seeded by the seed of the run, `options.id`
	and the number of the case, and the first failure ends the run. That case is replayed from its
	tape to see that it fails again, and then shrunk, and the outcome reports the shrunk case.

	A failure that does not repeat on replay depended on something other than its draws, so it is
	reported as "Crashed" with the failure it first gave, and not shrunk.

	With `options.tape`, that one tape is replayed alone, and nothing is shrunk.

	@param  options what to check and how hard
	@return "Passed" with the number of cases that ran, or the case that failed, shrunk
	@error  when `options.id` is empty
	@error  when `options.seed` or a word of `options.tape` is not a whole number from 0 to 2^32 - 1
]=]
function Properties.verify<T>(options: Options<T>): Outcome
	if options.id == "" then
		error('id must not be empty, got ""', 2)
	end

	if not RandomSource.isWord(options.seed) then
		local requirement = `a whole number from 0 to {RandomSource.MAX_WORD}`
		error(`options.seed must be {requirement}, got {options.seed}`, 2)
	end

	local tape = options.tape
	if tape ~= nil then
		for i, word in tape do
			if not RandomSource.isWord(word) then
				local requirement = `whole numbers from 0 to {RandomSource.MAX_WORD}`
				error(`options.tape must hold {requirement}, got {word} at word {i}`, 2)
			end
		end

		return replayAlone(options, tape)
	end

	local budget = BUDGET_BY_PROFILE[options.profile]
	for caseNumber = 1, budget.caseCount do
		options.pauseIfDue()

		local caseSeed = RandomSource.deriveSeed(options.seed, options.id, caseNumber)
		local source   = RandomSource.new(caseSeed)
		local trial    = attemptCase(options, source)
		if trial.kind ~= "Held" then
			local origin = {
				runSeed    = options.seed,
				caseSeed   = caseSeed,
				caseNumber = caseNumber,
			}

			return shrunkOf(options, trial, source:tape(), origin, budget)
		end
	end

	return { kind = "Passed", caseCount = budget.caseCount }
end


--[=[
	Returns the lowercase word that spells a profile.

	@param  profile the profile to spell
	@return the word, such as "quick", which `toProfile` reads back
]=]
function Properties.wordOf(profile: Profile): ProfileWord
	return WORD_BY_PROFILE[profile]
end


return table.freeze(Properties)
