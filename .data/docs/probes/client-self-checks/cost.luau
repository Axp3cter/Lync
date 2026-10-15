--!strict
-- Per-call costs of the client-side self-observation APIs, interpreted (no --codegen).
-- Run from this directory: luau -O2 cost.luau (and -O1, Studio's level).
local B = require("./bench")
local W = require("./walkstub")

local N = 200_000
local sink: any = nil

print("== debug.info")
B.report("debug.info(1, 's')", N, function() sink = debug.info(1, "s") end)
B.report("debug.info(2, 's')", N, function() sink = debug.info(2, "s") end)
B.report("debug.info(2, 'sl')", N, function() sink = debug.info(2, "sl") end)
B.report("debug.info(2, 'slnf')", N, function() sink = debug.info(2, "slnf") end)
B.report("debug.info(2, 'f')", N, function() sink = debug.info(2, "f") end)
B.report("debug.info(fn, 's')", N, function() sink = debug.info(W.walk, "s") end)
B.report("walk, 1 Lync frame", N, function() sink = W.d1() end)
B.report("walk, 3 Lync frames", N, function() sink = W.d3() end)
B.report("walk, 5 Lync frames", N, function() sink = W.d5() end)
B.report("walk (1 frame) + listed-source lookup", N, function() sink = W.checked() end)

print("== debug.traceback")
B.report("debug.traceback() at depth 3", 50_000, function() sink = debug.traceback() end)

print("== clocks")
B.report("os.clock()", N, function() sink = os.clock() end)
do
	-- smallest nonzero step between consecutive reads
	local least = math.huge
	local last = os.clock()
	for _ = 1, 1_000_000 do
		local now = os.clock()
		local d = now - last
		if d > 0 and d < least then
			least = d
		end
		last = now
	end
	print(string.format("%-44s %9.1f ns", "os.clock() smallest nonzero step", least * 1e9))
end

print("== pcall")
local function ok() end
local function luaError() error("lacking capability", 0) end
local function cError() string.rep() end
B.report("pcall, callee returns", N, function() sink = pcall(ok) end)
B.report("pcall, Lua error(string, 0)", 50_000, function() sink = pcall(luaError) end)
B.report("pcall, C argument error", 50_000, function() sink = pcall(cError :: any) end)

print("== U1: method dispatch on a userdata (Lua __namecall, C target)")
local proxy = newproxy(true)
local mt = getmetatable(proxy)
mt.__index = function(_self: any, _key: string): any
	return type
end
mt.__namecall = type -- a C function standing in for the engine's member dispatcher
local frame = buffer.create(64)
local captured = (proxy :: any).FireServer -- captured once, as U1 proposes
B.report("proxy:FireServer(frame) (NAMECALL)", N, function() sink = (proxy :: any):FireServer(frame) end)
B.report("proxy.FireServer(proxy, frame) (index each call)", N, function() sink = (proxy :: any).FireServer(proxy, frame) end)
B.report("captured(proxy, frame) (U1)", N, function() sink = captured(proxy, frame) end)

local _ = sink
