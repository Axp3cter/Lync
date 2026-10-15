-- mocks for running a fixture script outside Roblox: game:GetService, instance paths, require of the shard
local function inst(path)
	return setmetatable({ __path = path }, {
		__index = function(self, k)
			if k == "WaitForChild" or k == "FindFirstChild" then
				return function(s, name) return inst(s.__path .. "." .. name) end
			end
			return inst(self.__path .. "." .. k)
		end,
	})
end
game = { GetService = function(_, name) return inst(name) end }
Net.__lync = setmetatable({ E_x_y_z = { x = 0, y = 1, z = 2 }, E_shield_sword = { shield = 0, sword = 1 } }, { __index = RT })
require = function(i)
	assert(i.__path == "ReplicatedStorage.Shared.Net.client", i.__path)
	return Net
end
return nil
