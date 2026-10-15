--!strict

--[=[
	Types

	Holds the types that the repository scripts share.

	Only types live here: requiring this module builds an empty table and does nothing else.

	Requirers name a type through it, as Types.Result<string>.
]=]


-- Module ------------------------------------------------------------------------------------------

local Types = {}


-- Types -------------------------------------------------------------------------------------------

--[=[
	The outcome of an operation that can fail for a cause outside the scripts.

	Callers frame `error` in the recovery mold: `could not read the pin; stopping: {result.error}`.

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


return table.freeze(Types)
