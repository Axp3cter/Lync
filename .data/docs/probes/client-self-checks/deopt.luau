--!strict
-- What one getfenv(level) call made by another module does to the calling game script's speed.
-- This chunk never names getfenv, so the compiler keeps its imports and fast calls; the flag that
-- getfenv clears is checked at run time (lvmexecute.cpp: `cl->env->safeenv`).
local B = require("./bench")
local readEnv = require("./deoptmod")

local N = 200_000
local buf = buffer.create(64)
local sink = 0

local function work()
	-- a typical encoder step: builtin fast calls and an imported global
	local x = bit32.bxor(sink, 0x5bd1e995)
	x = bit32.lrotate(x, 13)
	buffer.writeu32(buf, 0, x)
	sink = buffer.readu32(buf, 0) + math.floor(1.5)
end

B.report("encoder step, safe environment", N, work)
B.report("encoder step, safe environment (again)", N, work)
readEnv() -- clears this chunk's environment's safe flag, for the rest of its life
B.report("encoder step, after getfenv(2) from a module", N, work)
B.report("encoder step, after (again)", N, work)
B.report("the getfenv(2) call itself", N, function() readEnv() end)
