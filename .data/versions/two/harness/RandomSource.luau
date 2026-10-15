--!strict

--[=[
	RandomSource

	Draws seeded random words for generators, records each word it draws as a tape, and replays a
	tape.

	A tape is the list of words that replay the draws of a source. `drawWord` records the word it
	gives, and a bounded draw, such as an integer or a boolean, records the value it chose, so that
	lowering a word of the tape lowers the value built from it. A source made from a tape hands out
	those words in order and then zeros, so every shorter tape is valid and a generator that reads
	zeros builds its simplest value.

	One seed gives one sequence of words on every host, because the words come from integer
	arithmetic on bit32 alone: xoshiro128** seeded through SplitMix32. Only `drawNumber` also uses
	floating-point arithmetic, to turn two words into a number.

	A source made by `newUnrecorded` draws the same sequence as one made by `new` and keeps no
	tape, for a caller that draws many values and never replays them.
]=]


-- Module ------------------------------------------------------------------------------------------

local RandomSource   = {}
RandomSource.__index = RandomSource


-- Types -------------------------------------------------------------------------------------------

type SplitMixConstants = {
	read increment:        number,
	read highShift:        number,
	read firstMultiplier:  number,
	read lowShift:         number,
	read secondMultiplier: number,
}


type XoshiroConstants = {
	read resultMultiplier: number,
	read resultRotation:   number,
	read resultScrambler:  number,
	read stateShift:       number,
	read stateRotation:    number,
}


type WideConstants = {
	read highFactor: number,
	read highRange:  number,
	read lowShift:   number,
	read range:      number,
}


type State = {
	first:  number,
	second: number,
	third:  number,
	fourth: number,
}


type Fields = {
	read _state:       State?,
	read _tape:        { number },
	read _isRecording: boolean,
	_drawCount:        number,
}


--- A source of draws: the words of one seed, or the words of one tape.
export type RandomSource = setmetatable<Fields, typeof(RandomSource)>


--- A function that builds one value from the draws of a source.
export type Generator<T> = (source: RandomSource) -> T


-- Constants ---------------------------------------------------------------------------------------

--- The largest word a source draws and the largest seed, 2^32 - 1.
const MAX_WORD = 0xFFFFFFFF


--- The most zeros a replayed source hands out past the end of its tape before a draw is refused.
const MAX_ZERO_COUNT = 4096


--- What a draw raises once a replayed case has passed the limit of zeros.
const OVERRUN_MESSAGE = `generator must settle within {MAX_ZERO_COUNT} words after its tape ends`


--- The widest span that `drawInteger` accepts, so that the count of results, span + 1, is exact.
const MAX_SPAN = 2 ^ 53 - 1


--- How many different words a draw can give.
const WORD_RANGE = 2 ^ 32


--- How many results a boolean has.
const BOOLEAN_COUNT = 2


--- The width in bits of the halves that `multiplyWords` multiplies, so no product passes 2^48.
const HALF_WIDTH = 16


--- The constants of SplitMix32 as its published form gives them.
const SPLIT_MIX: SplitMixConstants = {
	increment        = 0x9E3779B9,
	highShift        = 16,
	firstMultiplier  = 0x21F0AAAD,
	lowShift         = 15,
	secondMultiplier = 0x735A2D97,
}


--- The constants of xoshiro128** as its published form gives them.
const XOSHIRO: XoshiroConstants = {
	resultMultiplier = 5,
	resultRotation   = 7,
	resultScrambler  = 9,
	stateShift       = 9,
	stateRotation    = 11,
}


--- How two words join into one 53-bit number: the first word's 32 bits, then the second's top 21.
const WIDE_NUMBER: WideConstants = {
	highFactor = 2 ^ 21,
	highRange  = 2 ^ 21,
	lowShift   = 11,
	range      = 2 ^ 53,
}


-- Private -----------------------------------------------------------------------------------------

local function isWhole(value: number): boolean
	if not math.isfinite(value) then
		return false
	end

	return math.floor(value) == value
end


local function isWord(value: number): boolean
	if not isWhole(value) then
		return false
	end

	return value >= 0 and value <= MAX_WORD
end


local function canDrawInteger(min: number, max: number): boolean
	if not isWhole(min) then
		return false
	end

	if not isWhole(max) then
		return false
	end

	local span = max - min

	return span >= 0 and span <= MAX_SPAN
end


local function canDrawNumber(min: number, max: number): boolean
	if not math.isfinite(min) then
		return false
	end

	if not math.isfinite(max) then
		return false
	end

	return max >= min and math.isfinite(max - min)
end


