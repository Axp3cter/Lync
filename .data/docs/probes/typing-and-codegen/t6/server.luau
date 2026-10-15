--!strict
local Lync = require("./lync")
local Net = require("./net")
local SG = Lync.serverG(Net)
local SF = Lync.serverF(Net)
local p: Lync.Player = nil :: any

-- G: generic side types
SG.hit:connect(function(value, player)
	local _r: "REVEAL_G_value" = value
	local _rp: "REVEAL_G_player" = player
end)
SG.hit:fire(p, { target = 1, note = "x" }) -- ok
SG.hit:fireAll({ target = 1, note = "x" }) -- ok
SG.hit:fire({ target = 1, note = "x" }) -- client-style call on server view: must fail
SG.chat:fireServer("x") -- method that does not exist on server: must fail
SG.hit:fireAll({ target = "1", note = "x" }) -- wrong payload: must fail

-- F: type-function-built side types
SF.hit:connect(function(value, player)
	local _r: "REVEAL_F_value" = value
	local _rp: "REVEAL_F_player" = player
end)
SF.hit:fire(p, { target = 1, note = "x" }) -- ok
SF.hit:fire({ target = 1, note = "x" }) -- must fail
SF.chat:fireServer("x") -- must fail
SF.hit:fireAll({ target = "1", note = "x" }) -- must fail
return nil
