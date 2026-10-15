--!strict

--[=[
	Agent

	Runs tests in one DataModel: the server's own, or a client's. It holds the suites of the folder
	it was given, runs one work item at a time, and says how it ended.

	A body runs under two taps from `Recorder` and under a watchdog. A failed assertion is `Failed`
	and any other error `Crashed`, told apart by the check, which records its own failure. A body
	that runs longer than 5 seconds, or a pair of halves longer than 30, is `TimedOut`. A property
	run is watched between its pauses, since it yields on purpose. Lync output the test did not
	declare, and an uncaught error it did not claim, fail it.

	A client serves the work that the server sends over `HarnessChannel`, and reports each outcome
	back. The server runs its own work by calling `run`.

	Every build of the folder has a build id, a hash of the sorted ids and the version, which every
	client echoes so that the server can name a client that runs another build.

	Running yields. The module touches no engine service: what it listens to, and what it calls
	after each test, it is given.
]=]


-- Imports -----------------------------------------------------------------------------------------

local Check      = require("./Check")
local Link       = require("./Link")
local Printouts  = require("./Printouts")
local Properties = require("./Properties")
local Recorder   = require("./Recorder")
local Reports    = require("./Reports")
local Suite      = require("./Suite")
local Values     = require("./Values")


-- Module ------------------------------------------------------------------------------------------

local Agent   = {}
Agent.__index = Agent


-- Types -------------------------------------------------------------------------------------------

type AttemptPhase =
	| "Running"
	| "Finished"
	| "TimedOut"


type Returned = { read kind: "Returned" }


type Thrown = {
	read kind:      "Threw",
	read message:   string,
	read traceback: string,
}


type Unwinding = Returned | Thrown


type Attempt = {
	read limit:  number,
	read runner: thread,

	phase:       AttemptPhase,
	isWaiting:   boolean,
	timer:       thread?,
	unwinding:   Unwinding?,
}


type FaultKind =
	| "Failed"
	| "Crashed"
	| "TimedOut"


type SkippedFinding = {
	read kind: "Skipped",
	read text: string,
}


type FaultedFinding = {
	read kind: FaultKind,
	read text: string,
}


type Finding =
	| { read kind: "Held" }
	| SkippedFinding
	| FaultedFinding


type Run = {
	read finding:  Finding,
	read patterns: { string },
}


type Goldens = { read [string]: unknown }


type PropertyResult = { outcome: Properties.Outcome? }


--[=[
	How long things may take, in seconds.

	@field body  how long one body may run, or one stretch of a property run between its pauses
	@field pair  how long the halves of a pair test may run
	@field pause how long a property run goes on before it yields to the engine
]=]
export type Limits = {
	read body:  number,
	read pair:  number,
	read pause: number,
}


--[=[
	What `new` needs to make an agent.

	@field suites         the suites whose tests this agent can run, with distinct names
	@field goldensBySuite the goldens of each suite, by the suite's name
	@field sources        the signals of Output and of uncaught errors that the taps listen to
	@field stop           called after each test, so that no instance outlives its test
	@field version        the version of the build, which the build id hashes
	@field remote         the remote that carries pair-test messages, nil where there is none
	@field limits         how long things may take; the standard limits when omitted
]=]
export type Options = {
	read suites:         { Suite.Suite },
	read goldensBySuite: { read [string]: Goldens },
	read sources:        Recorder.Sources,
	read stop:           () -> (),
	read version:        string,
	read remote:         RemoteEvent?,
	read limits:         Limits?,
}


--[=[
	One test to run in this DataModel, and how.

	@field item      the test to run
	@field dataModel the name this DataModel gives its outcome, such as "Server" or "Client2"
	@field role      which half of a pair this DataModel runs, and the side of its link
	@field seed      the seed of the run, a whole number from 0 to 4294967295
	@field profile   how many cases a property runs
	@field tape      one tape to replay alone, nil to run the cases
	@field players   the players whose client halves are in a pair, empty on a client
	@field onLinked  called once a pair's server link listens, so that clients are started after
]=]
export type Assignment = {
	read item:      Suite.WorkItem,
	read dataModel: string,
	read role:      Link.Role,
	read seed:      number,
	read profile:   Properties.Profile,
	read tape:      { number }?,
	read players:   { Player },
	read onLinked:  (() -> ())?,
}


