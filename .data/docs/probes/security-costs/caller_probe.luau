--!strict
-- Claim 7: "Caller probe on every call: <= 0.2 ms of client CPU per second at 60/s" (v5-integrity.md §4,
-- v5-changes.md:550). The identity probe is one failing pcall (a capability error on Roblox, not reproducible
-- in the CLI; stand-ins below), the source probe one debug.info read. Cases per probe:
--   pcall ok           : pcall of a function that returns (baseline)
--   error(s) level 1   : a Lua error with a constant string; the VM prefixes the position
--   error(s, 0)        : the same without the position prefix
--   error(table)       : a non-string error value (no string built)
--   C arg error        : pcall(buffer.readu8, nil, 0): an error raised by a C builtin, like an engine member
--   debug.info source  : debug.info(2, "s") from inside a callee, plus a cache lookup
--   random draw        : math.random() per fire (the oneIn draw)
-- Run: luau -O2 caller_probe.luau ; luau -O2 --codegen caller_probe.luau
local H = require("./harness")

local function ok(): number return 1 end
local function failLevel1() error("The current thread cannot access 'X' (lacking capability Plugin)") end
local function failLevel0() error("The current thread cannot access 'X' (lacking capability Plugin)", 0) end
local errTable = { code = 1 }
local function failTable() error(errTable) end
local cache: { [string]: boolean } = {}
local function sourceOf(): boolean?
	local s = debug.info(2, "s")
	return cache[s]
end

local N = 200000
local r = H.compare("one probe", N, {
	{ name = "pcall ok", fn = function(n)
		local s = 0
		for _ = 1, n do if pcall(ok) then s += 1 end end
		return s
	end },
	{ name = "failing pcall, error(s) level 1", fn = function(n)
		local s = 0
		for _ = 1, n do if not pcall(failLevel1) then s += 1 end end
		return s
	end },
	{ name = "failing pcall, error(s, 0)", fn = function(n)
		local s = 0
		for _ = 1, n do if not pcall(failLevel0) then s += 1 end end
		return s
	end },
	{ name = "failing pcall, error(table)", fn = function(n)
		local s = 0
		for _ = 1, n do if not pcall(failTable) then s += 1 end end
		return s
	end },
	{ name = "failing pcall, C arg error", fn = function(n)
		local s = 0
		for _ = 1, n do if not pcall(buffer.readu8, nil :: any, 0) then s += 1 end end
		return s
	end },
	{ name = "debug.info(2,'s') + cache", fn = function(n)
		local s = 0
		for _ = 1, n do if sourceOf() == nil then s += 1 end end
		return s
	end },
	{ name = "random draw per fire", fn = function(n)
		local s = 0
		for _ = 1, n do if math.random() < 1 then s += 1 end end
		return s
	end },
})
print("## per second at 60 probes (identity + source) and 60 draws")
for _, name in { "failing pcall, error(s) level 1", "failing pcall, error(s, 0)", "failing pcall, error(table)", "failing pcall, C arg error" } do
	local us = 60 * (r[name] + r["debug.info(2,'s') + cache"] + r["random draw per fire"]) / 1000
	print(string.format("%-34s %.1f us/s (%.3f ms/s)", name, us, us / 1000))
end
print("sink", H.sink)
