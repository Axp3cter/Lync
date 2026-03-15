--!strict
--!optimize 2
-- Definitions.luau — Packet definitions and test data for benchmarking.

local Lync = require(script.Parent.Parent)

-- Definitions ------------------------------------------------------------

local Definitions = {}

Definitions.Ready = Lync.definePacket("BenchReady", {
    value = Lync.bool,
})

Definitions.Booleans = Lync.definePacket("BenchBool", {
    value = Lync.bool,
})

Definitions.Entities = Lync.definePacket("BenchEntity", {
    value = Lync.struct({
        position = Lync.vec3,
        velocity = Lync.vec3,
        health   = Lync.f32,
        shield   = Lync.f32,
        alive    = Lync.bool,
        team     = Lync.u8,
    }),
})

-- Data -------------------------------------------------------------------

Definitions.BOOL_DATA = true

Definitions.ENTITY_DATA = {
    position = Vector3.new(100.5, 50.25, -200.75),
    velocity = Vector3.new(10.1, 0, -5.3),
    health   = 87.5,
    shield   = 42.0,
    alive    = true,
    team     = 2,
}

return table.freeze(Definitions)
