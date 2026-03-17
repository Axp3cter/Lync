--!strict
--!optimize 2
-- Packet and data definitions for benchmarks.

local Lync = require (script.Parent.Parent)

-- Packets -------------------------------------------------------------

local Scenarios = {}

Scenarios.Ready = Lync.definePacket ("BenchReady", {
    value = Lync.bool,
})

-- Lync ----------------------------------------------------------------

Scenarios.Booleans = Lync.definePacket ("BenchBool", {
    value = Lync.bool,
})

Scenarios.Entities = Lync.definePacket ("BenchEntity", {
    value = Lync.struct ({
        position = Lync.vec3,
        velocity = Lync.vec3,
        health = Lync.f32,
        shield = Lync.f32,
        alive = Lync.bool,
        team = Lync.u8,
    }),
})

-- Blink-compatible -------------------------------------------------------

Scenarios.BlinkEntities = Lync.definePacket ("BlinkEntities", {
    value = Lync.array (Lync.struct ({
        id = Lync.u8,
        x = Lync.u8,
        y = Lync.u8,
        z = Lync.u8,
        orientation = Lync.u8,
        animation = Lync.u8,
    })),
})

Scenarios.BlinkBooleans = Lync.definePacket ("BlinkBooleans", {
    value = Lync.array (Lync.bool),
})

-- Static data ------------------------------------------------------------

Scenarios.STATIC_ENTITY = {
    position = Vector3.new (100.5, 50.25, -200.75),
    velocity = Vector3.new (10.1, 0, -5.3),
    health = 87.5,
    shield = 42.0,
    alive = true,
    team = 2,
}

-- Blink static data ------------------------------------------------------
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
    Scenarios.BLINK_ENTITIES = table.freeze (array)
end

Scenarios.BLINK_BOOLEANS = table.freeze (table.create (1000, true))

Scenarios.allPackets = {
    Booleans = Scenarios.Booleans,
    Entities = Scenarios.Entities,
    BlinkEntities = Scenarios.BlinkEntities,
    BlinkBooleans = Scenarios.BlinkBooleans,
}
return table.freeze (Scenarios)