--[=[
	Multiplies two words modulo 2^32 without rounding.

	Each half of `left` is multiplied by `right` apart, so that no product passes 2^48.

	@param  left  the word that is split into halves
	@param  right the word that multiplies each half
	@return the product modulo 2^32
]=]
local function multiplyWords(left: number, right: number): number
	local high = bit32.rshift(left, HALF_WIDTH)
	local low  = bit32.extract(left, 0, HALF_WIDTH)

	local lowProduct  = low * right
	local highProduct = bit32.lshift(high * right, HALF_WIDTH)

	return bit32.band(lowProduct + highProduct, MAX_WORD)
end


local function finalize(value: number): number
	local mixed = bit32.bxor(value, bit32.rshift(value, SPLIT_MIX.highShift))
	mixed       = multiplyWords(mixed, SPLIT_MIX.firstMultiplier)
	mixed       = bit32.bxor(mixed, bit32.rshift(mixed, SPLIT_MIX.lowShift))
	mixed       = multiplyWords(mixed, SPLIT_MIX.secondMultiplier)

	return bit32.bxor(mixed, bit32.rshift(mixed, SPLIT_MIX.lowShift))
end


--[=[
	Steps SplitMix32 once.

	@param  cursor the position to step from
	@return the position after the step
	@return the word that the step gives
]=]
local function stepSplitMix(cursor: number): (number, number)
	local advanced = bit32.band(cursor + SPLIT_MIX.increment, MAX_WORD)
	return advanced, finalize(advanced)
end


--[=[
	Mixes `word` into `seed` with the output stage of SplitMix32, so that a small change in either
	changes every bit of the result.

	@param  seed the seed so far
	@param  word the number to mix in
	@return the new seed
]=]
local function mixWord(seed: number, word: number): number
	local mixed    = bit32.bxor(seed, word)
	local advanced = bit32.band(mixed + SPLIT_MIX.increment, MAX_WORD)

	return finalize(advanced)
end


-- No guard against the all-zero state, which xoshiro128** cannot leave: SplitMix32 maps only 0
-- to 0 and never repeats a position within four steps, so no seed spreads into four zeros.
local function stateOf(seed: number): State
	local firstCursor, first   = stepSplitMix(seed)
	local secondCursor, second = stepSplitMix(firstCursor)
	local thirdCursor, third   = stepSplitMix(secondCursor)
	local _, fourth            = stepSplitMix(thirdCursor)

	return {
		first  = first,
		second = second,
		third  = third,
		fourth = fourth,
	}
end


--[=[
	Steps xoshiro128** once.

	The four words of the state are replaced in place, so that a draw allocates nothing.

	@param  state the four words of the state
	@return the word that the step gives
]=]
local function stepXoshiro(state: State): number
	local scrambled = multiplyWords(state.second, XOSHIRO.resultMultiplier)
	local rotated   = bit32.lrotate(scrambled, XOSHIRO.resultRotation)
	local word      = multiplyWords(rotated, XOSHIRO.resultScrambler)
	local shifted   = bit32.lshift(state.second, XOSHIRO.stateShift)

	state.third  = bit32.bxor(state.third, state.first)
	state.fourth = bit32.bxor(state.fourth, state.second)
	state.second = bit32.bxor(state.second, state.third)
	state.first  = bit32.bxor(state.first, state.fourth)
	state.third  = bit32.bxor(state.third, shifted)
	state.fourth = bit32.lrotate(state.fourth, XOSHIRO.stateRotation)

	return word
end


local function joinWords(high: number, low: number): number
	local scaled  = high * WIDE_NUMBER.highFactor
	local lowBits = bit32.rshift(low, WIDE_NUMBER.lowShift)

	return scaled + lowBits
end


local function stepWide(state: State): number
	local high = stepXoshiro(state)
	local low  = stepXoshiro(state)

	return joinWords(high, low)
end


local function replayWord(self: RandomSource): number
	local drawCount = self._drawCount + 1
	self._drawCount = drawCount

	local recorded = self._tape[drawCount]
	if recorded ~= nil then
		return recorded
	end

	return 0
end


local function drawWord(self: RandomSource): number
	local state = self._state
	if state == nil then
		return replayWord(self)
	end

	local word = stepXoshiro(state)
	if self._isRecording then
		table.insert(self._tape, word)
	end

	return word
end


-- A replay reads zeros past the end of its tape, so a generator that never settles on zeros would
-- never return; the public draws raise once this holds.
local function hasOverrun(self: RandomSource): boolean
	return self._drawCount - #self._tape > MAX_ZERO_COUNT
end


local function drawWide(self: RandomSource): number
	local high = drawWord(self)
	local low  = drawWord(self)

	return joinWords(high, low)
end


-- A replay takes the words of the tape as they are, reduced modulo `count`, since a candidate
-- tape may hold any word.
local function replayBelow(self: RandomSource, count: number): number
	if count <= WORD_RANGE then
		return replayWord(self) % count
	end

	local high = replayWord(self) % WIDE_NUMBER.highRange
	local low  = replayWord(self)

	return (high * WORD_RANGE + low) % count
