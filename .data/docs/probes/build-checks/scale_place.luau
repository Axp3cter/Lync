--!nocheck
-- Builds a place of about N instances for timing the checks (Lune 0.11.0).
-- Usage: lune run scale_place.luau OUT.rbxl N SCRIPTS CORPUS_LIST
--   N: total instances; SCRIPTS: how many of them are scripts; CORPUS_LIST: a file with one Luau file path per line,
--   cycled as script sources. One remote (RemoteEvent, RemoteFunction or UnreliableRemoteEvent in turn) per 500
--   instances, and one BindableEvent per 1000 (both in Workspace models). A fifth of the scripts are LocalScripts under StarterPlayerScripts, two
--   fifths ModuleScripts in ReplicatedStorage, the rest Scripts in ServerScriptService. Every 50th client script
--   requires the shard and indexes it with a computed key (a dynamicAccess site).
local fs = require("@lune/fs")
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local Instance, Vector3 = roblox.Instance, roblox.Vector3

local out, N, S = process.args[1], tonumber(process.args[2]), tonumber(process.args[3])
local corpus = {}
for p in string.gmatch(fs.readFile(process.args[4]), "[^\n]+") do
	local src = fs.readFile(p)
	if utf8.len(src) then table.insert(corpus, src) end -- Source must be UTF-8 for rbx-dom
end

local game = Instance.new("DataModel")
local RS, SSS, WS = game:GetService("ReplicatedStorage"), game:GetService("ServerScriptService"), game:GetService("Workspace")
local SPS = Instance.new("StarterPlayerScripts"); SPS.Parent = game:GetService("StarterPlayer")
local shard = Instance.new("ModuleScript"); shard.Name = "client"; shard.Source = "return {}"
local shared = Instance.new("Folder"); shared.Name = "Shared"; shared.Parent = RS
local net = Instance.new("Folder"); net.Name = "Net"; net.Parent = shared; shard.Parent = net

local count = 5
local scripts, remotes = 0, 0
local CLASSES = { "RemoteEvent", "RemoteFunction", "UnreliableRemoteEvent" }
local model
local t0 = os.clock()
while count < N do
	if count % 40 == 0 or not model then
		model = Instance.new("Model"); model.Name = "M" .. count; model.Parent = WS
		count += 1
	end
	local inst
	if count % 500 == 250 then
		remotes += 1
		inst = Instance.new(CLASSES[remotes % 3 + 1]); inst.Name = "R" .. remotes; inst.Parent = model
	elseif count % 1000 == 900 then
		inst = Instance.new("BindableEvent"); inst.Name = "B" .. count; inst.Parent = model
	elseif scripts < S and count % math.max(1, (N // S) - 1) == 0 then
		scripts += 1
		local r = scripts % 5
		local src = corpus[(scripts % #corpus) + 1]
		if r == 0 then
			inst = Instance.new("LocalScript"); inst.Parent = SPS
		elseif r <= 2 then
			inst = Instance.new("ModuleScript"); inst.Parent = RS
		else
			inst = Instance.new("Script"); inst.Parent = SSS
		end
		if r <= 2 and scripts % 50 == 0 then
			src = "local Net = require(game.ReplicatedStorage.Shared.Net.client)\nlocal k = 'x'\nNet[k]:fire()\n" .. src
		end
		inst.Name = "S" .. scripts
		inst.Source = src
	else
		inst = Instance.new("Part"); inst.Name = "P" .. count; inst.Size = Vector3.new(4, 1, 2); inst.Parent = model
	end
	count += 1
end
local t1 = os.clock()
local bytes = roblox.serializePlace(game)
fs.writeFile(out, bytes)
print(string.format("N=%d scripts=%d remotes=%d fileBytes=%d build=%.0fms serialize=%.0fms", #game:GetDescendants(),
	scripts, remotes, #bytes, (t1 - t0) * 1e3, (os.clock() - t1) * 1e3))
