--!strict

--[=[
	Suite

	A file's declarations of tests: what each proves, and the body that checks it.

	A suite is made in a module, declares its tests, and is the value the module returns. The
	runner finds suites by requiring the modules of a folder, and runs each declaration by its id.

	A test cites the claims it proves as the first argument of its declaration, and a declaration
	that cites none throws. A title is unique within its suite. There are no hooks: a body builds
	what it needs, so its setup is in view.

	Nothing here yields or touches the engine.
]=]


-- Imports -----------------------------------------------------------------------------------------

local Check        = require("./Check")
local Link         = require("./Link")
local Properties   = require("./Properties")
local RandomSource = require("./RandomSource")


-- Module ------------------------------------------------------------------------------------------

local Suite   = {}
Suite.__index = Suite


-- Types -------------------------------------------------------------------------------------------

--- Where a suite runs: in the server alone, or in the server and in every client.
export type Where =
	| "Server"
	| "Everywhere"


--- The body of a test: it checks, and passes by returning.
export type Body = (check: Check.Check) -> ()


--- One half of a pair test, which meets the other halves through its link.
export type Half = (check: Check.Check, link: Link.Link) -> ()


--[=[
	What a runner gives a property run.

	@field id             the id of the test, which seeds every case
	@field seed           the seed of the run, a whole number from 0 to 4294967295
	@field profile        how many cases to run
	@field tape           one tape to replay alone, nil to run the cases
	@field pauseIfDue     called between cases; free to yield
	@field outputPatterns where the output patterns that cases declare are added
]=]
export type VerifyOptions = {
	read id:             string,
	read seed:           number,
	read profile:        Properties.Profile,
	read tape:           { number }?,
	read pauseIfDue:     () -> (),
	read outputPatterns: { string },
}


--[=[
	A test that is one body.

	@field kind   always "Prove"
	@field title  the test's name within its suite
	@field claims the ids of the claims the test proves
	@field body   what the test does
]=]
export type ProveDeclaration = {
	read kind:   "Prove",
	read title:  string,
	read claims: { read string },
	read body:   Body,
}


--[=[
	A test that is a property over generated values.

	@field kind   always "ProveForAll"
	@field title  the test's name within its suite
	@field claims the ids of the claims the test proves
	@field verify checks the property on cases drawn from its generator
]=]
export type ProveForAllDeclaration = {
	read kind:   "ProveForAll",
	read title:  string,
	read claims: { read string },
	read verify: (options: VerifyOptions) -> Properties.Outcome,
}


--[=[
	A test that is two halves, one in the server and one in each of some clients.

	@field kind        always "ProvePair"
	@field title       the test's name within its suite
	@field claims      the ids of the claims the test proves
	@field serverHalf  what the server does
	@field clientHalf  what each client does
	@field clientCount how many clients the pair needs, from 1 to 8
]=]
export type ProvePairDeclaration = {
	read kind:        "ProvePair",
	read title:       string,
	read claims:      { read string },
	read serverHalf:  Half,
	read clientHalf:  Half,
	read clientCount: number,
}


--- One declared test.
export type Declaration =
	| ProveDeclaration
	| ProveForAllDeclaration
	| ProvePairDeclaration


--[=[
	One unit of work for a runner: a test, named and placed.

	@field id      the test's name in a run, its suite's name and its title
	@field suite   the name of the suite that declares it
	@field title   the test's name within its suite
	@field where   where the test runs
	@field clients how many client halves a pair test needs, 0 for any other test
]=]
export type WorkItem = {
	read id:      string,
	read suite:   string,
	read title:   string,
	read where:   Where,
	read clients: number,
}


type Fields = {
	read name:          string,
	read where:         Where,
	read _declarations: { Declaration },
	read _takenTitles:  { [string]: true },
}


--- A file's declarations of tests.
export type Suite = setmetatable<Fields, typeof(Suite)>


-- Constants ---------------------------------------------------------------------------------------

--- Matches the id of a claim: one capital letter, a hyphen, and a number without leading zeros.
const CLAIM_ID_PATTERN = "^%u%-[1-9]%d*$"


--- What joins the name of a suite and the title of a test into the test's id.
const ID_SEPARATOR = "/"


