--!strict
--!optimize 2
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Net = require(ReplicatedStorage.Shared.Net.client)

local function onHit(target: number, aim: Vector3)
	Net.strike:fire({ target = target, aim = aim })
end

local function onMove(state)
	Net.move6:fire({
		a = state.a,
		b = state.b,
		c = state.crouch,
		d = state.speed,
		e = state.mode,
		f = state.frame,
	})
end

local function shop()
	Net.buy:fire({ item = "sword" })
	local result = Net.buy:invoke({ item = "shield" }) -- expression context: left to the shard
	return result
end

return { onHit = onHit, onMove = onMove, shop = shop }
