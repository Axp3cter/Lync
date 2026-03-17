--!strict
--!optimize 2
local Lync = require (script.Parent.Parent)

local Scenarios = {}

Scenarios.Ready = Lync.definePacket ("IntReady", { value = Lync.bool })

Scenarios.SimpleU8 = Lync.definePacket ("IntSimpleU8", { value = Lync.u8 })

Scenarios.Struct = Lync.definePacket ("IntStruct", {
    value = Lync.struct ({ hp = Lync.u8, name = Lync.string, alive = Lync.bool }),
})

Scenarios.BigArray = Lync.definePacket ("IntBigArray", {
    value = Lync.array (Lync.u16),
})

Scenarios.Unreliable = Lync.definePacket ("IntUnrel", {
    value = Lync.vec3,
    unreliable = true,
})

Scenarios.Echo = Lync.defineQuery ("IntEcho", {
    request = Lync.string,
    response = Lync.string,
})

Scenarios.MathQuery = Lync.defineQuery ("IntMath", {
    request = Lync.struct ({ a = Lync.f32, b = Lync.f32 }),
    response = Lync.f32,
})

Scenarios.ClientToServer = Lync.definePacket ("IntC2S", { value = Lync.u8 })

return table.freeze (Scenarios)
