--!strict

--[=[
	Types

	Holds the types and type functions that the harness modules share.

	Only types live here: requiring this module builds an empty table and does nothing else.

	Requirers name a type through it, as Types.Complete<{ read [Profile]: Budget }>.
]=]


-- Module ------------------------------------------------------------------------------------------

local Types = {}


-- Types -------------------------------------------------------------------------------------------

--[=[
	The outcome of an operation that can fail for a cause outside the harness.

	Callers frame `error` in the recovery mold: `could not send the report; printing it: {error}`.

	@field ok    which of the two outcomes this is: true when the operation succeeded
	@field value what the operation produced, present only when `ok` is true
	@field error a clause naming the subject and the cause, present only when `ok` is false
]=]
export type Result<T> =
	| { read ok: true, read value: T }
	| { read ok: false, read error: string }


--[=[
	Makes every key that a lookup table type's indexer allows a required field.

	@param  lookupType a table type whose indexer's key type lists the keys
	@return `lookupType` with each of those keys added as a read-only field
	@error  when `lookupType` has no indexer
]=]
export type function Complete(lookupType)
	local indexer = lookupType:readindexer()
	if indexer == nil then
		error("Complete must be given a table type with an indexer")
	end

	local keyType  = indexer.index
	local keys     = if keyType:is("union") then keyType:components() else { keyType }
	local complete = types.copy(lookupType)
	for _, key in keys do
		complete:setreadproperty(key, indexer.result)
	end

	return complete
end


--[=[
	Gives the type of the values that a table of generators draws, one field for each generator.

	@param  generatorsType a table type whose readable properties are functions that return a value
	@return a table type with the same keys, each of the type that its generator returns
	@error  when a property cannot be read or is not a function that returns a value
]=]
export type function Drawn(generatorsType)
	local drawn = types.newtable()
	for key, property in generatorsType:properties() do
		local generatorType = property.read
		if generatorType == nil then
			error("Drawn must be given properties that can be read")
		end

		local returned = generatorType:returns().head
		if returned == nil then
			error("Drawn must be given properties that return a value")
		end

		drawn:setproperty(key, returned[1])
	end

	return drawn
end


return table.freeze(Types)
