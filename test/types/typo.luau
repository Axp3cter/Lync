--!strict

--[=[
	typo

	Typing proof (v5.md §10 item 1, review-2 M3): requiring a schema with a misspelled codec
	constructor through both views gives diagnostics and no crash, on luau-analyze and luau-lsp.
	Before type functions returned marker types instead of calling `error()`, this crashed both.
]=]


-- Imports -----------------------------------------------------------------------------------------

local Types = require("../../src/types")
local schema = require("./typo_schema")


-- Main --------------------------------------------------------------------------------------------

local server = (nil :: any) :: Types.ServerView<typeof(schema)>
local client = (nil :: any) :: Types.ClientView<typeof(schema)>

server.chat:connect(function(_player, text)
	print(#text)
end)

client.confirm:handle(function(text)
	return #text > 0
end)
