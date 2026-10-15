--!strict
-- Where `error` puts its position: levels, inlining at -O2, tables, and a debug.info walk.
-- Run at -O1 and -O2:  luau -O1 levels.luau ; luau -O2 levels.luau

local Lib = {}

-- A private helper raising at level 2 (inlinable at -O2).
local function check(x: number)
	if x ~= 1 then
		error("[Lync] helper level 2", 2)
	end
end

-- A public function stored on the module table after creation: never inlined.
function Lib.viaHelper(x: number)
	check(x)
end

function Lib.direct(x: number)
	if x ~= 1 then
		error("[Lync] direct level 2", 2)
	end
end

-- The walk: the first frame whose source is not this chunk.
local OWN = debug.info(1, "s")
local function raiseAtCaller(message: string): never
	local level = 2
	while true do
		local source, line = debug.info(level, "sl")
		if source == nil then
			error(message, 0)
		end
		if source ~= OWN and line ~= nil and line > 0 then
			error(`{source}:{line}: {message}`, 0)
		end
		level += 1
	end
end
function Lib.walked(x: number)
	if x ~= 1 then
		raiseAtCaller("[Lync] walked")
	end
end

-- A "user" chunk is simulated with loadstring so its source differs from Lib's.
local userSource = [[
local Lib = ...
local results = {}
local function try(name, f)
	local ok, e = pcall(f)
	table.insert(results, name .. " -> " .. tostring(e))
end
try("direct", function() Lib.direct(2) end)          -- line 7
try("viaHelper", function() Lib.viaHelper(2) end)    -- line 8
try("walked", function() Lib.walked(2) end)          -- line 9
try("level0", function() error("[Lync] level 0", 0) end)
try("table", function() error({ code = "LYNC1001" }, 2) end)
try("tableTostring", function()
	error(setmetatable({ code = "LYNC1001" }, { __tostring = function() return "[Lync] LYNC1001 tostring" end }), 2)
end)
try("pcallDirect", function() return select(2, pcall(Lib.direct, 2)) end)
try("pcallWalked", function() return select(2, pcall(Lib.walked, 2)) end)
return results
]]
-- note: pcallDirect/pcallWalked report the value pcall returned; the outer try prints it

local chunk = assert(loadstring(userSource, "=UserScript"))
for _, line in chunk(Lib) do
	print(line)
end

-- What pcall hands back when a table is thrown, and what tostring/traceback make of it.
local ok, value = pcall(function()
	error({ code = "LYNC1001", facts = { at = "x" } })
end)
print("table thrown:", ok, typeof(value), (value :: any).code)
print("traceback(table):", pcall(debug.traceback, value :: any))
print("xpcall(f, debug.traceback) on table:", xpcall(function() error({ code = "LYNC1003" }) end, debug.traceback))

-- xpcall handler sees the raw value
xpcall(function()
	error({ code = "LYNC1002" })
end, function(e)
	print("xpcall handler got:", typeof(e), e.code)
	return e
end)

-- Uncaught error in a coroutine: resume returns false and the value; traceback of the dead thread
local co = coroutine.create(function()
	local function deep()
		error("[Lync] in coroutine", 1)
	end
	deep()
end)
local okCo, errCo = coroutine.resume(co)
print("coroutine:", okCo, errCo)
print("traceback(co):", (string.gsub(debug.traceback(co), "\n", " | ")))
