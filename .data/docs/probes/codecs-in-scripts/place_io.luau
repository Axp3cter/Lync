-- Lune 0.11: read every script of a place file into JSON, or write sources back into a copy of the place.
--   lune run place_io.luau dump IN.rbxl OUT.json
--   lune run place_io.luau apply IN.rbxl SOURCES.json OUT.rbxl
local fs = require("@lune/fs")
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")

local mode, input = process.args[1], process.args[2]
local game = roblox.deserializePlace(fs.readFile(input))

local function pathOf(inst)
	local parts = {}
	local node = inst
	while node and node ~= game do
		table.insert(parts, 1, node.Name)
		node = node.Parent
	end
	return table.concat(parts, ".")
end

if mode == "dump" then
	local out = {}
	for _, inst in game:GetDescendants() do
		if inst:IsA("LuaSourceContainer") then
			local runContext = if inst:IsA("Script") then tostring(inst.RunContext) else nil
			table.insert(out, { path = pathOf(inst), className = inst.ClassName, runContext = runContext, source = inst.Source })
		end
	end
	fs.writeFile(process.args[3], serde.encode("json", out, true))
elseif mode == "apply" then
	local sources = serde.decode("json", fs.readFile(process.args[3]))
	local byPath = {}
	for _, s in sources do
		byPath[s.path] = s.source
	end
	local n = 0
	for _, inst in game:GetDescendants() do
		if inst:IsA("LuaSourceContainer") and byPath[pathOf(inst)] then
			inst.Source = byPath[pathOf(inst)]
			n += 1
		end
	end
	fs.writeFile(process.args[4], roblox.serializePlace(game))
	print("applied", n)
end
