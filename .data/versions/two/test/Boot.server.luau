--!strict

--[=[
	Boot

	Server script that starts a run of the tests in this folder.

	It asserts that it runs in Studio and in the test build, waits for a driver when the run is
	driven, then makes `HarnessChannel`, starts a conductor on the folder it sits in and runs it.
	The run's options come from the receiver in the terminal when one answers, and from the
	defaults when none does.

	The report goes to Output, and to the receiver when it answers.

	A driven run is one whose driver set the attribute `Driven` on `ReplicatedStorage.Lync` before
	it started play. Nothing of the harness is required until the driver answers, by clearing the
	attribute, or until 30 seconds pass, because coverage counts only the code that runs after the
	driver enabled it.
]=]


-- Imports -----------------------------------------------------------------------------------------

local HttpService       = game:GetService("HttpService")
local LogService        = game:GetService("LogService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local ScriptContext     = game:GetService("ScriptContext")

local lync = ReplicatedStorage:WaitForChild("Lync") :: Folder


-- Types -------------------------------------------------------------------------------------------

type Harness = {
	read Agent:        typeof(require("@harness/Agent")),
	read Conductor:    typeof(require("@harness/Conductor")),
	read Deliveries:   typeof(require("@harness/Deliveries")),
	read Properties:   typeof(require("@harness/Properties")),
	read RandomSource: typeof(require("@harness/RandomSource")),
	read Reports:      typeof(require("@harness/Reports")),
}


type Channel = {
	read folder:       Folder,
	read workAssigned: RemoteEvent,
	read workReported: RemoteEvent,
	read pairMessaged: RemoteEvent,
}


-- Constants ---------------------------------------------------------------------------------------

--- How long a driven run waits for its driver to answer, in seconds.
const DRIVER_TIMEOUT = 30


--- How many clients a play session has, which a run waits for when the options give no number.
const PLAY_CLIENT_COUNT = 1


--- How many milliseconds make a second, to turn the clock into a number that differs from run to run.
const MILLISECONDS_PER_SECOND = 1000


-- Private -----------------------------------------------------------------------------------------

-- A driver that does not answer in time is released by the timer, which clears the attribute.
local function waitForDriver(): ()
	if lync:GetAttribute("Driven") ~= true then
		return
	end

	local timer = task.delay(DRIVER_TIMEOUT, lync.SetAttribute, lync, "Driven", false)

	lync:GetAttributeChangedSignal("Driven"):Wait()

	if coroutine.status(timer) == "suspended" then
		task.cancel(timer)
	end
end


local function loadHarness(): Harness
	-- Required here, not in Imports: a driven run enables coverage only after the driver answers,
	-- and a module required before that would run uncovered.
	return {
		Agent        = require("@harness/Agent"),
		Conductor    = require("@harness/Conductor"),
		Deliveries   = require("@harness/Deliveries"),
		Properties   = require("@harness/Properties"),
		RandomSource = require("@harness/RandomSource"),
		Reports      = require("@harness/Reports"),
	}
end


-- There is no Lync source to stop yet, so there is nothing for a test to leave running.
local function stopLync(): ()
end


local function newRunId(harness: Harness): string
	local clockMilliseconds = math.floor(os.clock() * MILLISECONDS_PER_SECOND)
	local entropy           = bit32.bxor(os.time(), clockMilliseconds)
	local source  = harness.RandomSource.newUnrecorded(entropy)

	return harness.Reports.runIdOf(source:drawWord())
end


local function newChannel(harness: Harness, tests: Instance): Channel
	local names  = harness.Agent.CHANNEL
	local folder = Instance.new("Folder")
	folder.Name  = names.folder

	local function newRemote(name: string): RemoteEvent
		local remote  = Instance.new("RemoteEvent")
		remote.Name   = name
		remote.Parent = folder

		return remote
	end

	local root  = Instance.new("ObjectValue")
	root.Name   = names.root
	root.Value  = tests
	root.Parent = folder

	return {
		folder       = folder,
		workAssigned = newRemote(names.workAssigned),
		workReported = newRemote(names.workReported),
		pairMessaged = newRemote(names.pairMessaged),
	}
end


local function clientCountOf(requested: number?): number
	if requested ~= nil then
		return requested
	end

	if RunService:IsRunMode() then
		return 0
	end

	return PLAY_CLIENT_COUNT
end


local function start(): ()
	local tests = assert(script.Parent, "Boot must sit in the folder of tests")

	local harness = loadHarness()
	local ports   = harness.Deliveries.enginePorts(HttpService)
	local options = harness.Deliveries.loadOptions(ports)

	local collection = harness.Agent.collect(tests)
	local channel    = newChannel(harness, tests)
	local agent      = harness.Agent.new({
		suites         = collection.suites,
		goldensBySuite = collection.goldensBySuite,
		sources        = {
			output = LogService.MessageOut,
			faults = ScriptContext.Error,
		},
		stop           = stopLync,
		version        = VERSION,
		remote         = channel.pairMessaged,
		limits         = nil,
	})

	local conductor = harness.Conductor.new({
		settings     = {
			runId   = newRunId(harness),
			seed    = options.seed or harness.Properties.DEFAULT_SEED,
			profile = options.profile or "Standard",
			filter  = options.filter or "",
			tape    = options.tape,
			clients = clientCountOf(options.clients),
		},
		agent        = agent,
		loadFailures = collection.failures,
		channel      = channel,
		deliver      = harness.Deliveries.sender(ports),
		limits       = nil,
	})

	-- The channel appears only now, so that no client says hello before the conductor listens.
	channel.folder.Parent = ReplicatedStorage

	conductor:run()
	conductor:destroy()

	channel.folder:Destroy()
end


-- Main --------------------------------------------------------------------------------------------

assert(RunService:IsStudio(), "Boot must run in Studio")
assert(IS_DEVELOPMENT, "Boot must run in the test build, where IS_DEVELOPMENT is true")

waitForDriver()
start()
