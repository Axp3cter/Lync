--!strict

--[=[
	Tapes

	Shrinks the tape of a failing case into a smaller tape that still fails, and writes a tape as a
	Luau literal.

	A tape is the list of words that replay the draws of a RandomSource. A source that replays a
	tape gives zeros once it ends, so every shorter tape is valid and a case built from one keeps
	its invariants.

	Shrinking tries only tapes that come before the current tape in shortlex order: shorter first,
	then smaller at the first word that differs. That order has no endless descending chain, so the
	search ends even without a call limit.
]=]


-- Imports -----------------------------------------------------------------------------------------

local RandomSource = require("./RandomSource")


-- Module ------------------------------------------------------------------------------------------

local Tapes = {}


-- Types -------------------------------------------------------------------------------------------

type Search = {
	read callLimit: number,
	read fails:     (candidate: { number }) -> boolean,

	callCount:      number,
	tape:           { number },
}


-- Constants ---------------------------------------------------------------------------------------

--- The divisor that halves the width of a run and the gap that a bisection has left.
const HALVING_DIVISOR = 2


-- Private -----------------------------------------------------------------------------------------

local function isEarlier(candidate: { read number }, tape: { read number }): boolean
	if #candidate ~= #tape then
		return #candidate < #tape
	end

	for i, word in candidate do
		if word ~= tape[i] then
			return word < tape[i]
		end
	end

	return false
end


