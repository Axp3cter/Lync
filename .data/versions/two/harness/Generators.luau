--!strict

--[=[
	Generators

	Builds generators, the functions that draw one value from a RandomSource, out of a few basic
	draws and out of other generators.

	A generator draws in the order its arguments are written, and a zero draw builds its simplest
	value: the lowest number, the first choice, the shortest array. That is what lets Tapes shrink a
	case by lowering the words of its tape.

	A mistake in the arguments of a combinator is thrown where the generator is built, not where it
	first draws.
]=]


-- Imports -----------------------------------------------------------------------------------------

local RandomSource = require("./RandomSource")
local Types        = require("./Types")


-- Module ------------------------------------------------------------------------------------------

local Generators = {}


-- Types -------------------------------------------------------------------------------------------

--[=[
	One way of building a value, with how often it is chosen.

	@field weight    how often this entry is chosen against the others, a whole number of at least 1
	@field generator builds the value when this entry is chosen
]=]
export type Entry<T> = {
	read weight:    number,
	read generator: RandomSource.Generator<T>,
}


-- Constants ---------------------------------------------------------------------------------------

--- The most draws that a filter makes before it gives up on a case.
const MAX_FILTER_DRAWS = 100


--- The widest `wholeNumber` builds, in bits: one word, so that its value is one word of the tape.
const MAX_WHOLE_WIDTH = 32


--- The base of the bit widths that `wholeNumber` draws.
const BINARY_BASE = 2


--- The most that the weights of a `frequency` may total, so that the total is an exact number.
const MAX_TOTAL_WEIGHT = 2 ^ 53


-- Private -----------------------------------------------------------------------------------------

local function drawWholeNumber(source: RandomSource.RandomSource): number
	local width   = source:drawInteger(0, MAX_WHOLE_WIDTH)
	local largest = BINARY_BASE ^ width - 1

	return source:drawInteger(0, largest)
end


-- Public ------------------------------------------------------------------------------------------

--[=[
	Builds a generator of arrays: a length, and then that many elements.

	The length is drawn first, so shrinking a tape shortens an array before it changes elements.

	@param  element   builds each element
	@param  minLength the fewest elements, a whole number of 0 or more
	@param  maxLength the most elements, a whole number of at least `minLength`
	@return a generator of arrays of from `minLength` to `maxLength` elements
	@error  when the lengths are not whole numbers in order, or `minLength` is below 0
]=]
function Generators.array<T>(
	element:   RandomSource.Generator<T>,
	minLength: number,
	maxLength: number
): RandomSource.Generator<{ T }>
	if not RandomSource.canDrawInteger(minLength, maxLength) then
		error(`array lengths must be whole numbers in order, got {minLength} to {maxLength}`, 2)
	end

	if minLength < 0 then
		error(`minLength must be 0 or more, got {minLength}`, 2)
	end

	return function(source: RandomSource.RandomSource): { T }
		local length   = source:drawInteger(minLength, maxLength)
		local elements = table.create(length) :: { T }
		for i = 1, length do
			elements[i] = element(source)
		end

		return elements
	end
end


--[=[
	Builds a generator whose second draw depends on its first.

	@param  generator draws the first value
	@param  build     builds the generator for the second draw from the first value
	@return a generator that draws a value, builds a generator from it, and draws from that
]=]
function Generators.bind<T, U>(
	generator: RandomSource.Generator<T>,
	build:     (drawn: T) -> RandomSource.Generator<U>
): RandomSource.Generator<U>
	return function(source: RandomSource.RandomSource): U
		local dependent = build(generator(source))

		return dependent(source)
	end
end


--[=[
	Returns the generator of booleans, which draws false for a zero draw.

	@return a generator of true and false
]=]
function Generators.boolean(): RandomSource.Generator<boolean>
	return RandomSource.drawBoolean
end


--[=[
	Builds a generator that picks one of some values.

	@param  values the values to pick from, at least one; a zero draw picks the first
	@return a generator of the values, each as likely as another
	@error  when `values` is empty
]=]
function Generators.choice<T>(values: { T }): RandomSource.Generator<T>
	local count = #values
	if count == 0 then
		error("values must hold at least one value, got none", 2)
	end

	local snapshot = table.clone(values)

	return function(source: RandomSource.RandomSource): T
		local position = source:drawInteger(1, count)
		return snapshot[position]
	end
