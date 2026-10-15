--!strict

--[=[
	Requires

	Audits the require calls in a variant's output folder for the ones that break in Roblox but pass
	on Windows.

	Every operation here yields.

	A require resolves as darklua's `luau` require mode resolves it. A relative path starts from the
	folder of the requiring file, except in `init.luau`, which stands for its folder and so starts
	from that folder's parent.

	`@self/` starts from the folder of the requiring file, which holds the children of an init
	module.

	A path reaches `X.luau`, `X.lua`, `X/init.luau` or `X/init.lua`, in that order.

	darklua rewrites any alias other than `@self` and any path that is not relative, so the audit
	skips them.

	The audit adds a case check to darklua's resolution: the module file must be spelled on disk as
	the require spells it, because Roblox instance names are case-sensitive and Windows is not.

	The audit adds an escape check as well: a require that resolves outside the folder is reported,
	because Rojo does not mount what lies outside the output folder.

	Requires are found by pattern, so one inside a comment is audited too.
]=]


-- Imports -----------------------------------------------------------------------------------------

local Files = require("../system/Files")
local Types = require("../Types")


-- Module ------------------------------------------------------------------------------------------

local Requires = {}


-- Types -------------------------------------------------------------------------------------------

type RequireCall = { read line: number, read text: string }


--[=[
	A module file that a require reaches.

	@field path     the file as the require spells it
	@field spelling the file as the disk spells it, which differs from `path` only in case
]=]
type ModuleFile = {
	read path:     string,
	read spelling: string,
}


-- Constants ---------------------------------------------------------------------------------------

--- The names of an init module file, which stands for its folder.
const INIT_FILE_NAMES: { string } = {
	"init.luau",
	"init.lua",
}
table.freeze(INIT_FILE_NAMES)


--- The extensions of a module file, in the order that darklua tries them.
const MODULE_EXTENSIONS: { read string } = {
	".luau",
	".lua",
}
table.freeze(MODULE_EXTENSIONS)


--[=[
	Captures the quote and the text of a `require("…")` or `require('…')` call.

	The frontier rejects a `.` or `:` in front of `require`, so a method of that name does not
	match.

	The frontier leaves the character in front unread, so a call right after another is found.
]=]
const REQUIRE_PATTERN = "%f[%w_.:]require%s*%(%s*([\"'])(.-)%1%s*%)"


--- Matches the name of a Luau source file, which ends in `.luau` or `.lua`.
const SOURCE_FILE_PATTERN = "%.luau?$"


-- Private -----------------------------------------------------------------------------------------

