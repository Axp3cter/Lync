--!strict
local Lync = require("./lync")
local Net = Lync.client(require("./schema_typo"))
Net.confirm:handle(function(text)
	local _s: string = text
	return true
end)
local round = Net.round:get()
if round then
	local _r: "REVEAL_round" = round
end
local result = Net.buy:invoke({ item = "sword" })
if result.ok then
	local _v: number = result.value
end
