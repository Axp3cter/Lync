--!strict

--[=[
	Conductor

	Runs a whole run from the server: plans the work, sends it to the clients and to its own agent,
	merges what comes back into one report and delivers it.

	It takes the tests of its agent, keeps those whose id holds the filter, and puts them in an
	order shuffled by the run seed, so that state leaking between tests fails the same way again.
	It waits up to 30 seconds for the clients the run expects, and checks that each runs the build
	of the server: a client that runs another build is stale, and the run stops and names it.

	A test of a suite for the server runs in the server. A test of a suite for every DataModel runs
	in the server and in every client that came. A pair runs its server half in the server and its
	client halves in the first clients, and when fewer clients came it is `Skipped` with the reason,
	never passed. Items run one after another, the DataModels of one item together.

	A client is told apart by the name the conductor gave it when it said hello. What a client sends
	is not trusted: only a registered client's outcome for the item under way is taken, and under
	the name it was given.

	Running yields.
]=]


-- Imports -----------------------------------------------------------------------------------------

local Agent        = require("./Agent")
local Properties   = require("./Properties")
local RandomSource = require("./RandomSource")
local Reports      = require("./Reports")
local Suite        = require("./Suite")
local Values       = require("./Values")


-- Module ------------------------------------------------------------------------------------------

local Conductor   = {}
Conductor.__index = Conductor


-- Types -------------------------------------------------------------------------------------------

type Phase =
	| "Gathering"
	| "Running"
	| "Finished"


type Client = {
	read player:    Player,
	read dataModel: string,
	read buildId:   string,
}


type Ran = {
	read kind:    "Ran",
	read outcome: Reports.Outcome,
}


type Raised = {
	read kind:    "Raised",
	read message: string,
}


type Unwinding = Ran | Raised


type Tally = {
	read itemId:   string,
	read expected: { string },
	read outcomes: { [string]: Reports.Outcome },

	receivedCount: number,
	waiter:        thread?,
	timer:         thread?,
}


--[=[
	What a run is set to do.

	@field runId   the id of the run, 8 lowercase hexadecimal digits, the same on every copy
	@field seed    the seed of the run, a whole number from 0 to 4294967295
	@field profile how many cases a property runs
	@field filter  keeps the tests whose ids hold this text; empty keeps every test
	@field tape    one tape to replay alone in the properties the filter keeps, nil to run the cases
	@field clients how many clients to wait for, from 0 to 8
]=]
export type Settings = {
	read runId:   string,
	read seed:    number,
	read profile: Properties.Profile,
	read filter:  string,
	read tape:    { number }?,
	read clients: number,
}


--[=[
	The remotes that carry a run between the server and its clients.

	@field workAssigned the server sends each client the work it is to do
	@field workReported each client sends its hello and its outcomes
]=]
export type Channel = {
	read workAssigned: RemoteEvent,
	read workReported: RemoteEvent,
}


--[=[
	How long the conductor waits, in seconds.

	@field clientWait how long to wait for the clients a run expects
	@field pairReport how long to wait for the halves of a pair to report
	@field itemReport how long to wait for the DataModels to report any other test
]=]
export type Limits = {
	read clientWait: number,
	read pairReport: number,
	read itemReport: number,
}


--[=[
	What `new` needs to make a conductor.

	@field settings     what the run is set to do
	@field agent        the server's own agent, whose tests are the run's tests
	@field loadFailures the modules of the folder that raised when they were required
	@field channel      the remotes between the server and the clients
	@field deliver      sends the finished report out
	@field limits       how long to wait; the standard limits when omitted
]=]
export type Options = {
	read settings:     Settings,
	read agent:        Agent.Agent,
	read loadFailures: { Agent.LoadFailure },
	read channel:      Channel,
	read deliver:      (report: Reports.Report) -> (),
	read limits:       Limits?,
}


