local function show(name, f)
  local s, l, n, a1, a2 = debug.info(f, "s"), debug.info(f, "l"), debug.info(f, "n"), debug.info(f, "a")
  print(name, s, l, n, a1, a2)
end
show("print", print)
show("string.byte", string.byte)
show("buffer.readu8", buffer.readu8)
local function wrap(...) return print(...) end
show("luawrap", wrap)
show("pcall", pcall)
-- error message fingerprint from a C function and from a Lua wrapper
print(pcall(string.rep))
print(pcall(function() return string.rep() end))
local hooked = function(...) return string.rep(...) end
print(pcall(hooked))
-- traceback in an xpcall handler from a C function
xpcall(function() buffer.readu8(nil, 0) end, function(e) print("E:", e); print(debug.traceback()) ; for i=1,6 do print(i, debug.info(i,"sln")) end end)
-- stack depth: C stack limit
local depth = 0
local function rec() depth += 1; return pcall(rec) end
rec(); print("pcall nesting depth reached", depth)
local d2=0
local function rec2() d2+=1; rec2() end
print(pcall(rec2), d2)
print("isfrozen string lib", table.isfrozen(string), table.isfrozen(buffer), table.isfrozen(_G))
