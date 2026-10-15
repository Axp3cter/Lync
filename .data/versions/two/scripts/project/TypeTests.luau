--!strict

--[=[
	TypeTests

	Runs the Luau type tests: it analyzes `test/types` with luau-lsp and the Roblox and build
	definitions, and judges each claim that a note in those files marks.

	A note `-- proves <id>;` marks the line below it, which must have at least one type or syntax
	error. A note `-- infers <id>;` marks the line below it, which must have no finding at all.

	A line that no `proves` note marks must have no finding either, lint warnings included, so
	that a stray mistake in a type test cannot hide.

	The words of an error are never compared, so luau-lsp rewording a message breaks no test.

	A vendored folder, `node_modules`, is not analyzed, because its files are other people's.

	A claim is Proved when every line that its notes mark behaves as the note says, and Failing
	when one does not. A claim that no note marks has no state here.

	A note that stands outside `test/types` is a problem, because nothing would ever run it.

	The Typed and Inferred claims are checked here. The Declared claims wait for tsc.

	Every operation here yields.

	A failure outside the scripts, such as luau-lsp not starting, comes back as a Result.
]=]


-- Imports -----------------------------------------------------------------------------------------

local Citations = require("./Citations")
local Files     = require("../system/Files")
local Paths     = require("./Paths")
local Pins      = require("./Pins")
local Spec      = require("./Spec")
local stringext = require("@std/stringext")
local Tools     = require("../system/Tools")
local Types     = require("../Types")


-- Module ------------------------------------------------------------------------------------------

local TypeTests = {}


-- Types -------------------------------------------------------------------------------------------

--- Where a claim stands after the type tests.
export type State =
	| "Proved"
	| "Failing"


--[=[
	What the type tests found.

	@field stateByClaimId the state of each claim that a note marks, by the claim's id
	@field problems       the marked lines that misbehave and the findings on unmarked lines
]=]
export type Contents = {
	read stateByClaimId: { read [string]: State },
	read problems:       { string },
}


-- Constants ---------------------------------------------------------------------------------------

--- The extension of a Luau file.
const LUAU_EXTENSION = ".luau"


-- Private -----------------------------------------------------------------------------------------

--[=[
	Sorts the notes that mark lines of type tests by the verb that begins them.

	@param  cited    what the tests cite, whose notes are among its citations
	@param  problems where a note outside `test/types` is reported
	@return the `proves` notes, which want an error below them
	@return the `infers` notes, which want no finding below them
]=]
local function notesOf(
	cited:    Citations.Contents,
	problems: { string }
): ({ Citations.Citation }, { Citations.Citation })
	local typesPrefix = `{Paths.TEST.types}/`

	local provesNotes: { Citations.Citation } = {}
	local infersNotes: { Citations.Citation } = {}
	for _, citation in cited.citations do
		if citation.form ~= "TypedNote" and citation.form ~= "InferredNote" then
			continue
		end

		if not stringext.hasPrefix(citation.path, typesPrefix) then
			local requirement = `type proof note must stand in {Paths.TEST.types}`
			table.insert(problems, `{citation.location}: {requirement}, got one outside it`)
			continue
		end

		if citation.form == "TypedNote" then
			table.insert(provesNotes, citation)
		else
			table.insert(infersNotes, citation)
		end
	end

	return provesNotes, infersNotes
end


--[=[
	Lists the Luau files under `test/types`.

	@return the paths, or why the folder could not be listed, which is no failure when it is missing
]=]
local function listTypeFiles(): Types.Result<{ string }>
	local folder    = Paths.TEST.types
	local inspected = Files.inspect(folder)
	if not inspected.ok then
		return inspected
	end

	local kind = inspected.value
	if kind == nil then
		return { ok = true, value = {} }
	end

	if kind ~= "Folder" then
		local requirement = `{folder} must be a folder in the working directory`
		return { ok = false, error = `{requirement}, got {kind}` }
	end

	local listed = Files.list(folder)
	if not listed.ok then
		return listed
	end

	local files: { string } = {}
	for _, path in listed.value do
		if
			stringext.hasSuffix(path, LUAU_EXTENSION)
			and not Citations.isVendored(path)
		then
			table.insert(files, path)
		end
	end

	return { ok = true, value = files }
end