type Fields = {
	read _settings:     Settings,
	read _agent:        Agent.Agent,
	read _loadFailures: { Agent.LoadFailure },
	read _channel:      Channel,
	read _deliver:      (report: Reports.Report) -> (),
	read _limits:       Limits,
	read _clients:      { Client },

	_connection:        RBXScriptConnection?,
	_phase:             Phase,
	_tally:             Tally?,
	_clientWaiter:      thread?,
	_clientTimer:       thread?,
	_missingCount:      number,
}


--- A run, from the server.
export type Conductor = setmetatable<Fields, typeof(Conductor)>


-- Constants ---------------------------------------------------------------------------------------

--- The standard waits: 30 seconds for clients, 40 for a pair, 300 for any other test.
const STANDARD_LIMITS: Limits = {
	clientWait = 30,
	pairReport = 40,
	itemReport = 300,
}
table.freeze(STANDARD_LIMITS)


--- The name of the DataModel of the server in a report.
const SERVER_NAME = "Server"


--- The label that the order of the tests is drawn under.
const ORDER_LABEL = "order"


--- The place in the list of DataModels where the clients start, after the server.
const FIRST_CLIENT_PLACE = 2


--- The lowest place a shuffle swaps from: a test at the first place is swapped with itself.
const LAST_SWAP_PLACE = 2


-- Private -----------------------------------------------------------------------------------------

local function isSelected(item: Suite.WorkItem, filter: string): boolean
	if filter == "" then
		return true
	end

	return string.find(item.id, filter, 1, true) ~= nil
end


local function newTally(itemId: string, expected: { string }): Tally
	return {
		itemId        = itemId,
		expected      = expected,
		outcomes      = {},
		receivedCount = 0,
		waiter        = nil,
		timer         = nil,
	}
end


local function wake(thread: thread?): ()
	if thread ~= nil then
		task.spawn(thread)
	end
end


local function deposit(tally: Tally, outcome: Reports.Outcome): ()
	if tally.outcomes[outcome.dataModel] ~= nil then
		return
	end

	tally.outcomes[outcome.dataModel] = outcome
	tally.receivedCount              += 1

	if tally.receivedCount >= #tally.expected then
		wake(tally.waiter)
	end
end


local function isExpected(tally: Tally, dataModel: string): boolean
	return table.find(tally.expected, dataModel) ~= nil
end


local function clientOf(self: Conductor, player: Player): Client?
	for _, client in self._clients do
		if client.player == player then
			return client
		end
	end

	return nil
end


local function staleClientsOf(self: Conductor): { Client }
	local buildId                  = self._agent:buildId()
	local staleClients: { Client } = {}
	for _, client in self._clients do
		if client.buildId ~= buildId then
			table.insert(staleClients, client)
		end
	end

	return staleClients
end


local function skippedOutcomeOf(item: Suite.WorkItem, reason: string): Reports.Outcome
	return {
		id        = item.id,
		dataModel = SERVER_NAME,
		verdict   = "Skipped",
		claims    = {},
		reason    = reason,
	}
end


local function missingOutcomeOf(itemId: string, dataModel: string, limit: number): Reports.Outcome
	local requirement = `{dataModel} must report within {limit} seconds`

	return {
		id        = itemId,
		dataModel = dataModel,
		verdict   = "TimedOut",
		claims    = {},
		failure   = `{requirement}, got no report`,
	}
end


-- In Private, not Handlers: `awaitTally`, a private function, starts the timer that calls it.
local function onReportTimeout(self: Conductor, tally: Tally, limit: number): ()
	-- Forgotten first: a timer must not be cancelled while it is the one that wakes the waiter.
	tally.timer = nil

	for _, dataModel in tally.expected do
		if tally.outcomes[dataModel] == nil then
			tally.outcomes[dataModel] = missingOutcomeOf(tally.itemId, dataModel, limit)
			self._missingCount       += 1
		end
	end

	tally.receivedCount = #tally.expected

	wake(tally.waiter)
