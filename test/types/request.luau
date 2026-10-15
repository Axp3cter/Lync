--!strict

--[=[
	request

	Typing proof (v5.md §10 item 1): the `Lync.request` signature checks cleanly, and both
	directions of a request are typed through the views.
]=]


-- Imports -----------------------------------------------------------------------------------------

local Types = require("../../src/types")
local arena = require("./arena")


-- Main --------------------------------------------------------------------------------------------

local server = (nil :: any) :: Types.ServerView<typeof(arena)>
local client = (nil :: any) :: Types.ClientView<typeof(arena)>
local player = (nil :: any) :: Player

server.buy:handle(function(_player, request)
	local item: string = request.item
	return #item
end)

local bought = client.buy:invoke({ item = "sword" })
if bought.ok then
	local price: number = bought.value
	print(price)
end

client.confirm:handle(function(text)
	local question: string = text
	return #question > 0
end)

local confirmed = server.confirm:invoke(player, "rematch?")
if confirmed.ok then
	local isYes: boolean = confirmed.value
	print(isYes)
end