--[=[
	The suites that a folder holds.

	@field suites         the suites, in the order of their paths
	@field goldensBySuite the goldens of each suite, by the suite's name
	@field failures       the modules that could not be required, each as its path and the error
]=]
export type Collection = {
	read suites:         { Suite.Suite },
	read goldensBySuite: { [string]: Goldens },
	read failures:       { LoadFailure },
}


--[=[
	A module of the folder that raised when it was required.

	@field path    the module's path below the folder, joined by slashes
	@field message what it raised
]=]
export type LoadFailure = {
	read path:    string,
	read message: string,
}


type Fields = {
	read _declarationById: { [string]: Suite.Declaration },
	read _goldensBySuite:  { read [string]: Goldens },
	read _sources:         Recorder.Sources,
	read _stop:            () -> (),
	read _remote:          RemoteEvent?,
	read _limits:          Limits,
	read _items:           { Suite.WorkItem },
	read _buildId:         string,
	read _queue:           { Assignment },

	_isServing:            boolean,
}


--- Runs tests in one DataModel.
export type Agent = setmetatable<Fields, typeof(Agent)>


-- Constants ---------------------------------------------------------------------------------------

--- The standard limits: a body 5 seconds, a pair 30, and a property run pauses every 8 ms.
const STANDARD_LIMITS: Limits = {
	body  = 5,
	pair  = 30,
	pause = 0.008,
}
table.freeze(STANDARD_LIMITS)


--- The name of the barrier that both halves of a pair reach before either runs.
const START_BARRIER = "start"


--- No goldens, for a suite that has none.
const NO_GOLDENS: Goldens = {}
table.freeze(NO_GOLDENS)


const RETURNED: Returned = { kind = "Returned" }
table.freeze(RETURNED)


const HELD: Finding = { kind = "Held" }
table.freeze(HELD)


--- Where the tests of a suite run, for each word of a message.
const WHERE_BY_WORD: { read [string]: Suite.Where } = {
	Server     = "Server",
	Everywhere = "Everywhere",
}
table.freeze(WHERE_BY_WORD)


--- The verdict that each word of a message names.
const VERDICT_BY_WORD: { read [string]: Reports.Verdict } = {
	Passed   = "Passed",
	Failed   = "Failed",
	Crashed  = "Crashed",
	TimedOut = "TimedOut",
	Skipped  = "Skipped",
}
table.freeze(VERDICT_BY_WORD)


--- The name of the folder inside a test folder that holds the goldens.
const GOLDEN_FOLDER_NAME = "golden"


--- Matches the dot that separates the names in the full name of an instance.
const DOT_PATTERN = "%."


--- What separates the names in the path of a module below its folder.
const PATH_SEPARATOR = "/"


--- How far a full name is cut to leave the path below its folder: the folder's name and the dot.
const DOT_AFTER_ROOT = 2


-- Private -----------------------------------------------------------------------------------------

-- Requires a module script. The checker cannot resolve a require of an instance held in a
-- variable, and a module's result is outside data, so it comes back as `unknown`.
local requireModule: (module: ModuleScript) -> unknown = require :: any


local function toWorkItem(value: unknown): Suite.WorkItem?
	local entries = Values.toEntries(value)
	if entries == nil then
		return nil
	end

	local id        = Values.toText(entries.id)
	local suite     = Values.toText(entries.suite)
	local title     = Values.toText(entries.title)
	local whereWord = Values.toText(entries.where)
	local clients   = Values.toNumber(entries.clients)
	if
		id == nil
		or suite == nil
		or title == nil
		or whereWord == nil
		or clients == nil
	then
		return nil
	end

	local where = WHERE_BY_WORD[whereWord]
	if where == nil then
		return nil
	end

	return {
		id      = id,
		suite   = suite,
		title   = title,
		where   = where,
		clients = clients,
	}
end


