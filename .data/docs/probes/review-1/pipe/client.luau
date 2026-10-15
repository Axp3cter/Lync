--!strict
local Lync = require("./lync")
local Net = Lync.client(require("./schema"))
Net.chat:fire("gg")
Net.chat:fire(5) -- must fail
Net.announce:connect(function(a)
	if a.kind == "round" then
		local _n: number = a.number
	else
		local _s: "red" | "blue" = a.team
	end
end)
local result = Net.buy:invoke({ item = "sword" })
if result.ok then
	local v: number = result.value
else
	local e: Lync.Failure = result.error
	local _bad = result.value -- must fail: no value on failure
end
local _x = Net.buy:invoke({ item = "axe" }) -- must fail if enum is exact
local f = Net.fighters:get(1)
if f then
	local _r: "REVEAL_fighter" = f
end