end


--[=[
	Builds a generator that draws nothing and always gives the same value.

	@param  value the value to give
	@return a generator of `value`
]=]
function Generators.constant<T>(value: T): RandomSource.Generator<T>
	return function(): T
		return value
	end
end


--[=[
	Builds a generator of the values of another that a test accepts.

	A value that is not accepted is drawn again, up to MAX_FILTER_DRAWS draws, and then the case
	fails with an error, because a generator that rejects nearly everything is a mistake to fix.

	@param  generator  draws each candidate value
	@param  shouldKeep whether a candidate is accepted
	@return a generator of the accepted values
]=]
function Generators.filter<T>(
	generator:  RandomSource.Generator<T>,
	shouldKeep: (candidate: T) -> boolean
): RandomSource.Generator<T>
	return function(source: RandomSource.RandomSource): T
		for _ = 1, MAX_FILTER_DRAWS do
			local candidate = generator(source)
			if shouldKeep(candidate) then
				return candidate
			end
		end

		error(`filter must accept a value within {MAX_FILTER_DRAWS} draws, got none`)
	end
end


--[=[
	Builds a generator that picks one of some entries, as often as its weight says.

	@param  entries the ways to build a value, at least one; a zero draw picks the first
	@return a generator that picks an entry by weight and draws from its generator
	@error  when `entries` is empty, or a weight is not a whole number of at least 1
	@error  when the weights total more than 2^53
]=]
function Generators.frequency<T>(entries: { Entry<T> }): RandomSource.Generator<T>
	local count = #entries
	if count == 0 then
		error("entries must hold at least one entry, got none", 2)
	end

	local snapshot    = table.create(count) :: { Entry<T> }
	local totalWeight = 0
	for i, entry in entries do
		if not RandomSource.canDrawInteger(1, entry.weight) then
			error(`entries[{i}].weight must be a whole number of at least 1, got {entry.weight}`, 2)
		end

		-- Tested before the sum is taken, since a sum above 2^53 rounds and would pass unseen.
		if entry.weight > MAX_TOTAL_WEIGHT - totalWeight then
			local requirement = "entries must weigh at most 2^53 together"
			error(`{requirement}, got {totalWeight} and then {entry.weight} at entries[{i}]`, 2)
		end

		totalWeight += entry.weight

		-- Each entry is copied, so that a later change to an entry does not change the draws.
		snapshot[i] = { weight = entry.weight, generator = entry.generator }
	end

	return function(source: RandomSource.RandomSource): T
		local remaining = source:drawInteger(1, totalWeight)
		for i = 1, count - 1 do
			local entry = snapshot[i]
			if remaining <= entry.weight then
				return entry.generator(source)
			end

			remaining -= entry.weight
		end

		return snapshot[count].generator(source)
	end
end


--[=[
	Builds a generator of whole numbers from `min` to `max`.

	@param  min the lowest number, a whole number; a zero draw gives it
	@param  max the highest number, a whole number from `min` to `min + 2^53 - 1`
	@return a generator of the numbers, each as likely as another
	@error  when the bounds are not whole numbers in order, or are 2^53 or more apart
]=]
function Generators.integer(min: number, max: number): RandomSource.Generator<number>
	if not RandomSource.canDrawInteger(min, max) then
		error(`integer bounds must be whole numbers in order, got {min} to {max}`, 2)
	end

	return function(source: RandomSource.RandomSource): number
		return source:drawInteger(min, max)
	end
end


--[=[
	Builds a generator that changes each value of another.

	@param  generator draws the value to change
	@param  transform builds the new value from the drawn one
	@return a generator of the new values
]=]
function Generators.map<T, U>(
	generator: RandomSource.Generator<T>,
	transform: (drawn: T) -> U
): RandomSource.Generator<U>
	return function(source: RandomSource.RandomSource): U
		return transform(generator(source))
	end
