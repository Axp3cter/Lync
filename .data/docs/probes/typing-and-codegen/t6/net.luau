--!strict
local Lync = require("./lync")
return {
	hit = Lync.packet({ target = Lync.u8, note = Lync.str }),
	chat = Lync.packet(Lync.str),
}
