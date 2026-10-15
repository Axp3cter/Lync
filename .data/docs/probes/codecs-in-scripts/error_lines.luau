-- Which line a refusal reports for three woven forms, at -O1 (Studio) and -O2 (live). fail() walks to the first
-- frame that is not a woven helper (name prefix __lync). Run: luau -O1 error_lines.luau; luau -O2 error_lines.luau
local RT = { fail = nil :: any }
RT.fail = function() -- walk: first frame whose function is not a woven helper and not Lync
	for level = 2, 6 do
		local s, l, n = debug.info(level, "sln")
		if s ~= "[C]" and not (n and string.sub(n, 1, 6) == "__lync") then error("at line " .. l, 0) end
	end
end
local fail = RT.fail
local function __lync_s(a) if a > 9 then fail() end end
local H = {} function H.__lync_s(a) if a > 9 then fail() end end
print(pcall(function() __lync_s(10) end)) -- line 11: helper (local function)
print(pcall(function() H.__lync_s(10) end)) -- line 12: helper in a table
print(pcall(function() do local a = 10 if a > 9 then fail() end end end)) -- line 13: inline