--- The most clients a pair test can ask for, which a multi-client test session allows.
const MAX_CLIENT_COUNT = 8


--- How many clients a pair test asks for when it says nothing.
const DEFAULT_CLIENT_COUNT = 1


-- Private -----------------------------------------------------------------------------------------

local function idOf(name: string, title: string): string
	return `{name}{ID_SEPARATOR}{title}`
end


local function hasSeparator(text: string): boolean
	return string.find(text, ID_SEPARATOR, 1, true) ~= nil
end


local function problemWithClaims(claims: { read string }): string?
	if #claims == 0 then
		return "claims must hold at least one claim id, got none"
	end

	for i, claimId in claims do
		if typeof(claimId) ~= "string" then
			return `claims must hold only claim ids, got a {typeof(claimId)} at claims[{i}]`
		end

		if string.find(claimId, CLAIM_ID_PATTERN) == nil then
			return `claims must hold claim ids such as "W-12", got "{claimId}"`
		end
	end

	return nil
end


local function problemWithTitle(self: Suite, title: string): string?
	if title == "" then
		return 'title must not be empty, got ""'
	end

	if hasSeparator(title) then
		local requirement = `title must not hold "{ID_SEPARATOR}", which joins an id`

		return `{requirement}, got "{title}"`
	end

	if self._takenTitles[title] then
		return `title must differ from every title in suite "{self.name}", got "{title}"`
	end

	return nil
end


local function problemWithDeclaration(self: Suite, claims: { read string }, title: string): string?
	local claimsProblem = problemWithClaims(claims)
	if claimsProblem ~= nil then
		return claimsProblem
	end

	return problemWithTitle(self, title)
end


local function declare(self: Suite, declaration: Declaration): ()
	self._takenTitles[declaration.title] = true

	table.insert(self._declarations, declaration)
end


local function itemOf(self: Suite, declaration: Declaration): WorkItem
	local clients = 0
	if declaration.kind == "ProvePair" then
		clients = declaration.clientCount
	end

	return {
		id      = idOf(self.name, declaration.title),
		suite   = self.name,
		title   = declaration.title,
		where   = self.where,
		clients = clients,
	}
end


-- Public ------------------------------------------------------------------------------------------

--[=[
	Creates a suite with no tests.

	@param  name  the suite's name, which starts the id of each of its tests; not empty, no slash
	@param  where "Server" to run in the server alone, or "Everywhere" to run in every DataModel
	@return a suite that declares nothing yet
	@error  when `name` is empty or holds a slash
	@error  when `where` is neither "Server" nor "Everywhere"
]=]
function Suite.new(name: string, where: Where): Suite
	if name == "" then
		error('name must not be empty, got ""', 2)
	end

	if hasSeparator(name) then
		local requirement = `name must not hold "{ID_SEPARATOR}", which joins an id`

		error(`{requirement}, got "{name}"`, 2)
	end

	if
		where ~= "Server"
		and where ~= "Everywhere"
	then
		error(`where must be "Server" or "Everywhere", got {tostring(where)}`, 2)
	end

	return setmetatable({
		name          = name,
		where         = where,
		_declarations = {},
		_takenTitles  = {},
	}, Suite)
end


--[=[
	Returns the declarations of the suite.

	@return the declarations in the order they were made, as a copy
]=]
function Suite.declarations(self: Suite): { Declaration }
	return table.clone(self._declarations)
end


--[=[
	Returns the id of the test with a title in the suite with a name.

	Neither holds a slash in a suite or a declaration, so no two tests have the same id.

	@param  name  the suite's name
	@param  title the test's title
	@return the id, the two joined by a slash
]=]
function Suite.idOf(name: string, title: string): string
	return idOf(name, title)
end


