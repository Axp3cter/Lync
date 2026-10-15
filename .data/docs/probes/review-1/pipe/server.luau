--!strict
local Lync = require("./lync")
local Net = Lync.server(require("./schema"))
local player: Lync.Player = { Name = "a", UserId = 1 }

Net.chat:validate(function(p, text)
	local _r: "REVEAL_chat_text" = text
	return nil
end)
Net.chat:connect(function(p, text)
	local _n: number = text -- must fail: text is string
end)
Net.strike:connect(function(p, s)
	local _r: "REVEAL_strike" = s
end)
Net.announce:fire(player, { kind = "round", number = 3 }) -- ok
Net.announce:fire(player, { kind = "round", team = "red" }) -- must fail
Net.announce:fire(player, { kind = "winner", team = "green" }) -- must fail (enum)
Net.chat:fire(player, "x") -- must fail: wrong side
Net.ping:fire(player) -- no payload: should be allowed
Net.buy:handle(function(p, req)
	local _r: "REVEAL_buy_req" = req
	return 5
end)
Net.fighters:set(1, { name = "n", health = 100, position = vector.zero, nested = {} })
Net.fighters:patch(1, { health = 90 }) -- ok
Net.fighters:patch(1, { healht = 90 }) -- must fail
Net.fighters:patch(1, { health = "x" }) -- must fail
Net.fighters:patch(1, { title = nil }) -- clearing an optional
Net.chat:connect(function(p, text, extra) end) -- extra param: accepted?
