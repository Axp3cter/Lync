--!strict
--!optimize 2
-- Packet definitions, bench config, and case lists shared by both runners.

local Lync = require(script.Parent.Parent)

-- Constants --------------------------------------------------------------

local BLINK_ENTITY_COUNT = 100
local BLINK_BOOL_COUNT = 1000

-- Schema fragments -------------------------------------------------------

local entityFields = {
    position = Lync.vec3,
    velocity = Lync.vec3,
    health = Lync.f32,
    shield = Lync.f32,
    alive = Lync.bool,
    team = Lync.int(0, 255),
}

local entityCompactFields = {
    position = Lync.vec3(-500, 500, 0.1),
    velocity = Lync.vec3(-50, 50, 0.5),
    health = Lync.int(0, 255),
    shield = Lync.int(0, 255),
    alive = Lync.bool,
    team = Lync.int(0, 7),
}

local blinkEntityFields = {
    id = Lync.int(0, 255),
    x = Lync.int(0, 255),
    y = Lync.int(0, 255),
    z = Lync.int(0, 255),
    orientation = Lync.int(0, 255),
    animation = Lync.int(0, 255),
}

local flagFields = {
    alive = { type = "bool" },
    grounded = { type = "bool" },
    sprinting = { type = "bool" },
    crouching = { type = "bool" },
    team = { type = "uint", width = 3 },
    health = { type = "uint", width = 7 },
}

-- Codec instances --------------------------------------------------------

local entityCodec = Lync.struct(entityFields)
local entityCompactCodec = Lync.struct(entityCompactFields)
local entityDeltaCodec = Lync.deltaStruct(entityFields)
local entityCompactDelta = Lync.deltaStruct(entityCompactFields)
local blinkEntityCodec = Lync.struct(blinkEntityFields)
local flagsCodec = Lync.bitfield(flagFields)

-- Static data ------------------------------------------------------------

local CFRAME_VALUE = CFrame.new(10, 20, 30) * CFrame.Angles(1, 0.5, 0.3)

local ENTITY = table.freeze({
    position = Vector3.new(100.5, 50.25, -200.75),
    velocity = Vector3.new(10.1, 0, -5.3),
    health = 87.5,
    shield = 42.0,
    alive = true,
    team = 2,
})

local ENTITY_COMPACT = table.freeze({
    position = Vector3.new(100.5, 50.25, -200.75),
    velocity = Vector3.new(10.1, 0, -5.3),
    health = 88,
    shield = 42,
    alive = true,
    team = 2,
})

local FLAGS = table.freeze({
    alive = true,
    grounded = true,
    sprinting = false,
    crouching = false,
    team = 3,
    health = 100,
})

local rng = Random.new(0)
local blinkEntities = table.create(BLINK_ENTITY_COUNT)
for i = 1, BLINK_ENTITY_COUNT do
    blinkEntities[i] = {
        id = rng:NextInteger(1, 255),
        x = rng:NextInteger(1, 255),
        y = rng:NextInteger(1, 255),
        z = rng:NextInteger(1, 255),
        orientation = rng:NextInteger(1, 255),
        animation = rng:NextInteger(1, 255),
    }
end
local BLINK_ENTITIES = table.freeze(blinkEntities)
local BLINK_BOOLS = table.freeze(table.create(BLINK_BOOL_COUNT, true))

-- Handshake (4-step: cpu done -> ready -> swap -> done) ------------------

local handshake = table.freeze({
    ServerCpuDone = Lync.packet("BenchServerCpuDone", Lync.bool),
    ClientReady = Lync.packet("BenchClientReady", Lync.bool),
    ServerSwap = Lync.packet("BenchServerSwap", Lync.bool),
    ClientDone = Lync.packet("BenchClientDone", Lync.bool),
})

-- Network test packets ---------------------------------------------------

