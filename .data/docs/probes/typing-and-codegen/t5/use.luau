--!strict
-- consumer: no annotations on handlers
local Net = require("./net")

-- hover-equivalents
Net.hitA:connect(function(value, player)
	local _ra: "REVEAL_hitA" = value
	local _rp: "REVEAL_playerA" = player
	local _bad: string = value.target -- must fail
end)
Net.hitB:connect(function(value, player)
	local _rb: "REVEAL_hitB" = value
	local _rp: "REVEAL_playerB" = player
	local _bad: string = value.target -- must fail
end)
Net.hitC:connect(function(value, player)
	local _rc: "REVEAL_hitC" = value
	local _bad: string = value.target -- must fail
end)
Net.shotA:connect(function(value)
	if value.kind == "miss" then
		local _r: string = value.reason
		local _bad: number = value.target -- must fail
	end
end)
Net.shotB:connect(function(value)
	if value.kind == "miss" then
		local _r: string = value.reason
		local _bad: number = value.target -- must fail
	end
end)
Net.shotC:connect(function(value)
	local _r: "REVEAL_shotC" = value
end)
Net.numB:connect(function(v) local _r: "REVEAL_numB" = v end)
Net.numC:connect(function(v) local _r: "REVEAL_numC" = v end)
Net.listB:connect(function(v) local _r: "REVEAL_listB" = v end)
Net.listC:connect(function(v) local _r: "REVEAL_listC" = v end)

-- fire: good then bad
Net.hitA:fire({ target = 1, pos = { x = 1, y = 2 } })
Net.hitA:fire({ target = "1", pos = { x = 1, y = 2 } }) -- must fail FIRE_A_WRONG
Net.hitA:fire({ target = 1 }) -- must fail FIRE_A_MISSING
Net.hitB:fire({ target = 1, pos = { x = 1, y = 2 } })
Net.hitB:fire({ target = "1", pos = { x = 1, y = 2 } }) -- must fail FIRE_B_WRONG
Net.hitB:fire({ target = 1 }) -- must fail FIRE_B_MISSING
Net.hitC:fire({ target = "1", pos = { x = 1, y = 2 } }) -- must fail FIRE_C_WRONG
Net.shotB:fire({ kind = "miss", reason = "r" })
Net.shotB:fire({ kind = "miss", target = 1 }) -- must fail FIRE_SHOTB
Net.numB:fire("x") -- must fail
Net.numC:fire("x") -- must fail

-- handler with a wrong annotation must be rejected
Net.hitB:connect(function(value: string) end) -- must fail
-- handler assigned to a local first (not passed inline)
local h = function(value, player) local _r: "REVEAL_assigned" = value end
Net.hitB:connect(h)
return nil