local function toAssignment(value: unknown): Assignment?
	local entries = Values.toEntries(value)
	if entries == nil then
		return nil
	end

	local item        = toWorkItem(entries.item)
	local dataModel   = Values.toText(entries.dataModel)
	local seed        = Values.toNumber(entries.seed)
	local profileWord = Values.toText(entries.profile)
	if
		item == nil
		or dataModel == nil
		or seed == nil
		or profileWord == nil
	then
		return nil
	end

	local profile = Properties.toProfile(profileWord)
	if profile == nil then
		return nil
	end

	local tape = nil
	if entries.tape ~= nil then
		tape = Values.toTape(entries.tape)
		if tape == nil then
			return nil
		end
	end

	return {
		item      = item,
		dataModel = dataModel,
		role      = "Client",
		seed      = seed,
		profile   = profile,
		tape      = tape,
		players   = {},
		onLinked  = nil,
	}
end


local function faultOf(kind: FaultKind, text: string): Finding
	local finding: FaultedFinding = { kind = kind, text = text }

	return finding
end


local function skippedOf(text: string): Finding
	local finding: SkippedFinding = { kind = "Skipped", text = text }

	return finding
end


local function describeFailure(failure: Check.Failure): string
	return `{failure.message}\n{failure.traceback}`
end


local function describeCounterexample(example: Properties.Counterexample): string
	local lines = { example.message, `replay: {example.replayLine}` }

	local origin = example.origin
	if origin ~= nil then
		local seeds = `seed {origin.runSeed}, case {origin.caseNumber}, case seed {origin.caseSeed}`
		table.insert(lines, `{seeds}; shrunk in {example.shrinkCallCount} replays`)
	else
		table.insert(lines, "replayed alone from its tape")
	end

	table.insert(lines, example.traceback)

	return table.concat(lines, "\n")
end


local function describeProblems(problems: { Recorder.Problem }): string
	local first = problems[1]
	local text  = first.message
	if first.traceback ~= nil then
		text = `{text}\n{first.traceback}`
	end

	if #problems > 1 then
		text = `{text}\n(and {#problems - 1} more problems of the same kind)`
	end

	return text
end


local function newAttempt(limit: number): Attempt
	return {
		limit     = limit,
		runner    = coroutine.running(),
		phase     = "Running",
		isWaiting = false,
		timer     = nil,
		unwinding = nil,
	}
end


--[=[
	Ends an attempt unless it has ended, and wakes the runner if it is waiting.

	@param attempt the attempt to end
	@param phase   how it ended
]=]
local function finish(attempt: Attempt, phase: AttemptPhase): ()
	if attempt.phase ~= "Running" then
		return
	end

	attempt.phase = phase

	if attempt.isWaiting then
		task.spawn(attempt.runner)
	end
end


-- In Private, not Handlers: `arm`, a private function, starts the timer that calls it.
local function onLimit(attempt: Attempt): ()
	-- Forgotten first: a timer must not be cancelled while it is the one that wakes the runner.
	attempt.timer = nil

	finish(attempt, "TimedOut")
end


-- In Private, not Handlers: `runProtected`, a private function, names it as xpcall's handler. It
-- runs where the error happened, so level 2 starts the traceback at the function that failed.
local function onBodyError(failure: unknown): Thrown
	return {
		kind      = "Threw",
		message   = tostring(failure),
		traceback = debug.traceback(nil, 2),
	}
end


--[=[
	Starts an attempt's timer over, so that the limit counts from now.

	@param attempt the attempt whose timer starts over
]=]
local function arm(attempt: Attempt): ()
	local timer = attempt.timer
	if timer ~= nil then
		task.cancel(timer)
	end

	attempt.timer = task.delay(attempt.limit, onLimit, attempt)
end


local function callBody(body: () -> ()): Returned
	body()

	return RETURNED
end


local function runProtected(attempt: Attempt, body: () -> ()): ()
	local _, unwinding = xpcall(callBody, onBodyError, body)

	attempt.unwinding = unwinding

	finish(attempt, "Finished")
end


--[=[
	Runs a body in a thread of its own and waits until it returns, throws or runs out of time.

	A body that runs out of time has its thread cancelled.

	@param attempt the attempt to run, whose limit is how long the body may go without pausing
	@param body    what to run
]=]
local function supervise(attempt: Attempt, body: () -> ()): ()
	local bodyThread = task.spawn(runProtected, attempt, body)

	if attempt.phase == "Running" then
		arm(attempt)

		attempt.isWaiting = true
		coroutine.yield()
		attempt.isWaiting = false
	end

	local timer = attempt.timer
	if timer ~= nil then
		task.cancel(timer)
		attempt.timer = nil
	end

	if attempt.phase == "TimedOut" then
		task.cancel(bodyThread)
	end
