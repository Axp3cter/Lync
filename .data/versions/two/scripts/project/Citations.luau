--!strict

--[=[
	Citations

	Reads which claims the tests and benchmarks cite, from the Luau and TypeScript files under
	`test/` and `bench/`, and finds the citations that prove nothing.

	A citation is written in one of four forms, and each form proves the claims of the proof kinds
	that it suits.

	A declaration cites its claims as the first argument of a call to `prove`, `proveForAll` or
	`provePair`, written as a table of string literals, which is read from the syntax tree. It
	proves Tested and Scripted claims.

	A note stands alone at the start of its line, and ends its id with a semicolon. In Luau,
	`-- proves <id>;` proves a Typed claim and `-- infers <id>;` an Inferred claim. In TypeScript,
	`// proves <id>;` proves a Declared claim.

	No citation proves a Reviewed or a Waived claim.

	A citation proves a claim only when its form is the one that the claim's proof kind asks for.
	A citation of an id that is not a claim, of a withdrawn claim, or of a claim that its form does
	not suit is a problem, and so is a declaration whose claims cannot be read, or a Luau file that
	does not parse.

	A folder that does not exist holds no citations, and a vendored folder, `node_modules`, is not
	read, because its files are other people's.

	Every operation here yields, except isVendored and uncitedOf.

	A failure outside the scripts, such as a file that cannot be read, comes back as a Result.
]=]


-- Imports -----------------------------------------------------------------------------------------

local Files     = require("../system/Files")
local Paths     = require("./Paths")
local query     = require("@std/syntax/query")
local Spec      = require("./Spec")
local stringext = require("@std/stringext")
local syntax    = require("@std/syntax")
local Types     = require("../Types")


-- Module ------------------------------------------------------------------------------------------

local Citations = {}


-- Types -------------------------------------------------------------------------------------------

--- How a citation is written, which decides the claims that it can prove.
type Form =
	| "Declaration"
	| "TypedNote"
	| "InferredNote"
	| "DeclaredNote"


--[=[
	One claim id that a file cites.

	@field id       the id as written
	@field path     the file that cites it
	@field line     the line of the file that cites it, counted from 1
	@field location the same place spelled for a message, such as "test/behavior/Varint.luau:12"
	@field form     how the citation is written
]=]
export type Citation = {
	read id:       string,
	read path:     string,
	read line:     number,
	read location: string,
	read form:     Form,
}


--[=[
	What the tests and benchmarks cite.

	@field citations every citation that proves a claim, file by file
	@field citedIds  the ids that those citations name
	@field problems  what is wrong with the other citations and the declarations, one finding each
]=]
export type Contents = {
	read citations: { read Citation },
	read citedIds:  { read [string]: true },
	read problems:  { string },
}


-- Constants ---------------------------------------------------------------------------------------

--- Captures the first line of the error that the parser throws for source that does not parse.
const PARSE_FAILURE_PATTERN = "parsing failed:%s*([^\r\n]+)"


--- Captures the verb and the id of a note in Luau, as in "-- proves A-9; ...".
const LUAU_NOTE_PATTERN = "^%s*%-%-%s*(%a+)%s+([^%s;]+);"


--- Captures the verb and the id of a note in TypeScript, as in "// proves A-9; ...".
const TYPESCRIPT_NOTE_PATTERN = "^%s*//%s*(%a+)%s+([^%s;]+);"


--- The extension of a Luau file.
const LUAU_EXTENSION = ".luau"


--- The extension of a TypeScript file.
const TYPESCRIPT_EXTENSION = ".ts"


--- The name of a folder that holds other people's files, which no scan of the tests reads.
const VENDORED_FOLDER = "node_modules"


--- The folders whose files cite claims.
const CITING_FOLDERS: { read string } = {
	Paths.FOLDER.test,
	Paths.FOLDER.bench,
}
table.freeze(CITING_FOLDERS)


--- The names of the methods whose first argument lists the claims that a test cites.
const DECLARATION_NAMES: { read [string]: true } = {
	prove       = true,
	proveForAll = true,
	provePair   = true,
}
table.freeze(DECLARATION_NAMES)


--- The form that a note in Luau has, by the verb that begins it.
const LUAU_FORM_BY_VERB: { read [string]: Form } = {
	proves = "TypedNote",
	infers = "InferredNote",
}
table.freeze(LUAU_FORM_BY_VERB)


--- The form that a note in TypeScript has, by the verb that begins it.
const TYPESCRIPT_FORM_BY_VERB: { read [string]: Form } = {
	proves = "DeclaredNote",
}
table.freeze(TYPESCRIPT_FORM_BY_VERB)


--- The form that proves a claim of each proof kind, nil for the kinds that no citation proves.
const FORM_BY_KIND: Types.Complete<{ read [Spec.ProofKind]: Form? }> = {
	Tested   = "Declaration",
	Scripted = "Declaration",

	Typed    = "TypedNote",
	Inferred = "InferredNote",
	Declared = "DeclaredNote",

	Reviewed = nil,
	Waived   = nil,
}
table.freeze(FORM_BY_KIND)


