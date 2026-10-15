--!strict

--[=[
	sides

	Typing proof (v5.md §3.5, §10 item 1): calls made on the wrong side are type errors. The
	expected output records their text, which names neither the side nor the definition.
]=]


-- Imports -----------------------------------------------------------------------------------------

local Types = require("../../src/types")
local arena = require("./arena")


-- Main --------------------------------------------------------------------------------------------

local server = (nil :: any) :: Types.ServerView<typeof(arena)>
local client = (nil :: any) :: Types.ClientView<typeof(arena)>

server.chat:fire("gg")
client.announce:fire({ kind = "round", number = 3 })
client.buy:handle(function(_request)
	return 0
end)