--[=[
	Returns the work that the suite's tests make for a runner.

	@return one item for each declaration, in the order they were made
]=]
function Suite.items(self: Suite): { WorkItem }
	local items = table.create(#self._declarations) :: { WorkItem }
	for i, declaration in self._declarations do
		items[i] = itemOf(self, declaration)
	end

	return items
end


--[=[
	Declares a test that is one body.

	@param claims the ids of the claims the test proves, at least one, each such as "W-12"
	@param title  the test's name, not empty and not used by another test of the suite
	@param body   what the test does
	@error when `claims` is empty or holds something that is not a claim id
	@error when `title` is empty or is already a title of the suite
]=]
function Suite.prove(self: Suite, claims: { read string }, title: string, body: Body): ()
	local problem = problemWithDeclaration(self, claims, title)
	if problem ~= nil then
		error(problem, 2)
	end

	declare(self, {
		kind   = "Prove",
		title  = title,
		claims = table.freeze(table.clone(claims)),
		body   = body,
	})
end


--[=[
	Declares a test that is a property over generated values.

	@param claims    the ids of the claims the test proves, at least one, each such as "W-12"
	@param title     the test's name, not empty and not used by another test of the suite
	@param generator builds the value of each case from the draws of a source
	@param property  checks one case's value, failing its check or throwing when it does not hold
	@error when `claims` is empty or holds something that is not a claim id
	@error when `title` is empty or is already a title of the suite
]=]
function Suite.proveForAll<T>(
	self:      Suite,
	claims:    { read string },
	title:     string,
	generator: RandomSource.Generator<T>,
	property:  (check: Check.Check, caseValue: T, pauseIfDue: () -> ()) -> ()
): ()
	local problem = problemWithDeclaration(self, claims, title)
	if problem ~= nil then
		error(problem, 2)
	end

	local function verify(options: VerifyOptions): Properties.Outcome
		return Properties.verify({
			id             = options.id,
			generator      = generator,
			property       = property,
			seed           = options.seed,
			profile        = options.profile,
			tape           = options.tape,
			pauseIfDue     = options.pauseIfDue,
			outputPatterns = options.outputPatterns,
		})
	end

	declare(self, {
		kind   = "ProveForAll",
		title  = title,
		claims = table.freeze(table.clone(claims)),
		verify = verify,
	})
end


--[=[
	Declares a test that is two halves: one in the server and one in each of some clients.

	The halves meet through their link. Only a suite for the server can hold a pair, because a
	suite for every DataModel would run both halves in each.

	@param claims      the ids of the claims the test proves, at least one, each such as "W-12"
	@param title       the test's name, not empty and not used by another test of the suite
	@param serverHalf  what the server does
	@param clientHalf  what each client does
	@param clientCount how many clients the pair needs, from 1 to 8; 1 when omitted
	@error when `claims` is empty or holds something that is not a claim id
	@error when `title` is empty or is already a title of the suite
	@error when the suite is for every DataModel
	@error when `clientCount` is not a whole number from 1 to 8
]=]
function Suite.provePair(
	self:        Suite,
	claims:      { read string },
	title:       string,
	serverHalf:  Half,
	clientHalf:  Half,
	clientCount: number?
): ()
	clientCount = clientCount or DEFAULT_CLIENT_COUNT

	local problem = problemWithDeclaration(self, claims, title)
	if problem ~= nil then
		error(problem, 2)
	end

	if self.where ~= "Server" then
		error(`suite "{self.name}" must be for the Server to hold a pair, got {self.where}`, 2)
	end

	if
		not math.isfinite(clientCount)
		or math.floor(clientCount) ~= clientCount
		or clientCount < 1
		or clientCount > MAX_CLIENT_COUNT
	then
		local requirement = `clientCount must be a whole number from 1 to {MAX_CLIENT_COUNT}`

		error(`{requirement}, got {clientCount}`, 2)
	end

	declare(self, {
		kind        = "ProvePair",
		title       = title,
		claims      = table.freeze(table.clone(claims)),
		serverHalf  = serverHalf,
		clientHalf  = clientHalf,
		clientCount = clientCount,
	})
end


--[=[
	Reads a suite from a value, as a module that a runner requires may return one or not.

	@param  value the value to read
	@return the suite, nil when `value` was not made by `Suite.new`
]=]
function Suite.toSuite(value: unknown): Suite?
	if typeof(value) ~= "table" then
		return nil
	end

	if getmetatable(value) ~= Suite then
		return nil
	end

	-- A table with this class as its metatable was made by `new`, which the checker cannot see.
	return value :: Suite
end


return table.freeze(Suite)
