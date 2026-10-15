--!strict

--[=[
	Boot

	Client script that starts an agent, which runs the work the server sends for as long as the
	client lives.

	It waits for the server to make `HarnessChannel`, takes the folder of tests the channel points
	at, and requires its suites, so that it holds the same tests the server does. Then it serves
	the channel: it tells the server its build id and runs what it is sent. It serves tests and
	benchmark rows alike.

	A run that never starts leaves the client waiting, which costs nothing.
]=]


-- Imports -----------------------------------------------------------------------------------------

local LogService        = game:GetService("LogService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ScriptContext     = game:GetService("ScriptContext")

local Agent = require("./Agent")


-- Constants ---------------------------------------------------------------------------------------

--- How long the members of the channel may take to replicate after the channel itself, in seconds.
const MEMBER_TIMEOUT = 10


-- Private -----------------------------------------------------------------------------------------

local function findChannel(): Folder?
	local child = ReplicatedStorage:FindFirstChild(Agent.CHANNEL.folder)
	if
		child == nil
		or not child:IsA("Folder")
	then
		return nil
	end

	return child
end


local function waitForChannel(): Folder
	local channel = findChannel()
	while channel == nil do
		ReplicatedStorage.ChildAdded:Wait()

		channel = findChannel()
	end

	return assert(channel, "channel must exist once the wait for it ends")
end


local function findRemote(channel: Folder, name: string): RemoteEvent?
	local child = channel:WaitForChild(name, MEMBER_TIMEOUT)
	if
		child == nil
		or not child:IsA("RemoteEvent")
	then
		return nil
	end

	return child
end


local function findRoot(channel: Folder): Instance?
	local child = channel:WaitForChild(Agent.CHANNEL.root, MEMBER_TIMEOUT)
	if
		child == nil
		or not child:IsA("ObjectValue")
	then
		return nil
	end

	return child.Value
end


-- There is no Lync source to stop yet, so there is nothing for a test to leave running.
local function stopLync(): ()
end


local function start(): ()
	local channel      = waitForChannel()
	local workAssigned = findRemote(channel, Agent.CHANNEL.workAssigned)
	local workReported = findRemote(channel, Agent.CHANNEL.workReported)
	local pairMessaged = findRemote(channel, Agent.CHANNEL.pairMessaged)
	local root         = findRoot(channel)
	if
		workAssigned == nil
		or workReported == nil
		or pairMessaged == nil
		or root == nil
	then
		local consequence = "this client will not run the tests"
		warn(`could not find all of {Agent.CHANNEL.folder} in time; {consequence}`)
		return
	end

	local collection = Agent.collect(root)
	local agent      = Agent.new({
		suites         = collection.suites,
		goldensBySuite = collection.goldensBySuite,
		sources        = {
			output = LogService.MessageOut,
			faults = ScriptContext.Error,
		},
		stop           = stopLync,
		version        = VERSION,
		remote         = pairMessaged,
		limits         = nil,
	})

	agent:serve(workAssigned, workReported)
end


-- Main --------------------------------------------------------------------------------------------

start()
