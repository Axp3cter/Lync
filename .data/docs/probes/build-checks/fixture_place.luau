--!nocheck
-- Builds the build-checks fixture place (Lune 0.11.0). Usage: lune run fixture_place.luau OUT.rbxl
-- Every case is listed with the finding the checks must give (EXPECT) or must not give (CLEAN).
local fs = require("@lune/fs")
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local Instance = roblox.Instance

local game = Instance.new("DataModel")
local RS = game:GetService("ReplicatedStorage")
local SSS = game:GetService("ServerScriptService")
local SS = game:GetService("ServerStorage")
local WS = game:GetService("Workspace")
local SP = game:GetService("StarterPlayer")
local SPS = Instance.new("StarterPlayerScripts"); SPS.Parent = SP
local Chat = game:GetService("Chat")

local function new(class, name, parent, props)
	local i = Instance.new(class)
	i.Name = name
	for k, v in props or {} do i[k] = v end
	i.Parent = parent
	return i
end
local function script(class, name, parent, source, props)
	return new(class, name, parent, { Source = source })
end

-- Lync's own remotes, pre-created by a developer: owned by Lync (CLEAN)
local lyncFolder = new("Folder", "Lync", RS)
new("RemoteEvent", "Reliable", lyncFolder)
new("UnreliableRemoteEvent", "Unreliable", lyncFolder)
-- Lync's package: its runtime creates the remotes; the header marks the subtree as Lync's (CLEAN)
local pk = new("Folder", "Packages", RS)
local idx = new("Folder", "_Index", pk)
local lyncPkg = script("ModuleScript", "lync", new("Folder", "axp3cter_lync@5.0.0", idx),
	'-- Lync 5.0.0 runtime. MIT License.\nlocal r = Instance.new("RemoteEvent")\nr.Name = "Reliable"\nreturn {}\n')
script("ModuleScript", "transport", lyncPkg, '-- part of the runtime\nlocal u = Instance.new("UnreliableRemoteEvent")\nreturn u\n')

-- EXPECT foreignRemotes tree: a game remote, a remote inside a gear Tool in Workspace, one in ServerStorage
local remotes = new("Folder", "Remotes", RS)
new("RemoteEvent", "LegacyShop", remotes)
new("RemoteFunction", "GetProfile", remotes)
local tool = new("Tool", "Slingshot", WS)
new("RemoteEvent", "Fire", tool)
new("RemoteFunction", "AdminCommand", new("Folder", "Admin", SS))
-- EXPECT foreignRemotes tree, bindables (not network entry points): one replicated, one server-only
new("BindableEvent", "RoundStarted", RS)
new("BindableFunction", "GetRound", SSS)

-- EXPECT foreignRemotes creation sites: a third-party framework creating remotes at run time, literal and not
local knit = new("Folder", "knit", idx)
script("ModuleScript", "Comm", knit, [[
local Comm = {}
function Comm.createSignal(parent, name)
	local re = Instance.new("RemoteEvent")
	re.Name = name
	re.Parent = parent
	return re
end
function Comm.create(parent, className, name)
	local r = Instance.new(className) -- non-literal: class unknown to the build
	r.Name = name
	r.Parent = parent
	return r
end
return Comm
]])
-- a forked legacy chat runner creating its remotes (server-only script)
script("Script", "ChatServiceRunner", Chat, 'local f = Instance.new("Folder")\nlocal e = Instance.new("RemoteEvent")\nlocal fn = Instance.new("RemoteFunction")\n')

-- the namespace and its client shard
local net = new("Folder", "Net", new("Folder", "Shared", RS))
script("ModuleScript", "client", net, "local Net = {}\nNet.chat = {}\nNet.strike = {}\nreturn Net\n")
script("ModuleScript", "server", new("Folder", "Net", SSS), "return {}\n")

local client = new("Folder", "Client", SPS)
-- CLEAN: direct use, alias, local alias of a field, typed alias, cast alias
script("LocalScript", "Direct", client, [[
local Net = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Net"):WaitForChild("client"))
local chat = Net.chat
local N2: typeof(Net) = Net
local N3 = Net :: any
Net.strike:fire({ target = 1 })
chat:fire("gg")
N2.chat:fire("x")
N3.strike:fire({})
local s = Net["chat"] -- a literal index names the definition
print(typeof(Net))
]])
-- EXPECT dynamicAccess kind 1 (computed index), on the require binding and through an alias
script("LocalScript", "Computed", client, [[
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Net = require(ReplicatedStorage.Shared.Net.client)
local function send(name, value)
	Net[name]:fire(value)
end
local alias = Net
local key = "strike"
alias[key]:fire({})
]])
-- EXPECT dynamicAccess kind 2 (iteration): generalized, pairs, next
script("LocalScript", "Iterate", client, [[
local Net = require(game.ReplicatedStorage.Shared.Net.client)
for name, def in Net do def:fire(nil) end
for name, def in pairs(Net) do end
for name, def in next, Net do end
]])
-- CLEAN by name-following: the namespace stored in a field, returned from a module, passed to a function
-- the scan sees; EXPECT kind 1 where the followed value is then indexed with a computed key
local services = new("Folder", "Services", RS)
script("ModuleScript", "NetRef", services, [[
local Net = require(script.Parent.Parent.Shared.Net.client)
return Net
]])
script("ModuleScript", "Hud", services, [[
local Net = require(script.Parent.NetRef) -- a module that returns the namespace is a binding source
local Hud = {}
function Hud.new()
	local self = {}
	self.net = Net
	return self
end
function Hud.press(self, which)
	self.net.chat:fire("pressed")   -- CLEAN: named
	self.net[which]:fire("pressed") -- EXPECT kind 1 via the field `net`
end
return Hud
]])
script("ModuleScript", "Router", services, [[
local Net = require(script.Parent.NetRef)
local function wire(ns, names)
	for _, n in names do
		ns[n]:fire(true) -- EXPECT kind 1: `ns` is a parameter that receives the namespace below
	end
end
wire(Net, { "chat" })
Framework.register(Net) -- EXPECT kind 3: passed to a function the scan has no definition for
local registry = { Net }  -- EXPECT kind 3: stored positionally
]])
-- server-only code iterating its own view: not client code, not scanned for dynamicAccess (CLEAN)
script("Script", "AutoWire", SSS, [[
local Net = require(game.ReplicatedStorage.Shared.Net.client)
for name, def in Net do end
]])

-- a roblox-ts compiled client script
script("LocalScript", "TsClient", client, [[
local TS = require(game:GetService("ReplicatedStorage"):WaitForChild("rbxts_include"):WaitForChild("RuntimeLib"))
local Net = TS.import(script, game:GetService("ReplicatedStorage"), "Shared", "Net", "client")
local k = "chat"
Net[k]:fire("ts") -- EXPECT kind 1
]])

fs.writeFile(process.args[1], roblox.serializePlace(game))
print("wrote", process.args[1], #game:GetDescendants(), "instances")