--- How a message describes each form.
const DESCRIPTION_BY_FORM: Types.Complete<{ read [Form]: string }> = {
	Declaration  = "a test declaration",
	TypedNote    = 'a "-- proves" note in Luau',
	InferredNote = 'a "-- infers" note in Luau',
	DeclaredNote = 'a "// proves" note in TypeScript',
}
table.freeze(DESCRIPTION_BY_FORM)


-- Private -----------------------------------------------------------------------------------------

local function causeOf(thrown: unknown): string
	local message = tostring(thrown)
	local cause   = string.match(message, PARSE_FAILURE_PATTERN)
	if cause == nil then
		return message
	end

	return cause
end


--[=[
	Tells which nodes of a syntax tree are declarations that cite claims.

	@param  node a node of the tree
	@return `node` when it is a method call named in `DECLARATION_NAMES`, otherwise nil
]=]
local function toDeclaration(node: syntax.AstNode): syntax.AstExprCall?
	if node.kind ~= "expr" then
		return nil
	end

	if node.tag ~= "call" then
		return nil
	end

	if not node.self then
		return nil
	end

	local func = node.func
	if func.tag ~= "indexname" then
		return nil
	end

	if not DECLARATION_NAMES[func.index.text] then
		return nil
	end

	return node
end


--[=[
	Reads the claims that one declaration cites, which it writes as a table of string literals.

	@param path      the file that holds the declaration
	@param call      the declaration
	@param citations where each claim that the declaration cites is added
	@param problems  where a declaration whose claims cannot be read is reported
]=]
local function readDeclaration(
	path:      string,
	call:      syntax.AstExprCall,
	citations: { Citation },
	problems:  { string }
): ()
	local location    = Spec.locationOf(path, call.location.beginLine)
	local requirement = "declaration must cite its claims in a table of string literals"

	local first = call.arguments[1]
	if first == nil then
		table.insert(problems, `{location}: {requirement}, got no arguments`)
		return
	end

	local list = first.node
	if list.tag ~= "table" then
		table.insert(problems, `{location}: {requirement}, got a {list.tag}`)
		return
	end

	if #list.entries == 0 then
		table.insert(problems, `{location}: declaration must cite at least one claim, got none`)
		return
	end

	for _, entry in list.entries do
		if entry.kind ~= "list" then
			table.insert(problems, `{location}: {requirement}, got an entry with a key`)
			continue
		end

		local value = entry.value
		if value.tag ~= "string" then
			table.insert(problems, `{location}: {requirement}, got a {value.tag}`)
			continue
		end

		local line = value.location.beginLine

		local citation: Citation = {
			id       = value.token.text,
			path     = path,
			line     = line,
			location = Spec.locationOf(path, line),
			form     = "Declaration",
		}
		table.insert(citations, citation)
	end
end


local function readDeclarations(
	path:      string,
	source:    string,
	citations: { Citation },
	problems:  { string }
): ()
	local ok, parsed = pcall(syntax.parse, source)
	if not ok then
		local cause = causeOf(parsed)
		table.insert(problems, `{path}: file must parse, got "{cause}"`)
		return
	end

	local declarations = query.findAllFromRoot(parsed, toDeclaration)
	for _, call in declarations.nodes do
		readDeclaration(path, call, citations, problems)
	end
end


local function readNotes(
	path:       string,
	source:     string,
	pattern:    string,
	formByVerb: { read [string]: Form },
	citations:  { Citation }
): ()
	for i, line in string.split(source, "\n") do
		local verb, id = string.match(line, pattern)
		if
			verb == nil
			or id == nil
		then
			continue
		end

		local form = formByVerb[verb]
		if form == nil then
			continue
		end

		table.insert(citations, {
			id       = id,
			path     = path,
			line     = i,
			location = Spec.locationOf(path, i),
			form     = form,
		})
	end
end


local function isVendored(path: string): boolean
	for _, name in string.split(path, "/") do
		if name == VENDORED_FOLDER then
			return true
		end
	end

	return false
end


local function isCiting(path: string): boolean
	if isVendored(path) then
		return false
	end

	local isLuau       = stringext.hasSuffix(path, LUAU_EXTENSION)
	local isTypeScript = stringext.hasSuffix(path, TYPESCRIPT_EXTENSION)

	return isLuau or isTypeScript
end


--[=[
	Reads the file `path` for the claims that it cites.

	@param  path      the file to read, which is a Luau or TypeScript file
	@param  citations where each claim that the file cites is added
	@param  problems  where what is wrong in the file is reported
	@return a success once the file is read, or why it could not be
]=]
local function readFile(
	path:      string,
	citations: { Citation },
	problems:  { string }
): Types.Result<nil>
	local read = Files.read(path)
	if not read.ok then
		return read
	end

	local source = read.value
	if stringext.hasSuffix(path, LUAU_EXTENSION) then
		readDeclarations(path, source, citations, problems)
		readNotes(path, source, LUAU_NOTE_PATTERN, LUAU_FORM_BY_VERB, citations)
	elseif stringext.hasSuffix(path, TYPESCRIPT_EXTENSION) then
		readNotes(path, source, TYPESCRIPT_NOTE_PATTERN, TYPESCRIPT_FORM_BY_VERB, citations)
	end

	return { ok = true, value = nil }