end


local function newPauser(self: Agent, attempt: Attempt): () -> ()
	local pauseInterval = self._limits.pause
	local lastPauseAt   = os.clock()

	return function(): ()
		if os.clock() - lastPauseAt < pauseInterval then
			return
		end

		task.wait()

		lastPauseAt = os.clock()

		-- The wait was ours, so the time it took is not the property run's.
		arm(attempt)
	end
end


local function timeoutFinding(limit: number): Finding
	local requirement = `test must finish within {limit} seconds`

	return faultOf("TimedOut", `{requirement}, got a body that was still running`)
end


local function findingOfBody(
	attempt: Attempt,
	check:   Check.Check,
	link:    Link.Link?,
	elapsed: number
): Finding
	local linkReason = nil
	if link ~= nil then
		linkReason = link:timeoutReason()
	end

	if linkReason ~= nil then
		return faultOf("TimedOut", linkReason)
	end

	if attempt.phase == "TimedOut" then
		return timeoutFinding(attempt.limit)
	end

	local failure = check:failure()
	if failure ~= nil then
		return faultOf("Failed", describeFailure(failure))
	end

	local unwinding = attempt.unwinding
	if
		unwinding ~= nil
		and unwinding.kind == "Threw"
	then
		return faultOf("Crashed", `{unwinding.message}\n{unwinding.traceback}`)
	end

	if elapsed > attempt.limit then
		local requirement = `test must finish within {attempt.limit} seconds`
		local got         = string.format("%.1f", elapsed)

		return faultOf("TimedOut", `{requirement}, got a body that ran {got}`)
	end

	return HELD
end


local function findingOfProperty(attempt: Attempt, outcome: Properties.Outcome?): Finding
	if attempt.phase == "TimedOut" then
		return timeoutFinding(attempt.limit)
	end

	local unwinding = attempt.unwinding
	if
		unwinding ~= nil
		and unwinding.kind == "Threw"
	then
		return faultOf("Crashed", `{unwinding.message}\n{unwinding.traceback}`)
	end

	if
		outcome == nil
		or outcome.kind == "Passed"
	then
		return HELD
	end

	return faultOf(outcome.kind, describeCounterexample(outcome))
end


local function runProve(
	self:        Agent,
	assignment:  Assignment,
	declaration: Suite.ProveDeclaration
): Run
	local goldens = self._goldensBySuite[assignment.item.suite] or NO_GOLDENS
	local check   = Check.new(debug.info(declaration.body, "s"), goldens)
	local attempt = newAttempt(self._limits.body)

	local startedAt = os.clock()
	supervise(attempt, function(): ()
		declaration.body(check)
	end)

	local finding = findingOfBody(attempt, check, nil, os.clock() - startedAt)

	return { finding = finding, patterns = check:outputPatterns() }
end


local function runProveForAll(
	self:        Agent,
	assignment:  Assignment,
	declaration: Suite.ProveForAllDeclaration
): Run
	local attempt                = newAttempt(self._limits.body)
	local patterns: { string }   = {}
	local result: PropertyResult = { outcome = nil }

	supervise(attempt, function(): ()
		result.outcome = declaration.verify({
			id             = assignment.item.id,
			seed           = assignment.seed,
			profile        = assignment.profile,
			tape           = assignment.tape,
			pauseIfDue     = newPauser(self, attempt),
			outputPatterns = patterns,
		})
	end)

	return { finding = findingOfProperty(attempt, result.outcome), patterns = patterns }
end


