--!strict
-- Loop body for getfenv_deopt.luau, environment marked unsafe by getfenv.
local b = buffer.create(64)
local _ = getfenv(1)
local M = {}
function M.work(n: number): number
	local s = 0
	for i = 1, n do
		local v = bit32.bxor(i, 0x5bd1e995)
		buffer.writeu32(b, (i % 15) * 4, v)
		s += math.floor(buffer.readu32(b, (i % 15) * 4) / 3) + bit32.band(v, 7) + #string.char(65)
	end
	return s
end
return M
