-- Does the common idiom xpcall(f, debug.traceback) survive a table error that has __tostring
-- (the shape LogService:Error is documented to throw)?
local obj = setmetatable({ message = "Failed: timeout", template = "Failed: {reason}" }, {
	__tostring = function(self) return self.message end,
})
print("xpcall(f, debug.traceback), table with __tostring:", xpcall(function() error(obj) end, debug.traceback))
print("pcall then tostring:", (function() local ok, e = pcall(error, obj) return ok, tostring(e) end)())
print("string concat in handler:", xpcall(function() error(obj) end, function(e) return "caught: " .. tostring(e) end))
