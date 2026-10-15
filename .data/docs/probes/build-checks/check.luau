--!nocheck
-- Runs the foreignRemotes and dynamicAccess checks over a built place, as the CLI would (Lune 0.11.0, rbx-dom).
-- Usage: lune run check.luau PLACE.rbxl [quiet]
-- Prints the findings (unless quiet) and the time of each phase.
local fs = require("@lune/fs")
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local scan = require("./scan")

local CLASSES = { RemoteEvent = "network", UnreliableRemoteEvent = "network", RemoteFunction = "network",
	BindableEvent = "local", BindableFunction = "local" }
local SERVER_ONLY = { ServerScriptService = true, ServerStorage = true }
-- Lync's remotes: exactly these two instances, of exactly these classes (v5.md §4.1)
local LYNC_REMOTES = { ["ReplicatedStorage.Lync.Reliable"] = "RemoteEvent", ["ReplicatedStorage.Lync.Unreliable"] = "UnreliableRemoteEvent" }
local quiet = process.args[2] == "quiet"

local t0 = os.clock()
local bytes = fs.readFile(process.args[1])
local t1 = os.clock()
local game = roblox.deserializePlace(bytes)
local t2 = os.clock()

local function pathOf(inst)
	local parts = {}
	local node = inst
	while node and node ~= game do
		table.insert(parts, 1, node.Name)
		node = node.Parent
	end
	return table.concat(parts, ".")
end
local function topService(inst)
	local node = inst
	while node.Parent and node.Parent ~= game do node = node.Parent end
	return node.ClassName
end

local all = game:GetDescendants()
local t3 = os.clock()

-- Lync's package subtree: a ModuleScript whose first line is the runtime header, and its descendants
local lyncRoots = {}
local inventory, scripts = {}, {}
for _, inst in all do
	local cls = inst.ClassName
	if cls == "ModuleScript" and string.find(inst.Source, "^%-%- Lync %S+ runtime") then
		lyncRoots[inst] = true
	end
end
local function inLync(inst)
	local node = inst
	while node do
		if lyncRoots[node] then return true end
		node = node.Parent
	end
	return false
end
for _, inst in all do
	local cls = inst.ClassName
	local kind = CLASSES[cls]
	if kind then
		local path = pathOf(inst)
		if LYNC_REMOTES[path] ~= cls then
			table.insert(inventory, { path = path, class = cls, network = kind == "network",
				replicates = not SERVER_ONLY[topService(inst)] })
		end
	elseif cls == "LocalScript" or cls == "Script" or cls == "ModuleScript" then
		local client = cls == "LocalScript" or (cls == "Script" and inst.RunContext == roblox.Enum.RunContext.Client)
			or not SERVER_ONLY[topService(inst)]
		table.insert(scripts, { path = pathOf(inst), name = inst.Name, source = inst.Source, client = client, lync = inLync(inst) })
	end
end
local t4 = os.clock()
local findings, stats = scan(scripts, { client = "Net" })
local t5 = os.clock()

local srcBytes = 0
for _, s in scripts do srcBytes += #s.source end
if not quiet then
	table.sort(inventory, function(a, b) return a.path < b.path end)
	for _, r in inventory do
		print(string.format("foreignRemotes  tree      %-22s %-48s network=%d replicates=%d", r.class, r.path,
			r.network and 1 or 0, r.replicates and 1 or 0))
	end
	for _, f in findings do
		print(string.format("%-15s kind=%d  %s:%d:%d  %s", f.check, f.kind, f.path, f.line, f.col, f.detail))
	end
end
print(string.format("instances=%d scripts=%d sourceBytes=%d tokens=%d rounds=%d inventory=%d findings=%d",
	#all, #scripts, srcBytes, stats.tokens, stats.rounds, #inventory, #findings))
print(string.format("ms: read=%.1f deserialize=%.1f descendants=%.1f classify=%.1f scan=%.1f total=%.1f",
	(t1 - t0) * 1e3, (t2 - t1) * 1e3, (t3 - t2) * 1e3, (t4 - t3) * 1e3, (t5 - t4) * 1e3, (t5 - t0) * 1e3))
