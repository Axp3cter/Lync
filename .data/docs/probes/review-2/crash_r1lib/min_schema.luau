--!strict
-- review-2: the same one-typo schema against review-1's draft-1 stand-in library
local Lync = require("./lync")
local t = Lync.types
return Lync.schema("arena", {
	x = Lync.event({ from = "client", data = t.strng(40) }),
})
