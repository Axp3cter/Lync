--!strict
--!optimize 2
-- Packet definitions for benchmarks.

local Lync = require (script.Parent.Parent)

-- Definitions ------------------------------------------------------------

local Definitions = {}

Definitions.Ready = Lync.definePacket ("BenchReady", {
    value = Lync.bool,
})

-- Lync-specific benchmarks -----------------------------------------------

Definitions.Booleans = Lync.definePacket ("BenchBool", {
    value = Lync.bool,
})

Definitions.Entities = Lync.definePacket ("BenchEntity", {
    value = Lync.struct ({
        position = Lync.vec3,
        velocity = Lync.vec3,
        health = Lync.f32,
        shield = Lync.f32,
        alive = Lync.bool,
        team = Lync.u8,
    }),
})

-- Blink-compatible benchmarks --------------------------------------------
-- Exact same data shapes as Blink's benchmark suite so results are
-- directly comparable. See: github.com/1Axen/blink/benchmark

Definitions.BlinkEntities = Lync.definePacket ("BlinkEntities", {
    value = Lync.array (Lync.struct ({
        id = Lync.u8,
        x = Lync.u8,
        y = Lync.u8,
        z = Lync.u8,
        orientation = Lync.u8,
        animation = Lync.u8,
    })),
})

Definitions.BlinkBooleans = Lync.definePacket ("BlinkBooleans", {
    value = Lync.array (Lync.bool),
})

-- Static data ------------------------------------------------------------

Definitions.STATIC_ENTITY = {
    position = Vector3.new (100.5, 50.25, -200.75),
    velocity = Vector3.new (10.1, 0, -5.3),
    health = 87.5,
    shield = 42.0,
    alive = true,
    team = 2,
}

-- Blink-compatible static data (same seed as Blink: math.randomseed(0))
do
    math.randomseed (0)
    local array = table.create (100)
    for i = 1, 100 do
        array[i] = {
            id = math.random (1, 255),
            x = math.random (1, 255),
            y = math.random (1, 255),
            z = math.random (1, 255),
            orientation = math.random (1, 255),
            animation = math.random (1, 255),
        }
    end
    Definitions.BLINK_ENTITIES = table.freeze (array)
end

Definitions.BLINK_BOOLEANS = table.freeze (table.create (1000, true))

return table.freeze (Definitions)
