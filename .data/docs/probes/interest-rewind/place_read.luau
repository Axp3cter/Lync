--!nocheck
-- What a build host (Lune 0.11.0, rbx-dom) can read from a place file for a PVS bake.
-- Builds a small place, writes it as .rbxl, reads it back, and reports which geometry
-- properties survive and can be read. Usage: lune run place_read.luau OUTDIR
local fs = require("@lune/fs")
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local Instance, Vector3, CFrame = roblox.Instance, roblox.Vector3, roblox.CFrame

local out = process.args[1]
local game = Instance.new("DataModel")
local ws = game:GetService("Workspace")

local wall = Instance.new("Part")
wall.Name = "Wall"; wall.Size = Vector3.new(40, 20, 2); wall.CFrame = CFrame.new(0, 10, 0) * CFrame.Angles(0, math.rad(30), 0)
wall.CanCollide = true; wall.Transparency = 0; wall.Parent = ws

local glass = Instance.new("Part")
glass.Name = "Glass"; glass.Size = Vector3.new(10, 10, 1); glass.Transparency = 0.6; glass.Parent = ws

local ball = Instance.new("Part")
ball.Name = "Ball"; ball.Shape = roblox.Enum.PartType.Ball; ball.Size = Vector3.new(6, 6, 6); ball.Parent = ws

local mesh = Instance.new("MeshPart")
mesh.Name = "Rock"; mesh.Size = Vector3.new(12, 8, 12); mesh.Parent = ws

local union = Instance.new("UnionOperation")
union.Name = "Arch"; union.Size = Vector3.new(16, 12, 4); union.Parent = ws

local terrainIn = Instance.new("Terrain")
terrainIn.Parent = ws

local path = out .. "/probe.rbxl"
fs.writeFile(path, roblox.serializePlace(game))
local back = roblox.deserializePlace(fs.readFile(path))
local ws2 = back:GetService("Workspace")

local function try(f)
	local ok, v = pcall(f)
	return if ok then tostring(v) else ("error: " .. (string.match(tostring(v), "[^\n]+") or ""))
end

for _, inst in ws2:GetDescendants() do
	if inst:IsA("BasePart") then
		print(string.format("%s (%s): Size=%s CanCollide=%s Transparency=%s", inst.Name, inst.ClassName,
			try(function() return inst.Size end), try(function() return inst.CanCollide end), try(function() return inst.Transparency end)))
		print("  CFrame.Position=" .. try(function() return inst.CFrame.Position end))
		if inst.ClassName == "Part" then print("  Shape=" .. try(function() return inst.Shape end)) end
		if inst:IsA("MeshPart") then
			print("  MeshId=" .. try(function() return inst.MeshId end))
			print("  PhysicalConfigData=" .. try(function() return typeof(inst.PhysicalConfigData) end))
		end
		if inst:IsA("UnionOperation") then
			print("  AssetId=" .. try(function() return inst.AssetId end))
			print("  MeshData=" .. try(function() return typeof(inst.MeshData) end))
		end
	end
end
local terrain = ws2:FindFirstChildOfClass("Terrain")
print("Terrain instance: " .. tostring(terrain))
if terrain then
	print("Terrain.SmoothGrid: " .. try(function() return typeof(terrain.SmoothGrid) end))
	print("Terrain:ReadVoxels: " .. try(function() return typeof(terrain.ReadVoxels) end))
end
print("Workspace:Raycast: " .. try(function() return ws2:Raycast(Vector3.new(0, 10, -20), Vector3.new(0, 0, 40)) end))
