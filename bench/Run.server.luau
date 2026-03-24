--!strict
--!optimize 2
-- Server-side benchmark runner.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LyncFolder = ReplicatedStorage:WaitForChild("Lync")
local Lync = require(LyncFolder)
local benchFolder = LyncFolder:WaitForChild("bench")
local Channel = require(LyncFolder:WaitForChild("internal"):WaitForChild("Channel"))
local Harness = require(benchFolder:WaitForChild("Harness"))
local Scenarios = require(benchFolder:WaitForChild("Scenarios"))

Lync.configure({ channelMaxSize = 1048576, stats = true })
Lync.start()

local N = 100000

-- ═══════════════════════════════════════════════════════════════
-- Sections 1–5: CPU-only (no player needed)
-- ═══════════════════════════════════════════════════════════════

Harness.header("Wire Sizes")

Harness.section("Primitives")
Harness.benchWireSize("bool", Lync.bool, true)
Harness.benchWireSize("u8", Lync.int(0, 255), 42)
Harness.benchWireSize("u16", Lync.int(0, 65535), 1000)
Harness.benchWireSize("u32", Lync.int(0, 1000000), 500000)
Harness.benchWireSize("i8", Lync.int(-128, 127), -50)
Harness.benchWireSize("i16", Lync.int(-32768, 32767), -1000)
Harness.benchWireSize("i32", Lync.int(-2147483648, 2147483647), -100000)
Harness.benchWireSize("f16", Lync.f16, 42.5)
Harness.benchWireSize("f32", Lync.f32, 3.14)
Harness.benchWireSize("f64", Lync.f64, math.pi)
Harness.benchWireSize("nothing", Lync.nothing, nil)
Harness.sectionEnd()

Harness.section("Strings")
Harness.benchWireSize("empty", Lync.string, "")
Harness.benchWireSize("5 chars", Lync.string, "hello")
Harness.benchWireSize("100 chars", Lync.string, string.rep("x", 100))
Harness.benchWireSize("191 chars (max inline)", Lync.string, string.rep("x", 191))
Harness.benchWireSize("192 chars (varint)", Lync.string, string.rep("x", 192))
Harness.benchWireSize("1000 chars", Lync.string, string.rep("x", 1000))
Harness.sectionEnd()

Harness.section("Vectors & Spatial")
Harness.benchWireSize("vec2 (lossless)", Lync.vec2, Vector2.new(1, 2))
Harness.benchWireSize("vec2 (u8 quantized)", Lync.vec2(0, 100, 1), Vector2.new(50, 75))
Harness.benchWireSize("vec3 (lossless)", Lync.vec3, Vector3.new(1, 2, 3))
Harness.benchWireSize("vec3 (u8 quantized)", Lync.vec3(0, 100, 1), Vector3.new(25, 50, 75))
Harness.benchWireSize("vec3 (u16 quantized)", Lync.vec3(-1000, 1000, 0.1), Vector3.new(0, 0, 0))
Harness.benchWireSize(
    "cframe (lossless 24B)",
    Lync.cframe,
    CFrame.new(10, 20, 30) * CFrame.Angles(1, 0.5, 0.3)
)
Harness.benchWireSize(
    "cframe (compressed 16B)",
    Lync.cframe(),
    CFrame.new(10, 20, 30) * CFrame.Angles(1, 0.5, 0.3)
)
Harness.benchWireSize("color3", Lync.color3, Color3.fromRGB(255, 128, 0))
Harness.benchWireSize("ray", Lync.ray, Ray.new(Vector3.zero, Vector3.yAxis))
Harness.sectionEnd()

Harness.section("Structs")
Harness.benchWireSize("entity (lossless)", Scenarios.entityCodec, Scenarios.ENTITY)
Harness.benchWireSize("entity (compact)", Scenarios.entityCompactCodec, Scenarios.ENTITY_COMPACT)
Harness.benchWireSize("bitfield flags", Scenarios.flagsCodec, Scenarios.FLAGS)
Harness.sectionEnd()

Harness.section("Arrays")
Harness.benchWireSize(
    "100x entities",
    Lync.array(Scenarios.blinkEntityCodec),
    Scenarios.BLINK_ENTITIES
)
Harness.benchWireSize("1000x bools (bitpacked)", Lync.array(Lync.bool), Scenarios.BLINK_BOOLS)
Harness.sectionEnd()

Harness.header("Codec Throughput")

Harness.section("Primitive encode/decode round-trips")
Harness.benchRoundTrip("bool", N, Lync.bool, true)
Harness.benchRoundTrip("u8", N, Lync.int(0, 255), 42)
Harness.benchRoundTrip("u16", N, Lync.int(0, 65535), 30000)
Harness.benchRoundTrip("i16", N, Lync.int(-32768, 32767), -1000)
Harness.benchRoundTrip("f16", N, Lync.f16, 42.5)
Harness.benchRoundTrip("f32", N, Lync.f32, 3.14)
Harness.benchRoundTrip("f64", N, Lync.f64, math.pi)
Harness.sectionEnd()

