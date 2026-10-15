--!strict
-- Claim 11(f): environment checks were refused partly because "getfenv forms deoptimise every script"
-- (v5-changes.md:101; client-security.md §2.2: magnitude unmeasured; R9, R18). Measures the same fast-call loop
-- (bit32 and buffer builtins, a math.floor, a global table read) in a module whose environment is safe (baseline)
-- and in one whose environment getfenv() has marked unsafe (calling getfenv(1) clears the safe-env flag,
-- VM/src/lbaselib.cpp luaB_getfenv). The second module is loaded from a separate chunk so only it is affected.
-- Run: luau -O2 getfenv_deopt.luau ; luau -O2 --codegen getfenv_deopt.luau
local H = require("./harness")
local safe = require("./getfenv_deopt_safe")
local unsafe = require("./getfenv_deopt_unsafe")
assert(safe.work(1000) == unsafe.work(1000))
H.compare("fast-call loop body (per iteration)", 2000000, {
	{ name = "safe environment", fn = safe.work },
	{ name = "after getfenv(1) in the module", fn = unsafe.work },
})
print("sink", H.sink)