local function runProvePair(
	self:        Agent,
	assignment:  Assignment,
	declaration: Suite.ProvePairDeclaration
): Run
	local remote = self._remote
	if remote == nil then
		local text = "pair test must run where the pair remote exists, got a DataModel without it"

		return { finding = skippedOf(text), patterns = {} }
	end

	local isServer = assignment.role == "Server"
	local half     = declaration.clientHalf
	local wire     = Link.wrapAtClient(remote)
	if isServer then
		half = declaration.serverHalf
		wire = Link.wrapAtServer(remote, assignment.players)
	end

	local link = Link.new({
		item        = assignment.item.id,
		role        = assignment.role,
		clientCount = assignment.item.clients,
		wire        = wire,
	})

	local onLinked = assignment.onLinked
	if onLinked ~= nil then
		onLinked()
	end

	local goldens = self._goldensBySuite[assignment.item.suite] or NO_GOLDENS
	local check   = Check.new(debug.info(half, "s"), goldens)
	local attempt = newAttempt(self._limits.pair)

	local startedAt = os.clock()
	supervise(attempt, function(): ()
		link:barrier(START_BARRIER)
		half(check, link)
	end)

	local finding = findingOfBody(attempt, check, link, os.clock() - startedAt)

	link:close()

	return { finding = finding, patterns = check:outputPatterns() }
end


local function runDeclaration(
	self:        Agent,
	assignment:  Assignment,
	declaration: Suite.Declaration
): Run
	if declaration.kind == "Prove" then
		return runProve(self, assignment, declaration)
	elseif declaration.kind == "ProveForAll" then
		return runProveForAll(self, assignment, declaration)
	elseif declaration.kind == "ProvePair" then
		return runProvePair(self, assignment, declaration)
	end

	local unhandled: never = declaration
	return unhandled
end


local function outcomeOf(
	assignment: Assignment,
	claims:     { read string },
	finding:    Finding
): Reports.Outcome
	local id        = assignment.item.id
	local dataModel = assignment.dataModel

	if finding.kind == "Held" then
		return {
			id        = id,
			dataModel = dataModel,
			verdict   = "Passed",
			claims    = claims,
		}
	elseif finding.kind == "Skipped" then
		return {
			id        = id,
			dataModel = dataModel,
			verdict   = "Skipped",
			claims    = claims,
			reason    = finding.text,
		}
	end

	return {
		id        = id,
		dataModel = dataModel,
		verdict   = finding.kind,
		claims    = claims,
		failure   = finding.text,
	}
end


local function stopLync(self: Agent): string?
	local ok, failure = pcall(self._stop)
	if ok then
		return nil
	end

	return tostring(failure)
end


--[=[
	Runs one declaration under the taps and judges what it caused.

	@param  assignment  the test to run, and how
	@param  declaration what the test declared
	@return the outcome, which is `Passed` only when the body held and nothing went unclaimed
]=]
local function execute(
	self:        Agent,
	assignment:  Assignment,
	declaration: Suite.Declaration
): Reports.Outcome
	local recorder = Recorder.new(self._sources)
	recorder:start()

	local ran, ranOrFailure = pcall(runDeclaration, self, assignment, declaration)

	-- One frame lets the signals that the engine defers deliver what the test caused.
	task.wait()

	local problems = {}
	if ran then
		problems = recorder:problems(ranOrFailure.patterns)
	end

	recorder:destroy()

	local stopFailure = stopLync(self)

	if not ran then
		error(ranOrFailure, 0)
	end

	local finding = ranOrFailure.finding
	if
		finding.kind == "Held"
		and #problems > 0
	then
		finding = faultOf("Failed", describeProblems(problems))
	end

	if
		finding.kind == "Held"
		and stopFailure ~= nil
	then
		local requirement = "Lync.stop must not throw after a test"
		finding           = faultOf("Crashed", `{requirement}, got {stopFailure}`)
	end

	return outcomeOf(assignment, declaration.claims, finding)
end


local function unknownOutcomeOf(assignment: Assignment): Reports.Outcome
	local requirement = `{assignment.dataModel} must hold a test with the id the server sent`

	return {
		id        = assignment.item.id,
		dataModel = assignment.dataModel,
		verdict   = "Crashed",
		claims    = {},
		failure   = `{requirement}, got "{assignment.item.id}"`,
	}
end


