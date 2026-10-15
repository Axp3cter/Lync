--!nocheck
-- Injects Lune's Roblox datatypes as globals (as test/run.luau does) and returns the src modules.
local roblox = require("@lune/roblox")
local environment = getfenv(0)
environment.Vector3 = roblox.Vector3
environment.CFrame = roblox.CFrame
environment.Color3 = roblox.Color3
environment.Instance = roblox.Instance
environment.Enum = roblox.Enum

local SRC = "../../../../src"
return {
	Lync = require(SRC),
	Bits = require(SRC .. "/wire/bits"),
	Ints = require(SRC .. "/wire/ints"),
	Column = require(SRC .. "/wire/column"),
	Quant = require(SRC .. "/wire/quant"),
	Leaves = require(SRC .. "/codec/leaves"),
	Rows = require(SRC .. "/codec/rows"),
	Columns = require(SRC .. "/codec/columns"),
	Run = require(SRC .. "/codec/run"),
	plan = function(Lync, codec)
		return Lync.schema("p", { e = Lync.event({ from = "client", data = codec }) }).ir.byName.e.data
	end,
}
