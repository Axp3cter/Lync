--!strict
-- review-2: server.luau against schema_typo.luau (one misspelled codec constructor)
local Lync = require("./lync")
local Net = Lync.server(require("./schema_typo"))
local player: Lync.Player = { Name = "a", UserId = 1 }

Net.chat:validate(function(p, text)
	return string.find(text, "%S") ~= nil
end)
Net.chat:validate(function(p, text)
	return nil -- must fail: draft 2 validate returns boolean
end)
local c = Net.chat:connect(function(p, text) end)
c:disconnect()
Net.strike:refers("target", "fighters")
Net.strike:refers("tagret", "fihgters") -- typos: accepted statically?
Net.chat:trap()
Net.fighters:set(1, { name = "n", health = 100, position = vector.zero, look = { Position = vector.zero } })
Net.fighters:canary("titel") -- typo: accepted statically?
Net.fighters:decoys(function(viewer, tick)
	return { [999] = { name = "x", health = 1, position = vector.zero, look = { Position = vector.zero } } }
end, { maxPerViewer = 1 })
Net.round:set({ endsAt = 600, phase = "play" }) -- singleton: no key
Net.round:set(1, { endsAt = 600, phase = "play" }) -- must fail: singleton takes no key
local r = Net.confirm:invoke(player, "rematch?")
if r.ok then
	local _b: boolean = r.value
end
Net.confirm:invoke("rematch?") -- must fail: server invoke takes a player