end


-- In Private, not Handlers: `runOnServer`, a private function, names it as xpcall's handler. It
-- runs where the error happened, so level 2 starts the traceback at the function that failed.
local function onServerRunError(failure: unknown): Raised
	return { kind = "Raised", message = `{tostring(failure)}\n{debug.traceback(nil, 2)}` }
end


-- In Private, not Handlers: `waitForClients`, a private function, starts the timer that calls it.
local function onClientWaitOver(self: Conductor): ()
	self._clientTimer = nil

	wake(self._clientWaiter)
end


local function awaitTally(self: Conductor, tally: Tally, limit: number): ()
	if tally.receivedCount >= #tally.expected then
		return
	end

	tally.waiter = coroutine.running()
	tally.timer  = task.delay(limit, onReportTimeout, self, tally, limit)

	coroutine.yield()

	tally.waiter = nil

	local timer = tally.timer
	if timer ~= nil then
		task.cancel(timer)
		tally.timer = nil
	end
end


local function waitForClients(self: Conductor): ()
	if #self._clients >= self._settings.clients then
		return
	end

	self._clientWaiter = coroutine.running()
	self._clientTimer  = task.delay(self._limits.clientWait, onClientWaitOver, self)

	coroutine.yield()

	self._clientWaiter = nil

	local timer = self._clientTimer
	if timer ~= nil then
		task.cancel(timer)
		self._clientTimer = nil
	end
end


local function assignmentFor(
	self:      Conductor,
	item:      Suite.WorkItem,
	dataModel: string,
	role:      "Server" | "Client",
	players:   { Player },
	onLinked:  (() -> ())?
): Agent.Assignment
	return {
		item      = item,
		dataModel = dataModel,
		role      = role,
		seed      = self._settings.seed,
		profile   = self._settings.profile,
		tape      = self._settings.tape,
		players   = players,
		onLinked  = onLinked,
	}
end


local function sendTo(self: Conductor, client: Client, item: Suite.WorkItem): ()
	self._channel.workAssigned:FireClient(client.player, {
		kind      = "Assign",
		item      = item,
		dataModel = client.dataModel,
		seed      = self._settings.seed,
		profile   = Properties.wordOf(self._settings.profile),
		tape      = self._settings.tape,
	})
end


local function callAgent(agent: Agent.Agent, assignment: Agent.Assignment): Ran
	return { kind = "Ran", outcome = Agent.run(agent, assignment) }
end


local function runOnServer(agent: Agent.Agent, assignment: Agent.Assignment): Reports.Outcome
	local _, unwinding = xpcall(callAgent, onServerRunError, agent, assignment)
	if unwinding.kind == "Ran" then
		return unwinding.outcome
	elseif unwinding.kind == "Raised" then
		return {
			id        = assignment.item.id,
			dataModel = assignment.dataModel,
			verdict   = "Crashed",
			claims    = {},
			failure   = `the agent must run a test without raising, got {unwinding.message}`,
		}
	end

	local unhandled: never = unwinding
	return unhandled
end


local function startOnServer(self: Conductor, tally: Tally, assignment: Agent.Assignment): ()
	task.spawn(function(): ()
		deposit(tally, runOnServer(self._agent, assignment))
	end)
end