local function pathBelow(root: Instance, descendant: Instance): string
	local rootName = root:GetFullName()
	local fullName = descendant:GetFullName()
	local below    = string.sub(fullName, #rootName + DOT_AFTER_ROOT)
	local path     = string.gsub(below, DOT_PATTERN, PATH_SEPARATOR)

	return path
end


local function goldensOf(root: Instance, path: string): Goldens
	local folder = root:FindFirstChild(GOLDEN_FOLDER_NAME)
	if folder == nil then
		return NO_GOLDENS
	end

	local current: Instance = folder
	for _, name in string.split(path, PATH_SEPARATOR) do
		local child = current:FindFirstChild(name)
		if child == nil then
			return NO_GOLDENS
		end

		current = child
	end

	if not current:IsA("ModuleScript") then
		return NO_GOLDENS
	end

	local ok, loaded = pcall(requireModule, current)
	if not ok then
		return NO_GOLDENS
	end

	return Values.toRecord(loaded) or NO_GOLDENS
end


local function run(self: Agent, assignment: Assignment): Reports.Outcome
	local declaration = self._declarationById[assignment.item.id]
	if declaration == nil then
		return unknownOutcomeOf(assignment)
	end

	return execute(self, assignment, declaration)
end


--[=[
	Runs the assignments that have come, oldest first, until none is left, reporting each outcome.

	@param workReported the remote that carries each outcome to the server
]=]
local function serveQueued(self: Agent, workReported: RemoteEvent): ()
	while #self._queue > 0 do
		local assignment = table.remove(self._queue, 1)
		assert(assignment, "an assignment is taken only while one is queued")

		local outcome = run(self, assignment)

		workReported:FireServer({ kind = "Outcome", outcome = outcome })
	end
end


-- Handlers ----------------------------------------------------------------------------------------

local function onAssigned(self: Agent, workReported: RemoteEvent, message: unknown): ()
	local entries = Values.toEntries(message)
	if
		entries == nil
		or entries.kind ~= "Assign"
	then
		return
	end

	local assignment = toAssignment(message)
	if assignment == nil then
		return
	end

	-- A test runs at a time: one that comes while another runs, such as after the server gave up on
	-- the first, waits its turn instead of starting a second recorder.
	table.insert(self._queue, assignment)
	if self._isServing then
		return
	end

	self._isServing   = true
	local ok, failure = pcall(serveQueued, self, workReported)
	self._isServing   = false

	if not ok then
		error(failure, 0)
	end
end


-- Public ------------------------------------------------------------------------------------------

--[=[
	The names of the instances that carry a run between the server and its clients.

	The server makes a folder of the first name in ReplicatedStorage. It holds the remotes
	`workAssigned`, `workReported` and `pairMessaged`, and an object value `root` that points at
	the folder of tests, so that a client finds the same suites the server runs. Lync's own remotes
	never carry a run.
]=]
Agent.CHANNEL = table.freeze({
	folder       = "HarnessChannel",
	workAssigned = "WorkAssigned",
	workReported = "WorkReported",
	pairMessaged = "PairMessaged",
	root         = "Root",
})


--[=[
	Creates an agent for the suites it is given.

	@param  options the suites and everything the agent calls
	@return an agent that has run nothing
	@error  when two suites have the same name
]=]
function Agent.new(options: Options): Agent
	local declarationById: { [string]: Suite.Declaration } = {}
	local items: { Suite.WorkItem }                        = {}
	local takenNames: { [string]: true }                   = {}
	for _, suite in options.suites do
		if takenNames[suite.name] then
			error(`suites must have distinct names, got "{suite.name}" twice`, 2)
		end

		takenNames[suite.name] = true

		local suiteItems = suite:items()
		for i, declaration in suite:declarations() do
			local item = suiteItems[i]

			declarationById[item.id] = declaration
			table.insert(items, item)
		end
	end

	local ids = table.create(#items) :: { string }
	for i, item in items do
		ids[i] = item.id
	end

	return setmetatable({
		_declarationById = declarationById,
		_goldensBySuite  = options.goldensBySuite,
		_sources         = options.sources,
		_stop            = options.stop,
		_remote          = options.remote,
		_limits          = options.limits or STANDARD_LIMITS,
		_items           = items,
		_buildId         = Agent.buildIdOf(ids, options.version),
		_queue           = {},
		_isServing       = false,
	}, Agent)
end


--[=[
	Returns the build id of this agent's suites.

	@return the build id, which a server compares with every client's
]=]
function Agent.buildId(self: Agent): string
	return self._buildId
end


--[=[
	Returns the id of a build: a hash of its sorted test ids and its version.

	@param  ids     the ids of every test of the build
	@param  version the version of the build
	@return the build id, 8 lowercase hexadecimal digits, the same for the ids in any order
]=]
function Agent.buildIdOf(ids: { string }, version: string): string
	local sorted = table.clone(ids)
	table.sort(sorted)

	local joined = table.concat(sorted, "\n")

	return Printouts.checksumOf(`{joined}\n{version}`)
end


--[=[
	Requires the modules of a folder and keeps the suites they return.

	A module that returns something else, such as a table of goldens or a generator, is not a suite
	and is left out. A module that raises when required is reported, not skipped.

	@param  root the folder whose modules hold the suites
	@return the suites in the order of their paths, their goldens and the modules that raised
]=]
function Agent.collect(root: Instance): Collection
	local modules: { ModuleScript } = {}
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("ModuleScript") then
			table.insert(modules, descendant)
		end
	end

	table.sort(modules, function(left: ModuleScript, right: ModuleScript): boolean
		return left:GetFullName() < right:GetFullName()
	end)

	local suites: { Suite.Suite }               = {}
	local goldensBySuite: { [string]: Goldens } = {}
	local failures: { LoadFailure }             = {}
	for _, module in modules do
		local ok, required = pcall(requireModule, module)

		local path = pathBelow(root, module)
		if not ok then
			table.insert(failures, { path = path, message = tostring(required) })
			continue
		end

		local suite = Suite.toSuite(required)
		if suite == nil then
			continue
		end

		table.insert(suites, suite)

		goldensBySuite[suite.name] = goldensOf(root, path)
	end

	return {
		suites         = suites,
		goldensBySuite = goldensBySuite,
		failures       = failures,
	}
end


--[=[
	Returns the work that this agent's suites make.

	@return one item for each test, in the order of the suites and then of their declarations
]=]
function Agent.items(self: Agent): { Suite.WorkItem }
	return table.clone(self._items)
end


--[=[
	Runs one test and says how it ended.

	The test runs under the taps and the watchdog, `stop` is called after it, and nothing it did
	is left running or listening.

	@param  assignment the test to run, and how
	@return the outcome, with the verdict `Skipped` only for a pair that cannot run here
	@error  whatever a failure of the agent itself raises, after the taps are released
]=]
function Agent.run(self: Agent, assignment: Assignment): Reports.Outcome
	return run(self, assignment)
end


--[=[
	Serves the work that the server sends, and reports each outcome back, until it is stopped.

	It first tells the server its build id, so that the server can tell whether this client runs
	the same build.

	@param  workAssigned the remote that carries work to this client
	@param  workReported the remote that carries this client's messages to the server
	@return the function that stops serving
]=]
function Agent.serve(self: Agent, workAssigned: RemoteEvent, workReported: RemoteEvent): () -> ()
	local function onAssignedToThis(message: unknown): ()
		onAssigned(self, workReported, message)
	end

	local connection = workAssigned.OnClientEvent:Connect(onAssignedToThis)

	workReported:FireServer({ kind = "Hello", buildId = self._buildId })

	return function(): ()
		connection:Disconnect()
	end
end


--[=[
	Reads a client's outcome message into an outcome.

	@param  value what a client sent as its outcome, which is not trusted
	@return the outcome, nil when `value` is not one
]=]
function Agent.toOutcome(value: unknown): Reports.Outcome?
	local entries = Values.toEntries(value)
	if entries == nil then
		return nil
	end

	local id          = Values.toText(entries.id)
	local dataModel   = Values.toText(entries.dataModel)
	local verdictWord = Values.toText(entries.verdict)
	if
		id == nil
		or dataModel == nil
		or verdictWord == nil
	then
		return nil
	end

	local verdict = VERDICT_BY_WORD[verdictWord]
	if verdict == nil then
		return nil
	end

	local claims = Values.toTexts(entries.claims)
	if claims == nil then
		return nil
	end

	local failure = Values.toText(entries.failure)
	local reason  = Values.toText(entries.reason)
	if
		entries.failure ~= nil
		and failure == nil
	then
		return nil
	end

	if
		entries.reason ~= nil
		and reason == nil
	then
		return nil
	end

	return {
		id        = id,
		dataModel = dataModel,
		verdict   = verdict,
		claims    = claims,
		failure   = failure,
		reason    = reason,
	}
end


return table.freeze(Agent)