local function cutRun(tape: { number }, start: number, width: number): { number }
	local keptCount = #tape - width
	local cut       = table.create(keptCount, 0)
	table.move(tape, 1, start - 1, 1, cut)
	table.move(tape, start + width, #tape, start, cut)

	return cut
end


local function zeroRun(tape: { number }, start: number, width: number): { number }
	local zeroed = table.clone(tape)
	for i = start, start + width - 1 do
		zeroed[i] = 0
	end

	return zeroed
end


local function replaceWord(tape: { number }, position: number, word: number): { number }
	local replaced     = table.clone(tape)
	replaced[position] = word

	return replaced
end


local function moveWeight(
	tape:    { number },
	earlier: number,
	later:   number,
	amount:  number
): { number }
	local moved    = table.clone(tape)
	moved[earlier] = tape[earlier] - amount
	moved[later]   = tape[later] + amount

	return moved
end


local function canMoveWeight(tape: { number }, earlier: number, later: number): boolean
	if tape[earlier] == 0 then
		return false
	end

	return RandomSource.isWord(tape[earlier] + tape[later])
end


-- A call is spent only on a candidate that comes earlier than the tape in hand, since a later one
-- could not be an improvement.
local function adopt(search: Search, candidate: { number }): "Adopted" | "Declined"
	if search.callCount >= search.callLimit then
		return "Declined"
	end

	if not isEarlier(candidate, search.tape) then
		return "Declined"
	end

	search.callCount += 1
	if not search.fails(candidate) then
		return "Declined"
	end

	search.tape = candidate

	return "Adopted"
end


-- Whole runs go first, halving the width, because one cut that holds removes more than any
-- change to a word can.
local function cutRuns(search: Search): ()
	local width = #search.tape
	while width >= 1 do
		local start = 1
		while start + width - 1 <= #search.tape do
			if adopt(search, cutRun(search.tape, start, width)) == "Declined" then
				start += 1
			end
		end

		width //= HALVING_DIVISOR
	end
end


local function zeroRuns(search: Search): ()
	local width = #search.tape
	while width >= 1 do
		for start = 1, #search.tape - width + 1 do
			adopt(search, zeroRun(search.tape, start, width))
		end

		width //= HALVING_DIVISOR
	end
end


-- Each word is tried at zero, and failing that bisected between the last word that did not fail
-- and the word in hand, which assumes that a lower word is the likelier to fail.
local function lowerWord(search: Search, i: number): ()
	local failing = search.tape[i]
	local passing = 0
	if adopt(search, replaceWord(search.tape, i, 0)) == "Declined" then
		while failing - passing > 1 do
			local middle  = (passing + failing) // HALVING_DIVISOR
			local outcome = adopt(search, replaceWord(search.tape, i, middle))
			if outcome == "Adopted" then
				failing = middle
			elseif outcome == "Declined" then
				passing = middle
			else
				local _: never = outcome
			end
		end
	end
end


-- Later words go first, because a word often depends on an earlier one: a value drawn below a
-- width that is itself on the tape wraps when the width is lowered under it.
local function lowerWords(search: Search): ()
	for i = #search.tape, 1, -1 do
		if search.tape[i] == 0 then
			continue
		end

		lowerWord(search, i)
	end
end


-- The whole weight of the earlier word goes first, then half of it, then a quarter, and so on,
-- each size tried once, since a move that keeps a sum often has room for only part of it.
local function moveWeightsBetween(search: Search, earlier: number, later: number): ()
	local amount = search.tape[earlier]
	while amount >= 1 do
		adopt(search, moveWeight(search.tape, earlier, later, amount))
		amount = math.min(amount // HALVING_DIVISOR, search.tape[earlier])
	end
end


-- Words that fail only together, such as two numbers with a given sum, each stand at the lowest
-- value that the other allows, which no single-word change improves. Moving weight from a word
-- onto a later one makes the tape earlier in shortlex order and keeps their sum.
local function moveWeights(search: Search): ()
	for earlier = 1, #search.tape do
		for later = earlier + 1, #search.tape do
			if canMoveWeight(search.tape, earlier, later) then
				moveWeightsBetween(search, earlier, later)
			end
		end
	end
end


-- Public ------------------------------------------------------------------------------------------

--[=[
	Returns a tape written as a Luau literal without spaces, so that a command line can carry it.

	@param  tape the words to write
	@return the literal, such as `{3,0,17}`, and `{}` for an empty tape
]=]
function Tapes.literalOf(tape: { number }): string
	return `\{{table.concat(tape, ",")}}`
end


--[=[
	Shrinks a failing tape to the shortest and then smallest tape it can find that still fails.

	The search cuts runs of words, zeroes runs, and lowers single words. When those change nothing,
	it moves weight from a word onto a later word, so that words which fail only together, such as
	two numbers with a given sum, can trade. It repeats until a round changes nothing or
	`callLimit` calls are spent. The tape it returns is the last candidate for which `fails`
	answered true, or `tape` itself when none was.

	`fails` must give the same answer every time for the same tape, and must be true for `tape`.

	@param  tape      the tape of the failing case, whole words
	@param  callLimit the most calls to `fails` the search may spend, at least 1
	@param  fails     whether a candidate tape still fails in the way `tape` did
	@return the tape found, which is never later than `tape` in shortlex order
	@return how many calls to `fails` the search spent
	@error  when a word of `tape` is not a whole number from 0 to 4294967295
	@error  when `callLimit` is not a whole number of at least 1
]=]
function Tapes.shrink(
	tape:      { number },
	callLimit: number,
	fails:     (candidate: { number }) -> boolean
): ({ number }, number)
	for i, word in tape do
		if not RandomSource.isWord(word) then
			local requirement = `whole numbers from 0 to {RandomSource.MAX_WORD}`
			error(`tape must hold {requirement}, got {word} at word {i}`, 2)
		end
	end

	if
		not math.isfinite(callLimit)
		or callLimit < 1
		or math.floor(callLimit) ~= callLimit
	then
		error(`callLimit must be a whole number of at least 1, got {callLimit}`, 2)
	end

	local search: Search = {
		callLimit = callLimit,
		fails     = fails,

		callCount = 0,
		tape      = tape,
	}

	repeat
		local before = search.tape
		cutRuns(search)
		zeroRuns(search)
		lowerWords(search)
		if search.tape == before then
			moveWeights(search)
		end

		local isDone = search.tape == before
	until isDone

	return search.tape, search.callCount
end


return table.freeze(Tapes)
