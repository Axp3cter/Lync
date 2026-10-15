--!strict
-- shared schema module (no annotations)
local Lync = require("./lync")

local Hit = { target = Lync.u8, pos = { x = Lync.f32, y = Lync.f32 }, crit = Lync.optional(Lync.bool) }
local Shot = Lync.tagged({ hit = { target = Lync.u8 }, miss = { reason = Lync.str } })

return {
	hitA = Lync.packetA(Hit),
	hitB = Lync.packetB(Hit),
	hitC = Lync.packetC(Lync.struct(Hit)),
	shotA = Lync.packetA(Shot),
	shotB = Lync.packetB(Shot),
	shotC = Lync.packetC(Shot),
	numB = Lync.packetB(Lync.u8),
	numC = Lync.packetC(Lync.u8),
	listB = Lync.packetB(Lync.array(Lync.str)),
	listC = Lync.packetC(Lync.array(Lync.str)),
}