local function namesOf(clients: { Client }): { string }
	local names = table.create(#clients) :: { string }
	for i, client in clients do
		names[i] = client.dataModel
	end

	return names
end


--[=[
	Runs a test in the server and everywhere else it belongs, and waits for what each reports.

	A test that needs more clients than came is skipped, with the reason.

	@param  item the test to run
	@return what each DataModel reported, the server first
]=]
local function dispatch(self: Conductor, item: Suite.WorkItem): { Reports.Outcome }
	local clients = self._clients
	if item.clients > #clients then
		local requirement = `pair test must find {item.clients} clients`
		return { skippedOutcomeOf(item, `{requirement}, got {#clients}`) }
	end

	local targets: { Client } = {}
	if item.clients > 0 then
		targets = table.move(clients, 1, item.clients, 1, {})
	elseif item.where == "Everywhere" then
		targets = clients
	end

	local expected = { SERVER_NAME }
	table.move(namesOf(targets), 1, #targets, FIRST_CLIENT_PLACE, expected)

	local tally = newTally(item.id, expected)
	self._tally = tally

	local limit = self._limits.itemReport
	if item.clients > 0 then
		limit = self._limits.pairReport

		local players = table.create(#targets) :: { Player }
		for i, client in targets do
			players[i] = client.player
		end

		-- The clients start once the server's link listens, so that no message of theirs is lost.
		local function onLinked(): ()
			for _, client in targets do
				sendTo(self, client, item)
			end
		end

		local assignment = assignmentFor(self, item, SERVER_NAME, "Server", players, onLinked)

		startOnServer(self, tally, assignment)
	else
		for _, client in targets do
			sendTo(self, client, item)
		end

		startOnServer(self, tally, assignmentFor(self, item, SERVER_NAME, "Server", {}, nil))
	end

	awaitTally(self, tally, limit)

	self._tally = nil

	local outcomes = table.create(#expected) :: { Reports.Outcome }
	for i, dataModel in expected do
		outcomes[i] = tally.outcomes[dataModel]
	end

	return outcomes
end


local function loadFailureOutcome(failure: Agent.LoadFailure): Reports.Outcome
	return {
		id        = `{failure.path} (module)`,
		dataModel = SERVER_NAME,
		verdict   = "Crashed",
		claims    = {},
		failure   = `module must load without raising, got {failure.message}`,
	}
end


local function reportOf(
	self:       Conductor,
	outcomes:   { Reports.Outcome },
	isComplete: boolean
): Reports.Report
	local settings = self._settings

	return Reports.build({
		kind       = "test",
		runId      = settings.runId,
		buildId    = self._agent:buildId(),
		seed       = settings.seed,
		profile    = settings.profile,
		filter     = settings.filter,
		isComplete = isComplete,
		outcomes   = outcomes,
	})
end


local function describeStale(self: Conductor, staleClients: { Client }): string
	local serverBuildId = self._agent:buildId()
	local parts         = table.create(#staleClients) :: { string }
	for i, client in staleClients do
		parts[i] = `{client.dataModel} is stale, running build {client.buildId}`
	end

	local joined = table.concat(parts, ", ")

	return `{joined}, where the server runs build {serverBuildId}`
end


-- Handlers ----------------------------------------------------------------------------------------

local function onHello(self: Conductor, player: Player, entries: { read [unknown]: unknown }): ()
	if self._phase ~= "Gathering" then
		return
	end

	local buildId = entries.buildId
	if typeof(buildId) ~= "string" then
		return
	end

	local known = clientOf(self, player)
	if known ~= nil then
		return
	end

	local dataModel = `Client{#self._clients + 1}`
	table.insert(self._clients, {
		player    = player,
		dataModel = dataModel,
		buildId   = buildId,
	})

	if #self._clients >= self._settings.clients then
		wake(self._clientWaiter)
	end
end


local function onOutcome(self: Conductor, player: Player, entries: { read [unknown]: unknown }): ()
	local tally = self._tally
	if tally == nil then
		return
	end

	local client = clientOf(self, player)
	if client == nil then
		return
	end

	local outcome = Agent.toOutcome(entries.outcome)
	if outcome == nil then
		return
	end

	if
		outcome.id ~= tally.itemId
		or outcome.dataModel ~= client.dataModel
		or not isExpected(tally, client.dataModel)
	then
		return
	end

	deposit(tally, outcome)
end


local function onReported(self: Conductor, player: Player, message: unknown): ()
	local entries = Values.toEntries(message)
	if entries == nil then
		return
	end

	if entries.kind == "Hello" then
		onHello(self, player, entries)
	elseif entries.kind == "Outcome" then
		onOutcome(self, player, entries)
	end
end


-- Public ------------------------------------------------------------------------------------------

--[=[
	Creates a conductor and starts listening for its clients.

	It listens at once, so that a client that says hello before the run starts is not missed.

	@param  options the settings, the agent, the remotes and where the report goes
	@return a conductor that has run nothing
]=]
function Conductor.new(options: Options): Conductor
	local conductor: Conductor = setmetatable({
		_settings     = options.settings,
		_agent        = options.agent,
		_loadFailures = options.loadFailures,
		_channel      = options.channel,
		_deliver      = options.deliver,
		_limits       = options.limits or STANDARD_LIMITS,
		_clients      = {},
		_connection   = nil,
		_phase        = "Gathering",
		_tally        = nil,
		_clientWaiter = nil,
		_clientTimer  = nil,
		_missingCount = 0,
	}, Conductor)

	local function onClientReported(player: Player, message: unknown): ()
		onReported(conductor, player, message)
	end

	conductor._connection = options.channel.workReported.OnServerEvent:Connect(onClientReported)

	return conductor
end


--[=[
	Runs the run and delivers its report.

	It waits for the clients, stops at once if one runs another build, and otherwise runs each test
	the filter keeps. The report says whether every test reported.

	@return the report that was delivered
]=]
function Conductor.run(self: Conductor): Reports.Report
	waitForClients(self)

	self._phase = "Running"

	local loadOutcomes = table.create(#self._loadFailures) :: { Reports.Outcome }
	for i, failure in self._loadFailures do
		loadOutcomes[i] = loadFailureOutcome(failure)
	end

	local staleClients = staleClientsOf(self)
	if #staleClients > 0 then
		warn(`could not start the run; stopping it: {describeStale(self, staleClients)}`)

		self._phase = "Finished"

		local report = reportOf(self, loadOutcomes, false)
		self._deliver(report)

		return report
	end

	local selected: { Suite.WorkItem } = {}
	for _, item in self._agent:items() do
		if isSelected(item, self._settings.filter) then
			table.insert(selected, item)
		end
	end

	local outcomes = loadOutcomes
	for _, item in Conductor.shuffle(selected, self._settings.seed) do
		for _, outcome in dispatch(self, item) do
			table.insert(outcomes, outcome)
		end
	end

	self._phase = "Finished"

	local report = reportOf(self, outcomes, self._missingCount == 0)
	self._deliver(report)

	return report
end


--[=[
	Puts tests in the order a run shuffled by its seed runs them.

	@param  items the tests to order
	@param  seed  the seed of the run, a whole number from 0 to 4294967295
	@return the same tests in a new order, which one seed always gives for the same tests
	@error  when `seed` is not a whole number from 0 to 4294967295
]=]
function Conductor.shuffle(items: { Suite.WorkItem }, seed: number): { Suite.WorkItem }
	if not RandomSource.isWord(seed) then
		local requirement = `seed must be a whole number from 0 to {RandomSource.MAX_WORD}`
		error(`{requirement}, got {seed}`, 2)
	end

	local source   = RandomSource.newUnrecorded(RandomSource.deriveSeed(seed, ORDER_LABEL, 0))
	local shuffled = table.clone(items)
	for i = #shuffled, LAST_SWAP_PLACE, -1 do
		local j = source:drawInteger(1, i)

		shuffled[i], shuffled[j] = shuffled[j], shuffled[i]
	end

	return shuffled
end


--[=[
	Stops listening to the clients.

	What the conductor reported stays delivered. Repeating `destroy` does nothing.
]=]
function Conductor.destroy(self: Conductor): ()
	local connection = self._connection
	if connection ~= nil then
		connection:Disconnect()
		self._connection = nil
	end
end


return table.freeze(Conductor)