local packets = table.freeze({
    Bool = Lync.packet("BenchBool", Lync.bool),
    U8 = Lync.packet("BenchU8", Lync.int(0, 255)),
    U16 = Lync.packet("BenchU16", Lync.int(0, 65535)),
    F32 = Lync.packet("BenchF32", Lync.f32),
    F64 = Lync.packet("BenchF64", Lync.f64),
    String = Lync.packet("BenchString", Lync.string),
    Vec3 = Lync.packet("BenchVec3", Lync.vec3),
    CFrame = Lync.packet("BenchCFrame", Lync.cframe),
    CFrameC = Lync.packet("BenchCFrameC", Lync.cframe()),
    Entity = Lync.packet("BenchEntity", entityCodec),
    EntityCompact = Lync.packet("BenchEntityCompact", entityCompactCodec),
    BlinkEntities = Lync.packet("BenchBlinkEntities", Lync.array(blinkEntityCodec)),
    BlinkBools = Lync.packet("BenchBlinkBools", Lync.array(Lync.bool)),
    Flags = Lync.packet("BenchFlags", flagsCodec),
})

-- Bench config (shared by both runners) ----------------------------------

local bench = table.freeze({
    channelMaxSize = 1048576,
    netDuration = 8,
    compDuration = 10,
    compFps = 60,
    smallFires = 1000, -- per frame for primitives, vec3, etc.
    largeFires = 100, -- per frame for big array payloads
    compFires = 1000, -- per frame for cross-library comparison
})

-- Network throughput cases (shared) --------------------------------------

local netCases = table.freeze({
    {
        label = "booleans",
        fires = bench.smallFires,
        packet = packets.Bool,
        data = true,
    },
    {
        label = "u8",
        fires = bench.smallFires,
        packet = packets.U8,
        data = 42,
    },
    {
        label = "u16",
        fires = bench.smallFires,
        packet = packets.U16,
        data = 30000,
    },
    {
        label = "f32",
        fires = bench.smallFires,
        packet = packets.F32,
        data = 3.14,
    },
    {
        label = "f64",
        fires = bench.smallFires,
        packet = packets.F64,
        data = math.pi,
    },
    {
        label = "vec3",
        fires = bench.smallFires,
        packet = packets.Vec3,
        data = Vector3.new(1, 2, 3),
    },
    {
        label = "string",
        fires = bench.smallFires,
        packet = packets.String,
        data = "hello world",
    },
    {
        label = "entity struct",
        fires = bench.smallFires,
        packet = packets.Entity,
        data = ENTITY,
    },
    {
        label = "entity compact",
        fires = bench.smallFires,
        packet = packets.EntityCompact,
        data = ENTITY_COMPACT,
    },
    {
        label = "100x entities",
        fires = bench.largeFires,
        packet = packets.BlinkEntities,
        data = BLINK_ENTITIES,
    },
    {
        label = "1000x bools",
        fires = bench.largeFires,
        packet = packets.BlinkBools,
        data = BLINK_BOOLS,
    },
    {
        label = "bitfield flags",
        fires = bench.smallFires,
        packet = packets.Flags,
        data = FLAGS,
    },
    {
        label = "cframe lossless",
        fires = bench.smallFires,
        packet = packets.CFrame,
        data = CFRAME_VALUE,
    },
    {
        label = "cframe compressed",
        fires = bench.smallFires,
        packet = packets.CFrameC,
        data = CFRAME_VALUE,
    },
})

-- Cross-library comparison cases (shared) --------------------------------

local compCases = table.freeze({
    {
        label = "100x entities",
        title = "Entities: 100x struct(6x u8)",
        packet = packets.BlinkEntities,
        data = BLINK_ENTITIES,
    },
    {
        label = "1000x bools",
        title = "Booleans: 1000x bool",
        packet = packets.BlinkBools,
        data = BLINK_BOOLS,
    },
})

-- Public -----------------------------------------------------------------

return table.freeze({
    -- Codecs (for isolated CPU tests)
    entityCodec = entityCodec,
    entityCompactCodec = entityCompactCodec,
    entityDeltaCodec = entityDeltaCodec,
    entityCompactDelta = entityCompactDelta,
    blinkEntityCodec = blinkEntityCodec,
    flagsCodec = flagsCodec,

    -- Packets and handshake
    handshake = handshake,
    packets = packets,

    -- Bench config and case lists
    bench = bench,
    netCases = netCases,
    compCases = compCases,

    -- Static data
    CFRAME_VALUE = CFRAME_VALUE,
    ENTITY = ENTITY,
    ENTITY_COMPACT = ENTITY_COMPACT,
    FLAGS = FLAGS,
    BLINK_ENTITIES = BLINK_ENTITIES,
    BLINK_BOOLS = BLINK_BOOLS,
})