Harness.section("String encode/decode")
Harness.benchRoundTrip("empty string", N, Lync.string, "")
Harness.benchRoundTrip("10-char string", N, Lync.string, "0123456789")
Harness.benchRoundTrip("100-char string", N, Lync.string, string.rep("x", 100))
Harness.benchRoundTrip("1000-char string", N // 10, Lync.string, string.rep("x", 1000))
Harness.sectionEnd()

Harness.section("Roblox types")
Harness.benchRoundTrip("vec2", N, Lync.vec2, Vector2.new(1.5, -3.25))
Harness.benchRoundTrip("vec3", N, Lync.vec3, Vector3.new(1, 2, 3))
Harness.benchRoundTrip("vec3 quantized", N, Lync.vec3(0, 100, 1), Vector3.new(25, 50, 75))
Harness.benchRoundTrip(
    "cframe lossless",
    N,
    Lync.cframe,
    CFrame.new(10, 20, 30) * CFrame.Angles(1, 0.5, 0.3)
)
Harness.benchRoundTrip(
    "cframe compressed",
    N,
    Lync.cframe(),
    CFrame.new(10, 20, 30) * CFrame.Angles(1, 0.5, 0.3)
)
Harness.benchRoundTrip("color3", N, Lync.color3, Color3.fromRGB(255, 128, 0))
Harness.benchRoundTrip("udim2", N, Lync.udim2, UDim2.new(UDim.new(0.5, 10), UDim.new(1, 20)))
Harness.sectionEnd()

Harness.section("Composites")
Harness.benchRoundTrip("entity struct", N // 2, Scenarios.entityCodec, Scenarios.ENTITY)
Harness.benchRoundTrip(
    "entity compact",
    N // 2,
    Scenarios.entityCompactCodec,
    Scenarios.ENTITY_COMPACT
)
Harness.benchRoundTrip("bitfield flags", N, Scenarios.flagsCodec, Scenarios.FLAGS)
Harness.benchRoundTrip(
    "100x entities",
    N // 50,
    Lync.array(Scenarios.blinkEntityCodec),
    Scenarios.BLINK_ENTITIES
)
Harness.benchRoundTrip("1000x bools", N // 10, Lync.array(Lync.bool), Scenarios.BLINK_BOOLS)
Harness.sectionEnd()

Harness.header("Delta Savings")

Harness.section("deltaStruct unchanged vs changed")
Harness.benchDelta("entity delta", Scenarios.deltaEntityCodec, Scenarios.ENTITY)
Harness.benchDelta(
    "compact delta",
    Lync.deltaStruct({
        position = Lync.vec3(-500, 500, 0.1),
        velocity = Lync.vec3(-50, 50, 0.5),
        health = Lync.int(0, 255),
        shield = Lync.int(0, 255),
        alive = Lync.bool,
        team = Lync.int(0, 7),
    }),
    Scenarios.ENTITY_COMPACT
)
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

Harness.header("Batch Framing Overhead")

Harness.section("MSB single vs multi-item")

do
    local codec = Lync.int(0, 255)
    local openFn = Channel.resolveOpenFn(Channel.TS_NONE, "__bench_msb")
    local reg: any = {
        id = 1,
        name = "__bench_msb",
        kind = 0,
        codec = codec,
        isUnreliable = false,
        headerSize = 1,
        timestampMode = Channel.TS_NONE,
        _openFn = openFn,
    }

    local ch1 = Channel.create()
    Channel.writeBatch(ch1, reg, 42)
    print(`  │  single-item header: {ch1.cursor}B total (1B header + 1B payload)`)

    local ch10 = Channel.create()
    for _ = 1, 10 do
        Channel.writeBatch(ch10, reg, 42)
    end
    local overhead = ch10.cursor - 10
    print(`  │  10-item batch: {ch10.cursor}B total ({overhead}B overhead for 10 items)`)
    print(`  │  per-item overhead: {overhead / 10}B`)
end

Harness.sectionEnd()

Harness.header("Encode Throughput")

Harness.section("Isolated encode speed (write only, no decode)")

Harness.benchEncode("bool x 100k", N, function(): ()
    local ch = Channel.create()
    Lync.bool.write(ch, true)
end)

Harness.benchEncode("entity struct x 100k", N, function(): ()
    local ch = Channel.create()
    Scenarios.entityCodec.write(ch, Scenarios.ENTITY)
end)

Harness.benchEncode("100x entities x 2k", N // 50, function(): ()
    local ch = Channel.create()
    Lync.array(Scenarios.blinkEntityCodec).write(ch, Scenarios.BLINK_ENTITIES)
end)

Harness.benchEncode("1000x bools x 10k", N // 10, function(): ()
    local ch = Channel.create()
    Lync.array(Lync.bool).write(ch, Scenarios.BLINK_BOOLS)
end)

Harness.benchEncode("cframe compressed x 100k", N, function(): ()
    local ch = Channel.create()
    Lync.cframe().write(ch, CFrame.new(10, 20, 30) * CFrame.Angles(1, 0.5, 0.3))
end)

Harness.sectionEnd()

-- ═══════════════════════════════════════════════════════════════
-- Sections 6–7: network (needs a connected client)
-- ═══════════════════════════════════════════════════════════════

local function getPlayer(): Player
    local players = Players:GetPlayers()
    return if #players > 0 then players[1] else Players.PlayerAdded:Wait()
end

local player = getPlayer()

--[[
    Handshake: server tells the client CPU tests are done,
    client responds with Ready. Without this the client sends
    Ready while sections 1–5 are still running and the signal
    fires before the server registers its wait() listener.
]]
Scenarios.ServerReady:send(true, player)
Scenarios.Ready:wait()

local NET_FIRES = 1000
local NET_DURATION = 8

Harness.header("Network Throughput")

Harness.section(`{NET_FIRES}/frame, {NET_DURATION}s per test`)

Harness.benchNetwork("booleans", NET_FIRES, NET_DURATION, Scenarios.BoolPacket, true, player)

Harness.benchNetwork(
    "entity struct",
    NET_FIRES,
    NET_DURATION,
    Scenarios.EntityPacket,
    Scenarios.ENTITY,
    player
)

Harness.benchNetwork(
    "entity compact",
    NET_FIRES,
    NET_DURATION,
    Scenarios.EntityCompactPacket,
    Scenarios.ENTITY_COMPACT,
    player
)

Harness.benchNetwork(
    "100x entities",
    NET_FIRES // 10,
    NET_DURATION,
    Scenarios.BlinkEntitiesPacket,
    Scenarios.BLINK_ENTITIES,
    player
)

Harness.benchNetwork(
    "1000x bools",
    NET_FIRES // 10,
    NET_DURATION,
    Scenarios.BlinkBoolsPacket,
    Scenarios.BLINK_BOOLS,
    player
)

Harness.benchNetwork(
    "bitfield flags",
    NET_FIRES,
    NET_DURATION,
    Scenarios.FlagsPacket,
    Scenarios.FLAGS,
    player
)

Harness.benchNetwork(
    "cframe lossless",
    NET_FIRES,
    NET_DURATION,
    Scenarios.CFramePacket,
    CFrame.new(10, 20, 30) * CFrame.Angles(1, 0.5, 0.3),
    player
)

Harness.benchNetwork(
    "cframe compressed",
    NET_FIRES,
    NET_DURATION,
    Scenarios.CFrameCPacket,
    CFrame.new(10, 20, 30) * CFrame.Angles(1, 0.5, 0.3),
    player
)

Harness.sectionEnd()

local COMP_FIRES = 1000
local COMP_DURATION = 10
local COMP_FPS = 60

Harness.header("Cross-Library Comparison Data")

print("  ┌ Notes")
print("  │  Paste these numbers into the README comparison tables.")
print("  │  Same data shapes as github.com/1Axen/blink/benchmark.")
print("  └")

Harness.section(`Entities — 100x struct(6x u8) — {COMP_FIRES}/frame, {COMP_DURATION}s`)
Harness.benchComparison(
    "100x entities",
    COMP_FIRES,
    COMP_DURATION,
    COMP_FPS,
    Scenarios.BlinkEntitiesPacket,
    Scenarios.BLINK_ENTITIES,
    player
)
Harness.sectionEnd()

Harness.section(`Booleans — 1000x bool — {COMP_FIRES}/frame, {COMP_DURATION}s`)
Harness.benchComparison(
    "1000x bools",
    COMP_FIRES,
    COMP_DURATION,
    COMP_FPS,
    Scenarios.BlinkBoolsPacket,
    Scenarios.BLINK_BOOLS,
    player
)
Harness.sectionEnd()

Harness.section("Wire size comparison")

do
    local entBytes = Harness.benchWireSize(
        "Lync: 100x entities",
        Lync.array(Scenarios.blinkEntityCodec),
        Scenarios.BLINK_ENTITIES
    )
    print(`  │  Other tools: ~602B (100 x 6B + ~2B length)`)
    print(`  │  Difference:  {entBytes - 602}B`)

    local boolBytes = Harness.benchWireSize(
        "Lync: 1000x bools (bitpacked)",
        Lync.array(Lync.bool),
        Scenarios.BLINK_BOOLS
    )
    print(`  │  Other tools: ~1002B (1000 x 1B + ~2B length)`)
    print(
        `  │  Difference:  {boolBytes - 1002}B ({if boolBytes < 1002
            then `{math.floor((1 - boolBytes / 1002) * 100)}% smaller`
            else "comparable"})`
    )
end

Harness.sectionEnd()
