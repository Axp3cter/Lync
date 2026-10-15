--!nocheck
-- Writes a model file holding a Tool with a RemoteEvent and a Script inside (a gear from the Toolbox, say).
-- Usage: lune run make_rbxm.luau OUT.rbxm
local fs = require("@lune/fs")
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local tool = roblox.Instance.new("Tool"); tool.Name = "Slingshot"
local re = roblox.Instance.new("RemoteEvent"); re.Name = "Fire"; re.Parent = tool
local sc = roblox.Instance.new("Script"); sc.Name = "Handler"; sc.Source = 'script.Parent.Fire.OnServerEvent:Connect(print)'; sc.Parent = tool
fs.writeFile(process.args[1], roblox.serializeModel({ tool }))
