--!strict

--[=[
	Sources

	Analyzes the repository's Luau with luau-lsp, which shows what the type checker and the linter
	report.

	This is evidence only, never a verdict on quality.

	The Roblox code is analyzed with the Roblox and build definitions, so the Roblox definitions are
	verified against their pin first.

	The scripts are analyzed with the type definitions that Lute generates for itself.

	Every operation here yields.
]=]


-- Imports -----------------------------------------------------------------------------------------

local Files = require("../system/Files")
local Paths = require("../project/Paths")
local Pins  = require("../project/Pins")
local Tools = require("../system/Tools")
local Types = require("../Types")


-- Module ------------------------------------------------------------------------------------------

local Sources = {}


-- Constants ---------------------------------------------------------------------------------------

--- Globs the files under any `.lute` folder, whose errors are not reported.
const LUTE_FOLDER_GLOB = "**/.lute/**"


--- Globs the type tests, whose deliberate errors are not reported, because `claims` judges them.
const TYPE_TESTS_GLOB = `{Paths.TEST.types}/**`


--- The folders that hold Roblox code, of which only the ones that exist are analyzed.
const ROBLOX_FOLDERS: { read string } = {
	Paths.FOLDER.source,
	Paths.FOLDER.test,
	Paths.FOLDER.bench,
	Paths.FOLDER.harness,
}
table.freeze(ROBLOX_FOLDERS)


-- Private -----------------------------------------------------------------------------------------

--[=[
	Returns the paths among `paths` that are folders.

	@param  paths the paths to look at, in the order to keep
	@return the folders, or why a folder on the way to a path could not be listed
]=]
local function inspectFolders(paths: { read string }): Types.Result<{ string }>
	local folders: { string } = {}
	for _, path in paths do
		local inspected = Files.inspect(path)
		if not inspected.ok then
			return inspected
		end

		local kind = inspected.value
		if kind == nil then
			continue
		end

		if kind == "Folder" then
			table.insert(folders, path)
		end
	end

	return { ok = true, value = folders }
end


local function analyzeRobloxCode(): Types.Result<nil>
	local inspected = inspectFolders(ROBLOX_FOLDERS)
	if not inspected.ok then
		return inspected
	end

	local folders = inspected.value
	if #folders == 0 then
		return { ok = true, value = nil }
	end

	local analyzed = Tools.analyze(folders, {
		platform         = "Roblox",
		definitionByName = { roblox = Paths.DEFINITIONS.roblox, build = Paths.DEFINITIONS.build },
		baseLuaurc       = nil,
		ignores          = { TYPE_TESTS_GLOB },
	})
	if not analyzed.ok then
		return analyzed
	end

	local folderList = table.concat(folders, ", ")
	print(`{folderList} analyzed with the Roblox and build definitions`)

	return analyzed
end


local function analyzeScripts(): Types.Result<nil>
	local generated = Tools.generateLuteDefinitions()
	if not generated.ok then
		return generated
	end

	local analyzed = Tools.analyze({ Paths.FOLDER.scripts }, {
		platform         = "Standard",
		definitionByName = {},
		baseLuaurc       = `{generated.value}/{Paths.LUAURC}`,
		ignores          = { LUTE_FOLDER_GLOB },
	})
	if not analyzed.ok then
		return analyzed
	end

	print(`{Paths.FOLDER.scripts} analyzed with the type definitions that Lute generated`)

	return analyzed
end


-- Public ------------------------------------------------------------------------------------------

--[=[
	Analyzes the Roblox code, then the scripts, and stops at the first error.

	@return nothing, or why the Roblox definitions need setup or an analysis reported an error
]=]
function Sources.analyze(): Types.Result<nil>
	local verified = Pins.verify(Paths.PIN.roblox, Paths.DEFINITIONS.roblox)
	if not verified.ok then
		return { ok = false, error = `{verified.error}; run setup to fetch the Roblox definitions` }
	end

	local analyzed = analyzeRobloxCode()
	if not analyzed.ok then
		return analyzed
	end

	return analyzeScripts()
end


return table.freeze(Sources)
