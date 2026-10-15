--!nocheck
-- U15: what a build host (Lune 0.11.0, rbx-dom) can read from a place file for streaming and staged-release
-- checks. Builds a place, writes it as .rbxl, reads it back, and reports:
--   1. the Workspace streaming properties (NotScriptable in game scripts, but serialized: can_save true);
--   2. where a staged namespace's modules sit, classified by whether the container replicates to clients;
--   3. Workspace non-BasePart instances, which replicate at join regardless of the streaming radius.
-- Usage: lune run stream_read.luau OUTDIR
local fs = require("@lune/fs")
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local Instance = roblox.Instance

local out = process.args[1]
local game = Instance.new("DataModel")
local ws = game:GetService("Workspace")

local function try(f)
	local ok, v = pcall(f)
	return if ok then tostring(v) else ("error: " .. (string.match(tostring(v), "[^\n]+") or ""))
end

print("set StreamingEnabled: " .. try(function() ws.StreamingEnabled = true; return "ok" end))
print("set StreamingTargetRadius: " .. try(function() ws.StreamingTargetRadius = 512; return "ok" end))
print("set StreamingMinRadius: " .. try(function() ws.StreamingMinRadius = 64; return "ok" end))
print("set StreamOutBehavior: " .. try(function() ws.StreamOutBehavior = roblox.Enum.StreamOutBehavior.Opportunistic; return "ok" end))
print("set ModelStreamingBehavior: " .. try(function() ws.ModelStreamingBehavior = roblox.Enum.ModelStreamingBehavior.Improved; return "ok" end))

-- a staged namespace "season2": one copy correctly in ServerStorage, one mistakenly in ReplicatedStorage
local staged = Instance.new("ModuleScript")
staged.Name = "season2"
staged.Source = 'return Lync.schema("season2", { dragonblade = Lync.event({ from = "server" }) })'
staged.Parent = game:GetService("ServerStorage")
local leaked = staged:Clone()
leaked.Parent = game:GetService("ReplicatedStorage")

-- a Workspace folder of values: replicated at join, whatever the radius
local folder = Instance.new("Folder")
folder.Name = "Unreleased"
folder:SetAttribute("nextBoss", "Wyrm")
folder.Parent = ws

local path = out .. "/stream_probe.rbxl"
fs.writeFile(path, roblox.serializePlace(game))
local back = roblox.deserializePlace(fs.readFile(path))
local ws2 = back:GetService("Workspace")

for _, name in { "StreamingEnabled", "StreamingTargetRadius", "StreamingMinRadius", "StreamOutBehavior",
	"ModelStreamingBehavior", "StreamingIntegrityMode" } do
	print(string.format("read back Workspace.%s = %s", name, try(function() return ws2[name] end)))
end

-- containers whose descendants reach every client (docs: ReplicatedStorage, ReplicatedFirst, Workspace,
-- StarterGui, StarterPack, StarterPlayer, and anything copied from them into a player; Lighting, SoundService,
-- Teams and Chat are included as replicated services by assumption, unverified); never: ServerStorage,
-- ServerScriptService
local REPLICATED = { ReplicatedStorage = true, ReplicatedFirst = true, Workspace = true, StarterGui = true,
	StarterPack = true, StarterPlayer = true, Lighting = true, SoundService = true, Teams = true, Chat = true }
for _, service in back:GetChildren() do
	for _, d in service:GetDescendants() do
		if d:IsA("ModuleScript") then
			local reaches = if REPLICATED[service.ClassName] then "every client" else "no client"
			local mentions = string.find(d.Source, 'schema%("season2"') ~= nil
			print(string.format("ModuleScript %s.%s: reaches %s; declares namespace season2: %s",
				service.ClassName, d:GetFullName(), reaches, tostring(mentions)))
		end
	end
end
for _, d in ws2:GetDescendants() do
	if not d:IsA("BasePart") and not d:IsA("Terrain") and not d:IsA("Camera") then
		print(string.format("Workspace non-BasePart %s (%s), attributes %s: replicated at join (streaming scope excludes only BaseParts and atomic/persistent models)",
			d:GetFullName(), d.ClassName, try(function()
				local n = 0
				for _ in d:GetAttributes() do
					n += 1
				end
				return n
			end)))
	end
end
