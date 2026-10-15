local top = debug.info(1, "s")
local function f() end
print(top == debug.info(f, "s"), top, debug.info(f, "l"))
