--!strict

--[=[
	Roblox

	Builds the `Host` record (m2-plan.md §2) from the engine's services, for one side.

	The server creates `ReplicatedStorage.Lync` with the `Reliable` and `Unreliable` remotes when
	its transport opens; the client finds them through `ChildAdded` and never yields. Received
	remote arguments reach the handler untouched, so the inbound pipeline checks their shape
	itself (v5.md §6.1).

	Console lines go through `warn` with the constant template only, until Studio confirms that
	`LogService:Warn` groups by template in the Error Report (m2-plan.md §7); then
	`IS_STRUCTURED_LOGGING` turns on and the context reaches the console with it.
]=]

-- Imports -----------------------------------------------------------------------------------------

local LogService = game:GetService("LogService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Host = require("./host")

-- Module ------------------------------------------------------------------------------------------

local Roblox = {}

-- Types -------------------------------------------------------------------------------------------

type Handler = (player: Player?, lane: Host.Lane, ...unknown) -> ()

type Remotes = {
	reliable: RemoteEvent?,
	unreliable: UnreliableRemoteEvent?,
	handler: Handler,
	folderWatch: RBXScriptConnection?,
}

-- Constants ---------------------------------------------------------------------------------------

const FOLDER_NAME = "Lync"
const RELIABLE_NAME = "Reliable"
const UNRELIABLE_NAME = "Unreliable"

const RELIABLE: Host.Lane = 0
const UNRELIABLE: Host.Lane = 1

const IS_STRUCTURED_LOGGING = false

-- Private -----------------------------------------------------------------------------------------

local function ignoreReceived(_player: Player?, _lane: Host.Lane, ...: unknown) end

local function disconnectorOf(connection: RBXScriptConnection): () -> ()
	return function()
		connection:Disconnect()
	end
end

local function listenOnServer(remotes: Remotes, reliable: RemoteEvent, unreliable: UnreliableRemoteEvent)
	reliable.OnServerEvent:Connect(function(player: Player, ...: unknown)
		remotes.handler(player, RELIABLE, ...)
	end)
	unreliable.OnServerEvent:Connect(function(player: Player, ...: unknown)
		remotes.handler(player, UNRELIABLE, ...)
	end)
end

local function createRemotes(remotes: Remotes)
	local folder = Instance.new("Folder")
	folder.Name = FOLDER_NAME

	local reliable = Instance.new("RemoteEvent")
	reliable.Name = RELIABLE_NAME
	reliable.Parent = folder

	local unreliable = Instance.new("UnreliableRemoteEvent")
	unreliable.Name = UNRELIABLE_NAME
	unreliable.Parent = folder

	listenOnServer(remotes, reliable, unreliable)
	remotes.reliable = reliable
	remotes.unreliable = unreliable
	folder.Parent = ReplicatedStorage
end

local function onRemoteFound(remotes: Remotes, child: Instance)
	if remotes.reliable == nil and child.Name == RELIABLE_NAME and child:IsA("RemoteEvent") then
		remotes.reliable = child
		child.OnClientEvent:Connect(function(...: unknown)
			remotes.handler(nil, RELIABLE, ...)
		end)
		return
	end

	if remotes.unreliable ~= nil or child.Name ~= UNRELIABLE_NAME then
		return
	end

	if child:IsA("UnreliableRemoteEvent") then
		remotes.unreliable = child
		child.OnClientEvent:Connect(function(...: unknown)
			remotes.handler(nil, UNRELIABLE, ...)
		end)
	end
end

local function onFolderFound(remotes: Remotes, child: Instance)
	local folderWatch = remotes.folderWatch
	if child.Name ~= FOLDER_NAME or not child:IsA("Folder") or folderWatch == nil then
		return
	end

	folderWatch:Disconnect()
	remotes.folderWatch = nil
	child.ChildAdded:Connect(function(remote: Instance)
		onRemoteFound(remotes, remote)
	end)
	for _, remote in child:GetChildren() do
		onRemoteFound(remotes, remote)
	end
end

local function watchForRemotes(remotes: Remotes)
	remotes.folderWatch = ReplicatedStorage.ChildAdded:Connect(function(child: Instance)
		onFolderFound(remotes, child)
	end)

	local folder = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
	if folder ~= nil then
		onFolderFound(remotes, folder)
	end
end

local function transportOf(side: "server" | "client"): Host.Transport
	local remotes: Remotes = {
		reliable = nil,
		unreliable = nil,
		handler = ignoreReceived,
		folderWatch = nil,
	}

	local function open()
		if side == "server" then
			createRemotes(remotes)
			return
		end

		watchForRemotes(remotes)
	end

	local function ready(): boolean
		return remotes.reliable ~= nil and remotes.unreliable ~= nil
	end

	local function send(player: Player?, lane: Host.Lane, frame: buffer, instances: { Instance? }?)
		if side == "client" and lane == RELIABLE then
			(remotes.reliable :: RemoteEvent):FireServer(frame, instances)
		elseif side == "client" then
			(remotes.unreliable :: UnreliableRemoteEvent):FireServer(frame, instances)
		elseif lane == RELIABLE then
			(remotes.reliable :: RemoteEvent):FireClient(player :: Player, frame, instances)
		else
			(remotes.unreliable :: UnreliableRemoteEvent):FireClient(player :: Player, frame, instances)
		end
	end

	local function broadcast(lane: Host.Lane, frame: buffer, instances: { Instance? }?)
		if lane == RELIABLE then
			(remotes.reliable :: RemoteEvent):FireAllClients(frame, instances)
		else
			(remotes.unreliable :: UnreliableRemoteEvent):FireAllClients(frame, instances)
		end
	end

	local function onReceive(handler: Handler)
		remotes.handler = handler
	end

	return {
		open = open,
		ready = ready,
		send = send,
		broadcast = broadcast,
		onReceive = onReceive,
	}
end

-- Public ------------------------------------------------------------------------------------------

--[=[
	Builds the host for one side of a live game.

	@param  side "server" or "client", the side this process runs
	@return the host, whose transport is not open yet
]=]
function Roblox.host(side: "server" | "client"): Host.Host
	local random = Random.new()

	local function now(): number
		return workspace:GetServerTimeNow()
	end

	local function entropy32(): number
		return random:NextInteger(0, 2 ^ 32 - 1)
	end

	local function spawn(f: (...any) -> (), ...: any): thread
		return task.spawn(f, ...)
	end

	local function report(message: string)
		task.spawn(error, message, 0)
	end

	local function warnConsole(template: string, context: { [string]: any })
		if IS_STRUCTURED_LOGGING then
			LogService:Warn(template, context)
			return
		end

		warn(template)
	end

	local function onStep(f: (dt: number) -> ()): () -> ()
		return disconnectorOf(RunService.PostSimulation:Connect(f))
	end

	local function onClose(f: () -> ())
		game:BindToClose(f)
	end

	local function players(): { Player }
		return Players:GetPlayers()
	end

	local function onPlayerAdded(f: (player: Player) -> ()): () -> ()
		return disconnectorOf(Players.PlayerAdded:Connect(f))
	end

	local function onPlayerRemoving(f: (player: Player) -> ()): () -> ()
		return disconnectorOf(Players.PlayerRemoving:Connect(function(player: Player)
			f(player)
		end))
	end

	return {
		side = side,
		now = now,
		clock = os.clock,
		entropy32 = entropy32,
		spawn = spawn,
		report = report,
		warn = warnConsole,
		onStep = onStep,
		onClose = onClose,
		players = players,
		onPlayerAdded = onPlayerAdded,
		onPlayerRemoving = onPlayerRemoving,
		localPlayer = if side == "client" then Players.LocalPlayer else nil,
		transport = transportOf(side),
	}
end

return table.freeze(Roblox)