end


--[=[
	Builds a generator of numbers from `min` to `max` at the resolution of 53 bits.

	@param  min the lowest number, finite; a zero draw gives it
	@param  max the highest number, finite and at least `min`
	@return a generator of the numbers
	@error  when the bounds are not finite and in order, or `max - min` is not finite
]=]
function Generators.number(min: number, max: number): RandomSource.Generator<number>
	if not RandomSource.canDrawNumber(min, max) then
		error(`number bounds must be finite and in order, got {min} to {max}`, 2)
	end

	return function(source: RandomSource.RandomSource): number
		return source:drawNumber(min, max)
	end
end


--[=[
	Builds a generator that picks one of some generators and draws from it.

	@param  generators the generators to pick from, at least one; a zero draw picks the first
	@return a generator that draws from one of `generators`, each as likely as another
	@error  when `generators` is empty
]=]
function Generators.oneOf<T>(generators: { RandomSource.Generator<T> }): RandomSource.Generator<T>
	local count = #generators
	if count == 0 then
		error("generators must hold at least one generator, got none", 2)
	end

	local snapshot = table.clone(generators)

	return function(source: RandomSource.RandomSource): T
		local position = source:drawInteger(1, count)
		return snapshot[position](source)
	end
end


--[=[
	Builds a generator of records: one value for each field of a table of generators.

	The fields are drawn in the order of their names, whatever order the engine traverses `shape`
	in, so that one tape always builds the same record.

	@param  shape a table from field names to the generators that draw them
	@return a generator of tables with the same field names and the values their generators draw
]=]
function Generators.record<TShape>(
	shape: TShape & { read [string]: RandomSource.Generator<unknown> }
): RandomSource.Generator<Types.Drawn<TShape>>
	local generatorByField: { read [string]: RandomSource.Generator<unknown> } = shape

	local fields: { string } = {}
	for field in generatorByField do
		table.insert(fields, field)
	end

	table.sort(fields)

	local generators = table.create(#fields) :: { RandomSource.Generator<unknown> }
	for i, field in fields do
		generators[i] = generatorByField[field]
	end

	return function(source: RandomSource.RandomSource): Types.Drawn<TShape>
		local drawn: { [string]: unknown } = {}
		for i, field in fields do
			drawn[field] = generators[i](source)
		end

		-- The fields come from `shape` through a type function that the checker cannot match here.
		return drawn :: any
	end
end


--[=[
	Builds a generator of nested values: a depth, and then a leaf grown that many times.

	The depth is drawn first, so shrinking a tape makes the value shallower before it changes
	anything else, and a zero draw builds a leaf.

	@param  leaf     builds a value of depth 0
	@param  grow     builds the generator of the next depth from the generator of the depth below
	@param  maxDepth the deepest nesting, a whole number of 0 or more
	@return a generator of values from depth 0 to `maxDepth`
	@error  when `maxDepth` is not a whole number of 0 or more
]=]
function Generators.recursive<T>(
	leaf:     RandomSource.Generator<T>,
	grow:     (inner: RandomSource.Generator<T>) -> RandomSource.Generator<T>,
	maxDepth: number
): RandomSource.Generator<T>
	if not RandomSource.canDrawInteger(0, maxDepth) then
		error(`maxDepth must be a whole number of 0 or more, got {maxDepth}`, 2)
	end

	return function(source: RandomSource.RandomSource): T
		local depth   = source:drawInteger(0, maxDepth)
		local current = leaf
		for _ = 1, depth do
			current = grow(current)
		end

		return current(source)
	end
end


--[=[
	Returns the generator of whole numbers from 0 to 2^32 - 1 of every size.

	It draws the width of the number in bits first and then a number of that width, so that small
	numbers and large ones are both common, and a zero draw gives 0. A number needs one word of the
	tape, so shrinking can lower it without moving the words after it. For wider numbers use
	`integer` on its own, or beside this one in `oneOf`.

	@return a generator of whole numbers
]=]
function Generators.wholeNumber(): RandomSource.Generator<number>
	return drawWholeNumber
end


return table.freeze(Generators)
