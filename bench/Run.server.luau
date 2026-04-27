--!strict
--!optimize 2
-- Server-side benchmark runner. CPU + s2c throughput, then yields to
-- the client for c2s throughput.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LyncFolder = ReplicatedStorage:WaitForChild("Lync")
local Channel = require(LyncFolder.internal.Channel)
local Harness = require(LyncFolder.bench.Harness)
local Lync = require(LyncFolder)
local Scenarios = require(LyncFolder.bench.Scenarios)

-- Constants --------------------------------------------------------------

local bench = Scenarios.bench

-- Reference wire sizes for naive type-as-byte serializers (Blink/Zap/etc).
local OTHER_TOOLS_ENTITY_BYTES = 602 -- 100 entities * 6B + ~2B varint length
local OTHER_TOOLS_BOOL_BYTES = 1002 -- 1000 bools * 1B + ~2B varint length

local CFRAME_VALUE = Scenarios.CFRAME_VALUE

Lync.configure({ channelMaxSize = bench.channelMaxSize, stats = true })
Lync.start()

-- Wire sizes -------------------------------------------------------------

Harness.header("Wire Sizes")

Harness.section("Primitives")
local primitiveSizeCases = {
    { "bool", Lync.bool, true },
    { "u8", Lync.int(0, 255), 42 },
    { "u16", Lync.int(0, 65535), 1000 },
    { "u32", Lync.int(0, 1000000), 500000 },
    { "i8", Lync.int(-128, 127), -50 },
    { "i16", Lync.int(-32768, 32767), -1000 },
    { "i32", Lync.int(-2147483648, 2147483647), -100000 },
    { "f16", Lync.f16, 42.5 },
    { "f32", Lync.f32, 3.14 },
    { "f64", Lync.f64, math.pi },
    { "nothing", Lync.nothing, nil },
}
for _, case in primitiveSizeCases do
    Harness.benchWireSize(case[1], case[2], case[3])
end
Harness.sectionEnd()

Harness.section("Strings")
local stringSizeCases = {
    { "empty", "" },
    { "5 chars", "hello" },
    { "100 chars", string.rep("x", 100) },
    { "191 chars (max inline)", string.rep("x", 191) },
    { "192 chars (varint)", string.rep("x", 192) },
    { "1000 chars", string.rep("x", 1000) },
}
for _, case in stringSizeCases do
    Harness.benchWireSize(case[1], Lync.string, case[2])
end
Harness.sectionEnd()

Harness.section("Vectors & Spatial")
Harness.benchWireSize("vec2 (lossless)", Lync.vec2, Vector2.new(1, 2))
Harness.benchWireSize("vec2 (u8 quantized)", Lync.vec2(0, 100, 1), Vector2.new(50, 75))
Harness.benchWireSize("vec3 (lossless)", Lync.vec3, Vector3.new(1, 2, 3))
Harness.benchWireSize("vec3 (u8 quantized)", Lync.vec3(0, 100, 1), Vector3.new(25, 50, 75))
Harness.benchWireSize("vec3 (u16 quantized)", Lync.vec3(-1000, 1000, 0.1), Vector3.zero)
Harness.benchWireSize("cframe (lossless 24B)", Lync.cframe, CFRAME_VALUE)
Harness.benchWireSize("cframe (compressed 16B)", Lync.cframe(), CFRAME_VALUE)
Harness.benchWireSize("color3", Lync.color3, Color3.fromRGB(255, 128, 0))
Harness.benchWireSize("ray", Lync.ray, Ray.new(Vector3.zero, Vector3.yAxis))
Harness.benchWireSize("udim", Lync.udim, UDim.new(0.5, 10))
Harness.benchWireSize("udim2", Lync.udim2, UDim2.new(UDim.new(0.5, 10), UDim.new(1, 20)))
Harness.benchWireSize("vec2int16", Lync.vec2int16, Vector2int16.new(100, -200))
Harness.benchWireSize("vec3int16", Lync.vec3int16, Vector3int16.new(100, -200, 300))
Harness.benchWireSize("numberRange", Lync.numberRange, NumberRange.new(0, 100))
Harness.benchWireSize("rect", Lync.rect, Rect.new(0, 0, 100, 50))
Harness.sectionEnd()

Harness.section("Structs")
Harness.benchWireSize("entity (lossless)", Scenarios.entityCodec, Scenarios.ENTITY)
Harness.benchWireSize("entity (compact)", Scenarios.entityCompactCodec, Scenarios.ENTITY_COMPACT)
Harness.benchWireSize("bitfield flags", Scenarios.flagsCodec, Scenarios.FLAGS)
Harness.sectionEnd()

