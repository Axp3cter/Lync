--!strict

--[=[
	Values

	Reads values that come from outside the harness into the types it uses: what a client sends over
	a remote, and what the receiver serves as JSON.

	A value from outside is `unknown` until a conversion here has checked it. Each conversion
	returns the value as the type it names, or nil when the value is not of that type, and none
	trusts a table's contents beyond what it checks.

	This module uses no engine global, so that the scripts may require it.
]=]


-- Imports -----------------------------------------------------------------------------------------

local RandomSource = require("./RandomSource")


-- Module ------------------------------------------------------------------------------------------

local Values = {}


-- Private -----------------------------------------------------------------------------------------

local function toEntries(value: unknown): { read [unknown]: unknown }?
	if typeof(value) ~= "table" then
		return nil
	end

	-- The one cast that trusts nothing: every field it yields is still unknown.
	return value :: { read [unknown]: unknown }
end


local function toNumber(value: unknown): number?
	if typeof(value) ~= "number" then
		return nil
	end

	return value
end


local function toText(value: unknown): string?
	if typeof(value) ~= "string" then
		return nil
	end

	return value
end


-- Public ------------------------------------------------------------------------------------------

--[=[
	Reads a table whose contents are not known.

	@param  value the value to open
	@return the table with every field unknown, nil when `value` is not a table
]=]
function Values.toEntries(value: unknown): { read [unknown]: unknown }?
	return toEntries(value)
end


--[=[
	Reads a number.

	@param  value the value to read
	@return the number, nil when `value` is not a number
]=]
function Values.toNumber(value: unknown): number?
	return toNumber(value)
end


--[=[
	Reads a table whose keys are all text.

	@param  value the value to read
	@return the table with every field unknown, nil when `value` is not a table or has another key
]=]
function Values.toRecord(value: unknown): { read [string]: unknown }?
	local entries = toEntries(value)
	if entries == nil then
		return nil
	end

	for key in entries do
		if typeof(key) ~= "string" then
			return nil
		end
	end

	-- Every key was checked to be text just above, which the checker cannot see.
	return entries :: { read [string]: unknown }
end


--[=[
	Reads a tape: a list of words.

	@param  value the value to read
	@return the words in order, nil when `value` is not a list of whole numbers from 0 to 4294967295
]=]
function Values.toTape(value: unknown): { number }?
	local entries = toEntries(value)
	if entries == nil then
		return nil
	end

	local tape: { number } = {}
	for i = 1, #entries do
		local word = toNumber(entries[i])
		if
			word == nil
			or not RandomSource.isWord(word)
		then
			return nil
		end

		tape[i] = word
	end

	return tape
end


--[=[
	Reads text.

	@param  value the value to read
	@return the text, nil when `value` is not a string
]=]
function Values.toText(value: unknown): string?
	return toText(value)
end


--[=[
	Reads a list of text.

	@param  value the value to read
	@return the texts in order, nil when `value` is not a list or holds anything but text
]=]
function Values.toTexts(value: unknown): { string }?
	local entries = toEntries(value)
	if entries == nil then
		return nil
	end

	local texts: { string } = {}
	for i = 1, #entries do
		local text = toText(entries[i])
		if text == nil then
			return nil
		end

		texts[i] = text
	end

	return texts
end


return table.freeze(Values)