end


--[=[
	Lists the files under the folders whose files cite claims.

	@return the Luau and TypeScript files in those folders, or why a folder could not be listed
]=]
local function listCitingFiles(): Types.Result<{ string }>
	local files: { string } = {}
	for _, folder in CITING_FOLDERS do
		local inspected = Files.inspect(folder)
		if not inspected.ok then
			return inspected
		end

		local kind = inspected.value
		if kind == nil then
			continue
		end

		if kind ~= "Folder" then
			local requirement = `{folder} must be a folder in the working directory`
			return { ok = false, error = `{requirement}, got {kind}` }
		end

		local listed = Files.list(folder)
		if not listed.ok then
			return listed
		end

		for _, path in listed.value do
			if isCiting(path) then
				table.insert(files, path)
			end
		end
	end

	return { ok = true, value = files }
end


--[=[
	Keeps the citations that prove a claim.

	A citation proves a claim when the claim exists, is not withdrawn, and has a proof kind whose
	form is the citation's.

	@param  spec     the claims that a citation may prove
	@param  cited    every citation that was read
	@param  problems where each citation that is dropped is reported
	@return the citations that were kept, in the order read
]=]
local function keepProving(
	spec:     Spec.Contents,
	cited:    { read Citation },
	problems: { string }
): { Citation }
	local kept: { Citation } = {}
	for _, citation in cited do
		local claim = spec.claimById[citation.id]
		if claim == nil then
			local requirement = "citation must name a claim"
			table.insert(problems, `{citation.location}: {requirement}, got "{citation.id}"`)
			continue
		end

		if claim.isWithdrawn then
			local requirement = "citation must not name a withdrawn claim"
			table.insert(problems, `{citation.location}: {requirement}, got {citation.id}`)
			continue
		end

		local kind         = claim.proofKind
		local expectedForm = FORM_BY_KIND[kind]
		if expectedForm == nil then
			local requirement = `citation must not name a {kind} claim, which no citation proves`
			table.insert(problems, `{citation.location}: {requirement}, got {citation.id}`)
			continue
		end

		if expectedForm ~= citation.form then
			local expected    = DESCRIPTION_BY_FORM[expectedForm]
			local actual      = DESCRIPTION_BY_FORM[citation.form]
			local requirement = `citation of the {kind} claim {citation.id} must be {expected}`
			table.insert(problems, `{citation.location}: {requirement}, got {actual}`)
			continue
		end

		table.insert(kept, citation)
	end

	return kept
end


local function citedIdsOf(citations: { read Citation }): { [string]: true }
	local citedIds: { [string]: true } = {}
	for _, citation in citations do
		citedIds[citation.id] = true
	end

	return citedIds
end


-- Public ------------------------------------------------------------------------------------------

--- The name of a folder that holds other people's files, which no scan of the tests reads.
Citations.VENDORED_FOLDER = VENDORED_FOLDER


--[=[
	Tells whether a path lies inside a vendored folder.

	@param  path the path to ask about, names joined by "/"
	@return true when one of its folders is named `node_modules`
]=]
function Citations.isVendored(path: string): boolean
	return isVendored(path)
end


--[=[
	Reads the citations under `test/` and `bench/`, and checks that each proves a claim of the spec.

	Every file is read even when an earlier one has problems, so that the problems come all at once.

	@param  spec the spec whose claims the citations must prove
	@return the citations that prove claims, with the problems, or why a file could not be read
]=]
function Citations.read(spec: Spec.Contents): Types.Result<Contents>
	local listed = listCitingFiles()
	if not listed.ok then
		return listed
	end

	local cited:    { Citation } = {}
	local problems: { string }   = {}
	for _, path in listed.value do
		local read = readFile(path, cited, problems)
		if not read.ok then
			return read
		end
	end

	local citations = keepProving(spec, cited, problems)

	return {
		ok    = true,
		value = {
			citations = citations,
			citedIds  = citedIdsOf(citations),
			problems  = problems,
		},
	}
end


--[=[
	Picks the claims that no citation proves.

	@param  claims   the claims to look through
	@param  contents what the tests and benchmarks cite
	@return those of `claims` whose ids no citation names, in the order of `claims`
]=]
function Citations.uncitedOf(claims: { read Spec.Claim }, contents: Contents): { Spec.Claim }
	local uncited: { Spec.Claim } = {}
	for _, claim in claims do
		if contents.citedIds[claim.id] then
			continue
		end

		table.insert(uncited, claim)
	end

	return uncited
end


return table.freeze(Citations)
