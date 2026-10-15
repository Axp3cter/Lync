--!strict
-- T7: realistic user file (no reveal annotations) checked under the OLD solver
local Net = require("./net")
Net.hitB:connect(function(value, player)
	local s: string = value.target -- wrong (target is number): reported?
	local t: number = value.nope -- nonexistent field: reported?
	print(s, t, player.Name)
end)
Net.hitA:connect(function(value, player)
	local s: string = value.target
	print(s)
end)
Net.hitB:fire({ target = "1" }) -- wrong: reported?
Net.hitA:fire({ target = "1" })
Net.hitB:nonexistent() -- reported?
local x: number = "str" -- control: a plain error in the user file must still be reported
return nil
