--!strict
-- R1: what a listener sees below itself on its own thread, and the cost of looking (CLI stand-ins only; the
-- engine's own delivery and any executor's signal firing cannot run here).
-- Cases: the listener as the first function of a fresh coroutine (how a resumed handler starts); called by a
-- C function (pcall stands in for any C-side synchronous call); called by a Lua function.
local H = require("../security-costs/harness")

local seen: { [string]: string } = {}
local function listener(tag: string)
	local s2 = debug.info(2, "s")
	local f2 = debug.info(2, "f")
	seen[tag] = string.format("debug.info(2,'s') = %s; debug.info(2,'f') is %s", tostring(s2), typeof(f2))
end

-- Called through a table returned by a function, so -O2 can neither fold the field nor inline the callee (a
-- literal local table would fold, and -O2 then inlines: the Lua-caller case read nil until this was done). An
-- engine-connected function is never inlined either: it escapes through Connect.
local function box<F>(f: F): { f: F }
	return { f = f }
end
local api = box(listener)
coroutine.resume(coroutine.create(listener), "fresh coroutine, listener first")
coroutine.wrap(listener)("coroutine.wrap, listener first")
coroutine.resume(coroutine.create(function() pcall(listener, "C caller (pcall) in a coroutine") end))
local function luaCaller() api.f("Lua caller") end
local callers = box(luaCaller)
callers.f()
for _, k in { "fresh coroutine, listener first", "coroutine.wrap, listener first", "C caller (pcall) in a coroutine", "Lua caller" } do
	print(string.format("%-34s %s", k, seen[k]))
end

-- Cost per check: the check as a listener would run it once per frame.
local probe = box(function(): number
	return if debug.info(2, "f") == nil then 0 else 1
end)
H.compare("origin check per frame", 200000, {
	{ name = "no check (baseline)", fn = function(n)
		local acc = 0
		for _ = 1, n do acc += 1 end
		return acc
	end },
	{ name = "call through a field, no check", fn = function(n)
		local acc = 0
		local nop = box(function(): number return 0 end)
		for _ = 1, n do acc += nop.f() end
		return acc
	end },
	{ name = "debug.info(2, 'f') == nil", fn = function(n)
		local acc = 0
		for _ = 1, n do acc += probe.f() end
		return acc
	end },
})
