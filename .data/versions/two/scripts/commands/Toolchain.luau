--!strict

--[=[
	Toolchain

	Installs what the repository scripts, the type checker and generation need, in the order that
	each step relies on the one before.

	The pinned tools come first, because the later steps run them.

	Lute then writes the definitions that luau-lsp reads for `scripts/`.

	The Roblox definitions follow, then the Roblox API dump, which supplies the enum item values
	that the definitions lack.

	Each of those two files is fetched from its pin unless the file on disk already matches it.

	Every operation here yields.

	A failure comes back as a Result whose clause is the failing step's own.
]=]


-- Imports -----------------------------------------------------------------------------------------

local Paths = require("../project/Paths")
local Pins  = require("../project/Pins")
local Tools = require("../system/Tools")
local Types = require("../Types")


-- Module ------------------------------------------------------------------------------------------

local Toolchain = {}


-- Private -----------------------------------------------------------------------------------------

--[=[
	Fetches the file that a pin names, unless the file on disk already matches the pin.

	A file that already matches is left alone, so setup works offline once it has run.

	@param  pinPath  the pin file that names the address and the digest
	@param  filePath where the verified download is kept
	@return a success once the file matches its pin, or why it could not be fetched
]=]
local function fetchUnlessCurrent(pinPath: string, filePath: string): Types.Result<nil>
	local verified = Pins.verify(pinPath, filePath)
	if verified.ok then
		print(`"{filePath}" was already current with "{pinPath}"`)
		return verified
	end

	local fetched = Pins.fetch(pinPath, filePath)
	if not fetched.ok then
		return fetched
	end

	print(`"{filePath}" was fetched from the address in "{pinPath}"`)

	return fetched
end


-- Public ------------------------------------------------------------------------------------------

--[=[
	Installs the pinned tools, the Lute definitions, the Roblox definitions and the Roblox API
	dump, in that order.

	The first step that fails stops the rest.

	@return a success once every step is done, or the clause of the step that failed
]=]
function Toolchain.install(): Types.Result<nil>
	local installed = Tools.install()
	if not installed.ok then
		return installed
	end

	local generated = Tools.generateLuteDefinitions()
	if not generated.ok then
		return generated
	end

	local fetchedDefinitions = fetchUnlessCurrent(Paths.PIN.roblox, Paths.DEFINITIONS.roblox)
	if not fetchedDefinitions.ok then
		return fetchedDefinitions
	end

	return fetchUnlessCurrent(Paths.PIN.apiDump, Paths.FILE.apiDump)
end


return table.freeze(Toolchain)