local function diagnoseTypes(): Types.Result<{ Tools.Diagnostic }>
	local verified = Pins.verify(Paths.PIN.roblox, Paths.DEFINITIONS.roblox)
	if not verified.ok then
		return { ok = false, error = `{verified.error}; run setup to fetch the Roblox definitions` }
	end

	local options: Tools.AnalysisOptions = {
		platform         = "Roblox",
		definitionByName = {
			roblox = Paths.DEFINITIONS.roblox,
			build  = Paths.DEFINITIONS.build,
		},
		baseLuaurc       = nil,
		ignores          = { `**/{Citations.VENDORED_FOLDER}/**` },
	}

	return Tools.diagnose({ Paths.TEST.types }, options)
end


local function groupByPlace(
	diagnostics: { read Tools.Diagnostic }
): { [string]: { Tools.Diagnostic } }
	local diagnosticsByPlace: { [string]: { Tools.Diagnostic } } = {}
	for _, diagnostic in diagnostics do
		local place   = Spec.locationOf(diagnostic.path, diagnostic.line)
		local atPlace = diagnosticsByPlace[place]
		if atPlace == nil then
			atPlace                   = {}
			diagnosticsByPlace[place] = atPlace
		end

		table.insert(atPlace, diagnostic)
	end

	return diagnosticsByPlace
end


local function hasError(diagnostics: { read Tools.Diagnostic }): boolean
	for _, diagnostic in diagnostics do
		if diagnostic.isError then
			return true
		end
	end

	return false
end


local function recordState(
	stateByClaimId: { [string]: State },
	claimId:        string,
	isRight:        boolean
): ()
	if not isRight then
		stateByClaimId[claimId] = "Failing"
		return
	end

	if stateByClaimId[claimId] == nil then
		stateByClaimId[claimId] = "Proved"
	end
end


--[=[
	Reports the findings on lines that no `proves` note marks.

	@param diagnostics  every finding of the run
	@param provesPlaces the lines that a `proves` note marks, where findings are expected
	@param problems     where each unexpected finding is reported, once
]=]
local function findUnexpected(
	diagnostics:  { read Tools.Diagnostic },
	provesPlaces: { read [string]: true },
	problems:     { string }
): ()
	local seenProblems: { [string]: true } = {}
	for _, diagnostic in diagnostics do
		local place = Spec.locationOf(diagnostic.path, diagnostic.line)
		if provesPlaces[place] then
			continue
		end

		local requirement = 'line must have no finding unless a "-- proves" note marks it'
		local problem     = `{place}: {requirement}, got {diagnostic.name}: {diagnostic.message}`
		if seenProblems[problem] then
			continue
		end

		seenProblems[problem] = true
		table.insert(problems, problem)
	end
end


-- Public ------------------------------------------------------------------------------------------

--[=[
	Analyzes `test/types` and judges the claims that its notes mark.

	Luau-lsp does not run when no Luau file stands in `test/types`.

	@param  cited what the tests cite, whose type proof notes mark the lines to judge
	@return the state of each marked claim and the problems, or why luau-lsp could not run
]=]
function TypeTests.run(cited: Citations.Contents): Types.Result<Contents>
	local problems: { string } = {}

	local provesNotes, infersNotes = notesOf(cited, problems)

	local listed = listTypeFiles()
	if not listed.ok then
		return listed
	end

	local stateByClaimId: { [string]: State } = {}

	local contents: Contents = {
		stateByClaimId = stateByClaimId,
		problems       = problems,
	}

	if #listed.value == 0 then
		return { ok = true, value = contents }
	end

	local diagnosed = diagnoseTypes()
	if not diagnosed.ok then
		return diagnosed
	end

	local diagnosticsByPlace = groupByPlace(diagnosed.value)

	local provesPlaces: { [string]: true } = {}
	for _, note in provesNotes do
		local markedPlace         = Spec.locationOf(note.path, note.line + 1)
		provesPlaces[markedPlace] = true

		local isRight = hasError(diagnosticsByPlace[markedPlace] or {})
		recordState(stateByClaimId, note.id, isRight)
		if not isRight then
			local requirement = 'line below a "-- proves" note must have an error'
			table.insert(problems, `{note.location}: {requirement}, got none`)
		end
	end

	for _, note in infersNotes do
		local markedPlace = Spec.locationOf(note.path, note.line + 1)
		local atPlace     = diagnosticsByPlace[markedPlace] or {}
		recordState(stateByClaimId, note.id, #atPlace == 0)
	end

	findUnexpected(diagnosed.value, provesPlaces, problems)

	return { ok = true, value = contents }
end


return table.freeze(TypeTests)