Harness.section("Arrays & Collections")
Harness.benchWireSize(
    "100x entities",
    Lync.array(Scenarios.blinkEntityCodec),
    Scenarios.BLINK_ENTITIES
)
Harness.benchWireSize("1000x bools (bitpacked)", Lync.array(Lync.bool), Scenarios.BLINK_BOOLS)
Harness.benchWireSize("optional (present)", Lync.optional(Lync.int(0, 255)), 42)
Harness.benchWireSize("optional (absent)", Lync.optional(Lync.int(0, 255)), nil)
Harness.benchWireSize(
    "tuple(u8, vec3, bool)",
    Lync.tuple(Lync.int(0, 255), Lync.vec3, Lync.bool),
    { 7, Vector3.new(1, 2, 3), true }
)
Harness.benchWireSize(
    "string -> u8 map (3)",
    Lync.map(Lync.string, Lync.int(0, 255)),
    { hp = 100, mp = 50, stamina = 75 }
)
Harness.sectionEnd()

-- Codec round-trip throughput --------------------------------------------

Harness.header("Codec Throughput")

type RoundTripCase = { label: string, codec: any, value: any }

local function runRoundTrips(cases: { RoundTripCase }): ()
    for _, case in cases do
        Harness.benchRoundTrip(case.label, case.codec, case.value)
    end
end

Harness.section("Primitive encode/decode")
runRoundTrips({
    { label = "bool", codec = Lync.bool, value = true },
    { label = "u8", codec = Lync.int(0, 255), value = 42 },
    { label = "u16", codec = Lync.int(0, 65535), value = 30000 },
    { label = "i16", codec = Lync.int(-32768, 32767), value = -1000 },
    { label = "f16", codec = Lync.f16, value = 42.5 },
    { label = "f32", codec = Lync.f32, value = 3.14 },
    { label = "f64", codec = Lync.f64, value = math.pi },
})
Harness.sectionEnd()

Harness.section("Strings")
runRoundTrips({
    { label = "empty", codec = Lync.string, value = "" },
    { label = "10 chars", codec = Lync.string, value = "0123456789" },
    { label = "100 chars", codec = Lync.string, value = string.rep("x", 100) },
    { label = "1000 chars", codec = Lync.string, value = string.rep("x", 1000) },
})
Harness.sectionEnd()

Harness.section("Roblox types")
runRoundTrips({
    { label = "vec2", codec = Lync.vec2, value = Vector2.new(1.5, -3.25) },
    { label = "vec3", codec = Lync.vec3, value = Vector3.new(1, 2, 3) },
    { label = "vec3 quantized", codec = Lync.vec3(0, 100, 1), value = Vector3.new(25, 50, 75) },
    { label = "cframe lossless", codec = Lync.cframe, value = CFRAME_VALUE },
    { label = "cframe compressed", codec = Lync.cframe(), value = CFRAME_VALUE },
    {
        label = "color3",
        codec = Lync.color3,
        value = Color3.fromRGB(255, 128, 0),
    },
    {
        label = "udim2",
        codec = Lync.udim2,
        value = UDim2.new(UDim.new(0.5, 10), UDim.new(1, 20)),
    },
})
Harness.sectionEnd()

Harness.section("Composites")
runRoundTrips({
    {
        label = "entity struct",
        codec = Scenarios.entityCodec,
        value = Scenarios.ENTITY,
    },
    {
        label = "entity compact",
        codec = Scenarios.entityCompactCodec,
        value = Scenarios.ENTITY_COMPACT,
    },
    {
        label = "bitfield flags",
        codec = Scenarios.flagsCodec,
        value = Scenarios.FLAGS,
    },
    {
        label = "100x entities",
        codec = Lync.array(Scenarios.blinkEntityCodec),
        value = Scenarios.BLINK_ENTITIES,
    },
    {
        label = "1000x bools",
        codec = Lync.array(Lync.bool),
        value = Scenarios.BLINK_BOOLS,
    },
})
Harness.sectionEnd()

-- Delta savings ----------------------------------------------------------

Harness.header("Delta Savings")

Harness.section("deltaStruct")
Harness.benchDelta("entity delta", Scenarios.entityDeltaCodec, Scenarios.ENTITY)
Harness.benchDelta("compact delta", Scenarios.entityCompactDelta, Scenarios.ENTITY_COMPACT)
Harness.sectionEnd()

Harness.section("deltaArray / deltaMap")
Harness.benchDelta(
    "100x entities array",
    Lync.deltaArray(Scenarios.blinkEntityCodec),
    Scenarios.BLINK_ENTITIES
)
Harness.benchDelta("1000x bools array", Lync.deltaArray(Lync.bool), Scenarios.BLINK_BOOLS)
Harness.benchDelta(
    "string to u8 map",
    Lync.deltaMap(Lync.string, Lync.int(0, 255)),
    { hp = 100, mp = 50, stamina = 75 }
)
Harness.sectionEnd()

-- Batch framing overhead -------------------------------------------------

