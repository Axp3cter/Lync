--!strict

--[=[
	Golden

	Reads the golden index, `test/golden/index.json`, and its `.bin` files (m1-plan.md §4.4), from
	the repo root.

	An entry holds either a file of bytes or, for a vector that ends inside a byte, `bits`: the
	vector's bits in stream order as a string of "0" and "1".
]=]

-- Imports -----------------------------------------------------------------------------------------

local fs = require("@lune/fs")
local serde = require("@lune/serde")

-- Module ------------------------------------------------------------------------------------------

local Golden = {}

-- Types -------------------------------------------------------------------------------------------

--[=[
	One golden vector.

	@field id        the vector's name, such as "G2"
	@field file      the `.bin` file under `test/golden/`, nil when `bits` is set
	@field bits      the bits in stream order, nil when `file` is set
	@field milestone the milestone that must reproduce it
	@field what      what the vector encodes
	@field design    where the vector is specified
]=]
export type Entry = {
	id: string,
	file: string?,
	bits: string?,
	milestone: number,
	what: string,
	design: string,
}

-- Constants ---------------------------------------------------------------------------------------

const GOLDEN_DIRECTORY = "test/golden"

-- Public ------------------------------------------------------------------------------------------

--[=[
	Returns a vector's bytes.

	@param  entry a vector whose `file` is set
	@return the contents of its `.bin` file
	@error  when the entry has no file
]=]
function Golden.bytes(entry: Entry): buffer
	local file = entry.file
	if file == nil then
		error(`golden vector {entry.id} must have a file`, 2)
	end

	return buffer.fromstring(fs.readFile(`{GOLDEN_DIRECTORY}/{file}`))
end

--[=[
	Returns every vector of the index, in index order.

	@return the entries
]=]
function Golden.entries(): { Entry }
	return serde.decode("json", fs.readFile(`{GOLDEN_DIRECTORY}/index.json`))
end

--[=[
	Returns the vector with a given id.

	@param  id the vector's name
	@return its entry
	@error  when the index has no such vector
]=]
function Golden.entry(id: string): Entry
	for _, entry in Golden.entries() do
		if entry.id == id then
			return entry
		end
	end

	error(`golden index must hold {id}`, 2)
end

return table.freeze(Golden)
