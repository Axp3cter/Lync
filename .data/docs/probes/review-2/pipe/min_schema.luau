--!strict
-- review-2: the one-typo schema used by min_server.luau (variants tried: request reply, event data, collection field)
-- review-2: minimal schema for the analyzer crash (last variant tried is left in place)
local Lync = require("./lync")
local t = Lync.types
return Lync.schema("arena", {
	x = Lync.event({ from = "client", data = { a = t.strng(40) } }),
})
