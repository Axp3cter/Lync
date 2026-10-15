--!strict
-- stand-in for the generated client shard (the typed API game code requires)
local Net = {}
local function def() return { fire = function(self, v) end, invoke = function(self, v) return { ok = true, value = 0 } end } end
Net.strike = def()
Net.move6 = def()
Net.chat = def()
Net.buy = def()
Net.announce = def()
return Net