Harness.header("Batch Framing Overhead")

Harness.section("MSB single vs multi-item")
do
    local codec = Lync.int(0, 255)
    local reg: any = {
        id = 1,
        name = "__bench_msb",
        kind = 0,
        codec = codec,
        isUnreliable = false,
        headerSize = 1,
        timestampMode = Channel.TS_NONE,
        _openFn = Channel.resolveOpenFn(Channel.TS_NONE, "__bench_msb"),
    }

    local single = Channel.create()
    Channel.writeBatch(single, reg, 42)
    Harness.note(
        string.format("single-item header: %dB total (1B header + 1B payload)", single.cursor)
    )

    local many = Channel.create()
    for _ = 1, 10 do
        Channel.writeBatch(many, reg, 42)
    end
    local overhead = many.cursor - 10
    Harness.note(
        string.format(
            "10-item batch:      %dB total (%dB overhead, %.1fB/item)",
            many.cursor,
            overhead,
            overhead / 10
        )
    )
end
Harness.sectionEnd()

-- Encode-only throughput -------------------------------------------------

Harness.header("Encode Throughput")

local entityArrayCodec = Lync.array(Scenarios.blinkEntityCodec)
local boolArrayCodec = Lync.array(Lync.bool)
local cframeCompressed = Lync.cframe()

Harness.section("Isolated encode (write only)")
Harness.benchEncode("bool", function()
    local ch = Channel.create()
    Lync.bool.write(ch, true)
end)
Harness.benchEncode("entity struct", function()
    local ch = Channel.create()
    Scenarios.entityCodec.write(ch, Scenarios.ENTITY)
end)
Harness.benchEncode("100x entities", function()
    local ch = Channel.create()
    entityArrayCodec.write(ch, Scenarios.BLINK_ENTITIES)
end)
Harness.benchEncode("1000x bools", function()
    local ch = Channel.create()
    boolArrayCodec.write(ch, Scenarios.BLINK_BOOLS)
end)
Harness.benchEncode("cframe compressed", function()
    local ch = Channel.create()
    cframeCompressed.write(ch, CFRAME_VALUE)
end)
Harness.sectionEnd()

-- Network: requires a connected client -----------------------------------

local function getPlayer(): Player
    local players = Players:GetPlayers()
    return if #players > 0 then players[1] else Players.PlayerAdded:Wait()
end

local player = getPlayer()

Scenarios.handshake.ServerCpuDone:send(true, player)
Scenarios.handshake.ClientReady:wait()

Harness.header("Network Throughput (server -> client)")

Harness.section(string.format("%d fires/frame, %ds per case", bench.smallFires, bench.netDuration))
for _, case in Scenarios.netCases do
    local packet, data = case.packet, case.data
    Harness.benchNetwork(case.label, case.fires, bench.netDuration, function()
        packet:send(data, player)
    end)
end
Harness.sectionEnd()

-- Cross-library comparison (server -> client) ----------------------------

Harness.header("Cross-Library Comparison (server -> client)")

for _, case in Scenarios.compCases do
    Harness.section(
        string.format("%s, %d/frame, %ds", case.title, bench.compFires, bench.compDuration)
    )
    local packet, data = case.packet, case.data
    Harness.benchComparison(
        case.label,
        bench.compFires,
        bench.compDuration,
        bench.compFps,
        function()
            packet:send(data, player)
        end
    )
    Harness.sectionEnd()
end

Harness.section("Wire size vs other tools")
local entBytes = Harness.benchWireSize(
    "Lync: 100x entities",
    Lync.array(Scenarios.blinkEntityCodec),
    Scenarios.BLINK_ENTITIES
)
Harness.note(
    string.format(
        "Other tools: ~%dB    Difference: %+dB",
        OTHER_TOOLS_ENTITY_BYTES,
        entBytes - OTHER_TOOLS_ENTITY_BYTES
    )
)

local boolBytes = Harness.benchWireSize(
    "Lync: 1000x bools (bitpacked)",
    Lync.array(Lync.bool),
    Scenarios.BLINK_BOOLS
)
local boolDelta = if boolBytes < OTHER_TOOLS_BOOL_BYTES
    then string.format("%d%% smaller", math.floor((1 - boolBytes / OTHER_TOOLS_BOOL_BYTES) * 100))
    else "comparable"
Harness.note(
    string.format(
        "Other tools: ~%dB    Difference: %+dB (%s)",
        OTHER_TOOLS_BOOL_BYTES,
        boolBytes - OTHER_TOOLS_BOOL_BYTES,
        boolDelta
    )
)
Harness.sectionEnd()

-- Hand off to client for c2s tests ---------------------------------------

Scenarios.handshake.ServerSwap:send(true, player)
Scenarios.handshake.ClientDone:wait()

Harness.header("Bench Complete")