local function isInitFile(file: string): boolean
	local names = string.split(file, "/")
	local name  = names[#names]
	return table.find(INIT_FILE_NAMES, name) ~= nil
end


local function requiresOf(source: string): { RequireCall }
	local requireCalls: { RequireCall } = {}
	for i, line in string.split(source, "\n") do
		for _, text in string.gmatch(line, REQUIRE_PATTERN) do
			table.insert(requireCalls, { line = i, text = text })
		end
	end

	return requireCalls
end


--[=[
	Follows `segments` from the folder `folderNames`.

	@param  folderNames the names of the folder that the segments start from
	@param  segments    the segments of a require's path, where ".." leaves a folder
	@return the names of the path, where each leading ".." stands for a climb above the root
]=]
local function follow(folderNames: { string }, segments: { read string }): { string }
	local names = table.clone(folderNames)
	for _, segment in segments do
		if segment == "" or segment == "." then
			continue
		end

		if segment ~= ".." then
			table.insert(names, segment)
		elseif
			#names > 0
			and names[#names] ~= ".."
		then
			table.remove(names)
		else
			-- With no name left to leave, ".." stays, which shows a climb above the root.
			table.insert(names, "..")
		end
	end

	return names
end


--[=[
	Works out the names of the path that a require reaches, without looking at the disk.

	@param  file the path of the requiring file
	@param  text the text of the require, as it is written between the quotes
	@return the names of the path, nil for an alias or a path that is not relative, which is skipped
]=]
local function targetOf(file: string, text: string): { string }?
	local segments = string.split(text, "/")
	local first    = string.lower(segments[1])

	local folderNames = string.split(file, "/")
	table.remove(folderNames)

	if first == "@self" then
		table.remove(segments, 1)
		return follow(folderNames, segments)
	elseif first == "." or first == ".." then
		-- An init module stands for its folder, so its relative requires start above the folder.
		if isInitFile(file) then
			table.remove(folderNames)
		end

		return follow(folderNames, segments)
	end

	return nil
end


--[=[
	Tells whether the path of `names` lies inside `folder`, ignoring case.

	@param  names  the names of a path
	@param  folder the folder that the path should lie inside
	@return true when `names` begin with the names of `folder`
]=]
local function isUnder(names: { read string }, folder: string): boolean
	local folderNames = string.split(folder, "/")
	if #names < #folderNames then
		return false
	end

	for i, folderName in folderNames do
		if string.lower(names[i]) ~= string.lower(folderName) then
			return false
		end
	end

	return true
end


--[=[
	Returns the module files that `modulePath` may reach, in the order that darklua tries them.

	@param  modulePath the path of a module, without its extension
	@return `modulePath` with each extension, then with "/" and each init file name
]=]
local function candidatesOf(modulePath: string): { string }
	local candidateCount = #MODULE_EXTENSIONS + #INIT_FILE_NAMES
	local candidates     = table.create(candidateCount) :: { string }
	for _, extension in MODULE_EXTENSIONS do
		table.insert(candidates, `{modulePath}{extension}`)
	end

	for _, initFileName in INIT_FILE_NAMES do
		table.insert(candidates, `{modulePath}/{initFileName}`)
	end

	return candidates
end


--[=[
	Returns the part of `spelling` from the first name that differs from `path`.

	@param  spelling a path as the disk spells it
	@param  path     the same path as a require spells it, which differs only in case
	@return the names of `spelling` from the first one that is not spelled as in `path`
]=]
local function differingTailOf(spelling: string, path: string): string
	local spellingNames = string.split(spelling, "/")
	local pathNames     = string.split(path, "/")
	for i, name in spellingNames do
		if name ~= pathNames[i] then
			return table.concat(spellingNames, "/", i)
		end
	end

	return spelling
end


local function frameProblem(file: string, requireCall: RequireCall, problem: string): string
	return `"{file}" line {requireCall.line} requires "{requireCall.text}", which {problem}`
end


--[=[
	Fetches how the disk spells the module file `path`.

	@param  path a candidate path for a module file, in any case
	@return the spelling on disk, nil when no file is there, or why the disk could not be read
]=]
local function fetchSpelling(path: string): Types.Result<string?>
	local resolved = Files.resolveCase(path)
	if not resolved.ok then
		return resolved
	end

	local spelling = resolved.value
	if spelling == nil then
		return { ok = true, value = nil }
	end

	local inspected = Files.inspect(spelling)
	if not inspected.ok then
		return inspected
	end

	local kind = inspected.value
	if kind == nil then
		return { ok = true, value = nil }
	end

	if kind == "File" then
		return { ok = true, value = spelling }
	end

	return { ok = true, value = nil }
end


--[=[
	Fetches the module file that `modulePath` reaches.

	A candidate spelled exactly as written is preferred to one that differs only in case.

	@param  modulePath the path of a module, without its extension
	@return the module file, nil when none is there, or why the disk could not be read
]=]
local function fetchModuleFile(modulePath: string): Types.Result<ModuleFile?>
	local candidates = candidatesOf(modulePath)
	for _, candidate in candidates do
		local inspected = Files.inspect(candidate)
		if not inspected.ok then
			return inspected
		end

		local kind = inspected.value
		if kind == nil then
			continue
		end

		if kind == "File" then
			local exactFile: ModuleFile = { path = candidate, spelling = candidate }
			return { ok = true, value = exactFile }
		end
	end

	for _, candidate in candidates do
		local fetched = fetchSpelling(candidate)
		if not fetched.ok then
			return fetched
		end

		local spelling = fetched.value
		if spelling == nil then
			continue
		end

		local looseFile: ModuleFile = { path = candidate, spelling = spelling }
		return { ok = true, value = looseFile }
	end

	return { ok = true, value = nil }
end


--[=[
	Fetches what is wrong with the module that `modulePath` reaches.

	@param  modulePath the path of a module, without its extension
	@return the problem, nil when the module is there as written, or why the disk could not be read
]=]
local function fetchModuleProblem(modulePath: string): Types.Result<string?>
	local fetched = fetchModuleFile(modulePath)
	if not fetched.ok then
		return fetched
	end

	local moduleFile = fetched.value
	if moduleFile == nil then
		return { ok = true, value = "reaches no module" }
	end

	if moduleFile.spelling == moduleFile.path then
		return { ok = true, value = nil }
	end

	local spellingTail = differingTailOf(moduleFile.spelling, moduleFile.path)
	return { ok = true, value = `the disk spells "{spellingTail}"` }
end


--[=[
	Fetches what is wrong with one require call of one file.

	@param  file        the path of the requiring file
	@param  requireCall the require to examine
	@param  folder      the output folder that the require must not leave
	@return the problem, nil when the require is sound or skipped, or why the disk could not be read
]=]
local function fetchRequireProblem(
	file:        string,
	requireCall: RequireCall,
	folder:      string
): Types.Result<string?>
	local names = targetOf(file, requireCall.text)
	if names == nil then
		return { ok = true, value = nil }
	end

	if not isUnder(names, folder) then
		return { ok = true, value = `leaves "{folder}"` }
	end

	local modulePath = table.concat(names, "/")
	if not Files.isRelativePath(modulePath) then
		return { ok = true, value = "holds a backslash or a colon in a name" }
	end

	return fetchModuleProblem(modulePath)
end


local function readProblems(file: string, folder: string): Types.Result<{ string }>
	local read = Files.read(file)
	if not read.ok then
		return read
	end

	local problems: { string } = {}
	for _, requireCall in requiresOf(read.value) do
		local fetched = fetchRequireProblem(file, requireCall, folder)
		if not fetched.ok then
			return fetched
		end

		local problem = fetched.value
		if problem ~= nil then
			table.insert(problems, frameProblem(file, requireCall, problem))
		end
	end

	return { ok = true, value = problems }
end


-- Public ------------------------------------------------------------------------------------------

--[=[
	Finds the requires under the folder `folder` that break in Roblox but pass on Windows.

	Only `.luau` and `.lua` files are read.

	A problem is one clause naming the file, the line, the require text and what is wrong, as in
	`"build/test/src/Foo.luau" line 3 requires "./bar", which the disk spells "Bar.luau"`.

	@param  folder the output folder of a variant, relative to the working directory
	@return the problems in file order, empty when sound, or why a file could not be read
	@error  when `folder` is not relative names joined by "/"
]=]
function Requires.audit(folder: string): Types.Result<{ string }>
	if not Files.isRelativePath(folder) then
		error(`folder must be relative names joined by "/", got "{folder}"`, 2)
	end

	local listed = Files.list(folder)
	if not listed.ok then
		return listed
	end

	local problems: { string } = {}
	for _, file in listed.value do
		if string.find(file, SOURCE_FILE_PATTERN) == nil then
			continue
		end

		local read = readProblems(file, folder)
		if not read.ok then
			return read
		end

		local fileProblems = read.value
		table.move(fileProblems, 1, #fileProblems, #problems + 1, problems)
	end

	return { ok = true, value = problems }
end


return table.freeze(Requires)