end


local function recordChosen(self: RandomSource, chosen: number, isWide: boolean): ()
	if not self._isRecording then
		return
	end

	if isWide then
		table.insert(self._tape, chosen // WORD_RANGE)
		table.insert(self._tape, chosen % WORD_RANGE)
	else
		table.insert(self._tape, chosen)
	end
end


-- A draw that lands in the partial block at the top of the range is drawn again, since taking it
-- modulo `count` would favour the low results. Only the value chosen is recorded, as one word, or
-- as two for a count above 2^32, so that the tape holds the draw and not the draws it cost.
local function generateBelow(self: RandomSource, state: State, count: number): number
	local isWide = count > WORD_RANGE
	local range  = if isWide then WIDE_NUMBER.range else WORD_RANGE
	local limit  = range - range % count

	local step: (state: State) -> number = if isWide then stepWide else stepXoshiro

	local drawn = 0
	repeat
		drawn = step(state)
	until drawn < limit

	local chosen = drawn % count
	recordChosen(self, chosen, isWide)

	return chosen
end


local function drawBelow(self: RandomSource, count: number): number
	local state = self._state
	if state == nil then
		return replayBelow(self, count)
	end

	return generateBelow(self, state, count)
end


-- Public ------------------------------------------------------------------------------------------

--- The largest word a source draws and the largest seed, 2^32 - 1.
RandomSource.MAX_WORD = MAX_WORD


--[=[
	Creates a source that draws the sequence of a seed.

	@param  seed the number that fixes the whole sequence, from 0 to 4294967295
	@return a source whose tape is empty until it draws
	@error  when `seed` is not a whole number from 0 to 4294967295
]=]
function RandomSource.new(seed: number): RandomSource
	if not isWord(seed) then
		error(`seed must be a whole number from 0 to {MAX_WORD}, got {seed}`, 2)
	end

	return setmetatable({
		_state       = stateOf(seed),
		_tape        = {},
		_isRecording = true,
		_drawCount   = 0,
	}, RandomSource)
end


--[=[
	Creates a source that replays a tape.

	The source hands out the words of `tape` in order and then zeros, and its own tape stays `tape`.
	A bounded draw takes the next word modulo the number of its results.

	@param  tape the words to replay, each a whole number from 0 to 4294967295
	@return a source that is about to draw the first word of `tape`
	@error  when a word of `tape` is not a whole number from 0 to 4294967295
]=]
function RandomSource.fromTape(tape: { number }): RandomSource
	for i, word in tape do
		if not isWord(word) then
			error(`tape must hold whole numbers from 0 to {MAX_WORD}, got {word} at word {i}`, 2)
		end
	end

	return setmetatable({
		_state       = nil,
		_tape        = table.clone(tape),
		_isRecording = true,
		_drawCount   = 0,
	}, RandomSource)
end


--[=[
	Creates a source that draws the sequence of a seed and keeps no tape.

	The source gives the same words and values as `new(seed)` would, but it records nothing, so
	a long run of draws holds no memory, and it cannot be replayed.

	@param  seed the number that fixes the whole sequence, from 0 to 4294967295
	@return a source that draws like `new(seed)` and whose `tape` it refuses to give
	@error  when `seed` is not a whole number from 0 to 4294967295
]=]
function RandomSource.newUnrecorded(seed: number): RandomSource
	if not isWord(seed) then
		error(`seed must be a whole number from 0 to {MAX_WORD}, got {seed}`, 2)
	end

	return setmetatable({
		_state       = stateOf(seed),
		_tape        = {},
		_isRecording = false,
		_drawCount   = 0,
	}, RandomSource)
end


--[=[
	Tells whether `drawInteger` accepts `min` and `max`.

	@param  min the lowest number that would be drawn
	@param  max the highest number that would be drawn
	@return true when both are whole numbers and `max` is from `min` to `min + 2^53 - 1`
]=]
function RandomSource.canDrawInteger(min: number, max: number): boolean
	return canDrawInteger(min, max)
end


--[=[
	Tells whether `drawNumber` accepts `min` and `max`.

	@param  min the lowest number that would be drawn
	@param  max the highest number that would be drawn
	@return true when both are finite, `max` is at least `min` and `max - min` is finite
]=]
function RandomSource.canDrawNumber(min: number, max: number): boolean
	return canDrawNumber(min, max)
end


--[=[
	Derives the seed of one case from the seed of a run, a label and a number.

	The seed depends on those three arguments alone, so a case replays without the cases before it.

	@param  runSeed the seed of the whole run, a whole number from 0 to 4294967295
	@param  label   the text that names what is being seeded, such as a test's id
	@param  index   the number of the case among those the label names, from 0 to 4294967295
	@return a seed for `new`, a whole number from 0 to 4294967295
	@error  when `runSeed` or `index` is not a whole number from 0 to 4294967295
]=]
function RandomSource.deriveSeed(runSeed: number, label: string, index: number): number
	if not isWord(runSeed) then
		error(`runSeed must be a whole number from 0 to {MAX_WORD}, got {runSeed}`, 2)
	end

	if not isWord(index) then
		error(`index must be a whole number from 0 to {MAX_WORD}, got {index}`, 2)
	end

	local seed = runSeed
	for i = 1, #label do
		seed = mixWord(seed, string.byte(label, i))
	end

	return mixWord(seed, index)
end


--[=[
	Draws a boolean, recording 1 for true and 0 for false.

	@return true when the draw is odd, so a zero draw gives false
	@error  when the case draws more than MAX_ZERO_COUNT zeros past the end of a replayed tape
]=]
function RandomSource.drawBoolean(self: RandomSource): boolean
	local isOdd = drawBelow(self, BOOLEAN_COUNT) == 1
	if hasOverrun(self) then
		error(OVERRUN_MESSAGE, 2)
	end

	return isOdd
end


--[=[
	Draws a whole number from `min` to `max`, both ends included.

	A span of 0 takes no draw. Otherwise the tape records the number drawn minus `min`, as one
	word, or as two for a span of 2^32 or more, and a zero word draws `min`.

	@param  min the lowest number that can be drawn, a whole number
	@param  max the highest number that can be drawn, a whole number from `min` to `min + 2^53 - 1`
	@return the number drawn
	@error  when `min` or `max` is not whole, or `max` is not from `min` to `min + 2^53 - 1`
	@error  when the case draws more than MAX_ZERO_COUNT zeros past the end of a replayed tape
]=]
function RandomSource.drawInteger(self: RandomSource, min: number, max: number): number
	if not canDrawInteger(min, max) then
		local requirement = `bounds must be whole numbers with max from min to min + {MAX_SPAN}`
		error(`{requirement}, got {min} to {max}`, 2)
	end

	local span = max - min
	if span == 0 then
		return min
	end

	local drawn = min + drawBelow(self, span + 1)
	if hasOverrun(self) then
		error(OVERRUN_MESSAGE, 2)
	end

	return drawn
end


--[=[
	Draws a number from `min` to `max` at the resolution of 53 bits.

	The number is `min` plus a fraction of `max - min`, the fraction being two words read as a
	53-bit whole number over 2^53. A zero word draws `min`.

	@param  min the lowest number that can be drawn, finite
	@param  max the highest number that can be drawn, finite and at least `min`
	@return the number drawn
	@error  when `min` or `max` is not finite, `max` is below `min`, or `max - min` is not finite
	@error  when the case draws more than MAX_ZERO_COUNT zeros past the end of a replayed tape
]=]
function RandomSource.drawNumber(self: RandomSource, min: number, max: number): number
	if not canDrawNumber(min, max) then
		local requirement = "bounds must be finite numbers in order with a finite difference"
		error(`{requirement}, got {min} to {max}`, 2)
	end

	local range    = max - min
	local fraction = drawWide(self) / WIDE_NUMBER.range
	if hasOverrun(self) then
		error(OVERRUN_MESSAGE, 2)
	end

	return min + fraction * range
end


--[=[
	Draws the next word.

	A source made by `new` draws a fresh word and appends it to its tape. A source made by
	`fromTape` draws the next word of its tape, and zeros once the tape has ended.

	@return a whole number from 0 to 4294967295
	@error  when the case draws more than MAX_ZERO_COUNT zeros past the end of a replayed tape
]=]
function RandomSource.drawWord(self: RandomSource): number
	local word = drawWord(self)
	if hasOverrun(self) then
		error(OVERRUN_MESSAGE, 2)
	end

	return word
end


--[=[
	Tells whether a case drew more than MAX_ZERO_COUNT zeros past the end of a replayed tape.

	@return true once a draw has been refused for that reason
]=]
function RandomSource.hasOverrun(self: RandomSource): boolean
	return hasOverrun(self)
end


--[=[
	Tells whether `value` can be a word of a tape or a seed.

	@param  value the number to test
	@return true when `value` is a whole number from 0 to 4294967295
]=]
function RandomSource.isWord(value: number): boolean
	return isWord(value)
end


--[=[
	Returns a copy of the tape: the words that replay the draws so far, or the tape it replays.

	@return the words in the order they were drawn
	@error  when the source was made by `newUnrecorded`, which keeps no tape
]=]
function RandomSource.tape(self: RandomSource): { number }
	if not self._isRecording then
		error("source must record its draws to give a tape, got one made by newUnrecorded", 2)
	end

	return table.clone(self._tape)
end


return table.freeze(RandomSource)
