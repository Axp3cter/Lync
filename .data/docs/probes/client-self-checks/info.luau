--!strict
-- Semantics of debug.info as Lync's client shard would use it on an unmodified client.
-- Run from this directory: luau -O1 info.luau, then luau -O2 info.luau.
local Stub = require("./lyncstub")

print("own source", Stub.own, "main source", (debug.info(1, "s")))

-- 1. a direct call from a game function
local function gameSend()
	return Stub.fire(1) -- line 10
end
print("direct", gameSend())

-- 2. a call through a local helper that -O2 may inline into its caller
local function helper(v)
	return Stub.fire(v) -- line 16
end
local function outer()
	local a, b, c = helper(2) -- line 19
	return a, b, c
end
print("via helper", outer())

-- 3. a multi-line call expression
local function multi()
	return Stub.fire(
		3
	) -- the call starts on line 26
end
print("multi-line", multi())

-- 4. the shard's fire passed to coroutine.wrap / task-style scheduling: no game frame on the stack
local co = coroutine.wrap(Stub.fire)
print("coroutine.wrap(fire)", co(4))

-- 5. a C function between game code and Lync (pcall)
print("via pcall", select(2, pcall(Stub.fire, 5)))

-- 6. a closure created at run time in game code
local made = (function()
	return function()
		return Stub.fire(6)
	end
end)()
print("closure", made())

-- 7. levels past the stack top, and option rules
print("level 99", debug.info(99, "s"))
print("C function", debug.info(print, "sln"))
print("arity vararg", debug.info(function(...) end, "a"))
print("bad option", pcall(debug.info, 1, "ss"))
print("bad option x", pcall(debug.info, 1, "x"))

-- 8. traceback text at this point
print("traceback:\n" .. debug.traceback("tb", 1))
