--!strict
--!optimize 2
-- Packet definitions and static data for benchmarks.

local Lync = require(script.Parent.Parent)

-- Packets -------------------------------------------------------------

local Scenarios = {}

Scenarios.Ready = Lync.packet("BenchReady", Lync.bool)
Scenarios.ServerReady = Lync.packet("BenchServerReady", Lync.bool)

-- Primitives
Scenarios.BoolPacket = Lync.packet("BenchBool", Lync.bool)
Scenarios.U8Packet = Lync.packet("BenchU8", Lync.int(0, 255))
Scenarios.U16Packet = Lync.packet("BenchU16", Lync.int(0, 65535))
Scenarios.F32Packet = Lync.packet("BenchF32", Lync.f32)
Scenarios.F64Packet = Lync.packet("BenchF64", Lync.f64)
Scenarios.StringPacket = Lync.packet("BenchString", Lync.string)
Scenarios.Vec3Packet = Lync.packet("BenchVec3", Lync.vec3)
Scenarios.CFramePacket = Lync.packet("BenchCFrame", Lync.cframe)
Scenarios.CFrameCPacket = Lync.packet("BenchCFrameC", Lync.cframe())

-- Structs
local entityCodec = Lync.struct({
    position = Lync.vec3,
    velocity = Lync.vec3,
    health = Lync.f32,
    shield = Lync.f32,
    alive = Lync.bool,
    team = Lync.int(0, 255),
})

local entityCompactCodec = Lync.struct({
    position = Lync.vec3(-500, 500, 0.1),
    velocity = Lync.vec3(-50, 50, 0.5),
    health = Lync.int(0, 255),
    shield = Lync.int(0, 255),
    alive = Lync.bool,
    team = Lync.int(0, 7),
})

local deltaEntityCodec = Lync.deltaStruct({
    position = Lync.vec3,
    velocity = Lync.vec3,
    health = Lync.f32,
    shield = Lync.f32,
    alive = Lync.bool,
    team = Lync.int(0, 255),
})

Scenarios.EntityPacket = Lync.packet("BenchEntity", entityCodec)
Scenarios.EntityCompactPacket = Lync.packet("BenchEntityCompact", entityCompactCodec)
Scenarios.DeltaEntityPacket = Lync.packet("BenchDeltaEntity", deltaEntityCodec)

-- Arrays (Blink-style)
local blinkEntityCodec = Lync.struct({
    id = Lync.int(0, 255),
    x = Lync.int(0, 255),
    y = Lync.int(0, 255),
    z = Lync.int(0, 255),
    orientation = Lync.int(0, 255),
    animation = Lync.int(0, 255),
})

Scenarios.BlinkEntitiesPacket = Lync.packet("BenchBlinkEntities", Lync.array(blinkEntityCodec))
Scenarios.BlinkBoolsPacket = Lync.packet("BenchBlinkBools", Lync.array(Lync.bool))

-- Bitfield
local flagsCodec = Lync.bitfield({
    alive = { type = "bool" },
    grounded = { type = "bool" },
    sprinting = { type = "bool" },
    crouching = { type = "bool" },
    team = { type = "uint", width = 3 },
    health = { type = "uint", width = 7 },
})
Scenarios.FlagsPacket = Lync.packet("BenchFlags", flagsCodec)

-- Codecs (for isolated throughput tests)
Scenarios.entityCodec = entityCodec
Scenarios.entityCompactCodec = entityCompactCodec
Scenarios.deltaEntityCodec = deltaEntityCodec
Scenarios.blinkEntityCodec = blinkEntityCodec
Scenarios.flagsCodec = flagsCodec

-- Static data ---------------------------------------------------------

Scenarios.ENTITY = table.freeze({
    position = Vector3.new(100.5, 50.25, -200.75),
    velocity = Vector3.new(10.1, 0, -5.3),
    health = 87.5,
    shield = 42.0,
    alive = true,
    team = 2,
})

Scenarios.ENTITY_COMPACT = table.freeze({
    position = Vector3.new(100.5, 50.25, -200.75),
    velocity = Vector3.new(10.1, 0, -5.3),
    health = 88,
    shield = 42,
    alive = true,
    team = 2,
})

Scenarios.FLAGS = table.freeze({
    alive = true,
    grounded = true,
    sprinting = false,
    crouching = false,
    team = 3,
    health = 100,
})

do
    math.randomseed(0)
    local arr = table.create(100)
    for i = 1, 100 do
        arr[i] = {
            id = math.random(1, 255),
            x = math.random(1, 255),
            y = math.random(1, 255),
            z = math.random(1, 255),
            orientation = math.random(1, 255),
            animation = math.random(1, 255),
        }
    end
    Scenarios.BLINK_ENTITIES = table.freeze(arr)
end

Scenarios.BLINK_BOOLS = table.freeze(table.create(1000, true))

-- Collect all network-testable packets
Scenarios.allPackets = table.freeze({
    BoolPacket = Scenarios.BoolPacket,
    U8Packet = Scenarios.U8Packet,
    U16Packet = Scenarios.U16Packet,
    F32Packet = Scenarios.F32Packet,
    F64Packet = Scenarios.F64Packet,
    StringPacket = Scenarios.StringPacket,
    Vec3Packet = Scenarios.Vec3Packet,
    CFramePacket = Scenarios.CFramePacket,
    CFrameCPacket = Scenarios.CFrameCPacket,
    EntityPacket = Scenarios.EntityPacket,
    EntityCompactPacket = Scenarios.EntityCompactPacket,
    DeltaEntityPacket = Scenarios.DeltaEntityPacket,
    BlinkEntitiesPacket = Scenarios.BlinkEntitiesPacket,
    BlinkBoolsPacket = Scenarios.BlinkBoolsPacket,
    FlagsPacket = Scenarios.FlagsPacket,
})

return table.freeze(Scenarios)
