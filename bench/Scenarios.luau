--!strict
--!optimize 2
-- Bench definitions: codec catalogue, delta catalogue, network workloads.

local Lync = require(script.Parent.Parent)

-- Constants --------------------------------------------------------------

local POOL_SIZE = 1000
local ENT_COUNT = 100
local BOOL_COUNT = 1000
local CFRAME_COUNT = 50

-- Schemas ----------------------------------------------------------------

local entitySchema = {
    id = Lync.int(0, 255),
    x = Lync.int(0, 255),
    y = Lync.int(0, 255),
    z = Lync.int(0, 255),
    orientation = Lync.int(0, 255),
    animation = Lync.int(0, 255),
}

local stateSchema = {
    posX = Lync.f32,
    posY = Lync.f32,
    posZ = Lync.f32,
    velX = Lync.f32,
    velY = Lync.f32,
    velZ = Lync.f32,
    yaw = Lync.f32,
    pitch = Lync.f32,
    health = Lync.int(0, 255),
    armor = Lync.int(0, 255),
    alive = Lync.bool,
    grounded = Lync.bool,
}

local entityCodec = Lync.struct(entitySchema)
local entityArray = Lync.array(entityCodec)
local boolArray = Lync.array(Lync.bool)
local cframeArray = Lync.array(Lync.cframe())
local stateCodec = Lync.struct(stateSchema)
local stateDelta = Lync.deltaStruct(stateSchema)

-- Generators -------------------------------------------------------------

local rng = Random.new(0xB1A5)

local function entity()
    return {
        id = rng:NextInteger(0, 255),
        x = rng:NextInteger(0, 255),
        y = rng:NextInteger(0, 255),
        z = rng:NextInteger(0, 255),
        orientation = rng:NextInteger(0, 255),
        animation = rng:NextInteger(0, 255),
    }
end

local function entityArr(n: number)
    local a = table.create(n)
    for i = 1, n do
        a[i] = entity()
    end
    return a
end

local function boolArr(n: number)
    local a = table.create(n)
    for i = 1, n do
        a[i] = rng:NextNumber() < 0.5
    end
    return a
end

local function cframeOne(): CFrame
    return CFrame.new(rng:NextNumber(-500, 500), rng:NextNumber(0, 100), rng:NextNumber(-500, 500))
        * CFrame.Angles(
            rng:NextNumber(-math.pi, math.pi),
            rng:NextNumber(-math.pi, math.pi),
            rng:NextNumber(-math.pi, math.pi)
        )
end

local function cframeArr(n: number)
    local a = table.create(n)
    for i = 1, n do
        a[i] = cframeOne()
    end
    return a
end

local function stateOne()
    return {
        posX = rng:NextNumber(-500, 500),
        posY = rng:NextNumber(0, 100),
        posZ = rng:NextNumber(-500, 500),
        velX = rng:NextNumber(-50, 50),
        velY = rng:NextNumber(-20, 20),
        velZ = rng:NextNumber(-50, 50),
        yaw = rng:NextNumber(-math.pi, math.pi),
        pitch = rng:NextNumber(-1.4, 1.4),
        health = rng:NextInteger(0, 255),
        armor = rng:NextInteger(0, 255),
        alive = rng:NextNumber() < 0.95,
        grounded = rng:NextNumber() < 0.7,
    }
end

-- Pool builders ----------------------------------------------------------

local function poolVarying<T>(make: () -> T): { T }
    local p = table.create(POOL_SIZE)
    for i = 1, POOL_SIZE do
        p[i] = make()
    end
    return table.freeze(p) :: { T }
end

local function poolShared<T>(make: () -> T): { T }
    local one = make()
    local p = table.create(POOL_SIZE)
    for i = 1, POOL_SIZE do
        p[i] = one
    end
    return table.freeze(p) :: { T }
end

local function poolBoolFlip(n: number)
    local current = boolArr(n)
    local p = table.create(POOL_SIZE)
    p[1] = table.clone(current)
    for i = 2, POOL_SIZE do
        local idx = 1 + (i - 2) % n
        current[idx] = not current[idx]
        p[i] = table.clone(current)
    end
    return table.freeze(p) :: { { boolean } }
end

local function poolStateOneMut()
    local keys =
        { "posX", "posY", "posZ", "velX", "velY", "velZ", "yaw", "pitch", "health", "armor" }
    local current = stateOne()
    local p = table.create(POOL_SIZE)
    p[1] = table.clone(current)
    for i = 2, POOL_SIZE do
        local k = keys[1 + (i - 2) % #keys]
        if k == "health" or k == "armor" then
            current[k] = rng:NextInteger(0, 255)
        else
            current[k] = rng:NextNumber(-100, 100)
        end
        p[i] = table.clone(current)
    end
    return table.freeze(p) :: { { [string]: any } }
end

-- Wire-size catalogue ----------------------------------------------------

local wireCases = table.freeze({
    { label = "u8", codec = Lync.int(0, 255), value = 200 },
    { label = "u16", codec = Lync.int(0, 65535), value = 30000 },
    { label = "u32", codec = Lync.int(0, 0xFFFFFFFF), value = 1234567890 },
    { label = "f16", codec = Lync.f16, value = 42.5 },
    { label = "f32", codec = Lync.f32, value = 3.14 },
    { label = "f64", codec = Lync.f64, value = math.pi },
    {
        label = "vec3.lossless",
        codec = Lync.vec3,
        value = Vector3.new(1.5, 2.5, 3.5),
    },
    {
        label = "vec3.q[0..100,1]",
        codec = Lync.vec3(0, 100, 1),
        value = Vector3.new(25, 50, 75),
    },
    { label = "vec3.q[-1k..1k,.1]", codec = Lync.vec3(-1000, 1000, 0.1), value = Vector3.zero },
    {
        label = "cframe.lossless",
        codec = Lync.cframe,
        value = CFrame.new(1, 2, 3),
    },
    {
        label = "cframe.compact",
        codec = Lync.cframe(),
        value = CFrame.new(1, 2, 3),
    },
    {
        label = "color3",
        codec = Lync.color3,
        value = Color3.fromRGB(128, 64, 200),
    },
    { label = "string[5]", codec = Lync.string, value = "hello" },
    {
        label = "string[191]",
        codec = Lync.string,
        value = string.rep("x", 191),
    },
    {
        label = "string[192]",
        codec = Lync.string,
        value = string.rep("x", 192),
    },
    {
        label = "string[1000]",
        codec = Lync.string,
        value = string.rep("x", 1000),
    },
    { label = "optional<u8>(some)", codec = Lync.optional(Lync.int(0, 255)), value = 7 },
    { label = "optional<u8>(none)", codec = Lync.optional(Lync.int(0, 255)), value = nil },
    {
        label = "array<u8>[100]",
        codec = Lync.array(Lync.int(0, 255)),
        value = (function()
            local t = {}
            for i = 1, 100 do
                t[i] = i % 256
            end
            return t
        end)(),
    },
    { label = "array<bool>[1000]", codec = boolArray, value = boolArr(1000) },
    { label = "entity_struct", codec = entityCodec, value = entity() },
    {
        label = "entity_arr_100",
        codec = entityArray,
        value = entityArr(100),
    },
    { label = "state_struct", codec = stateCodec, value = stateOne() },
    {
        label = "bitfield[6 fields]",
        codec = Lync.bitfield({
            a = { type = "bool" },
            b = { type = "bool" },
            c = { type = "bool" },
            d = { type = "bool" },
            tier = { type = "uint", width = 4 },
            level = { type = "uint", width = 8 },
        }),
        value = { a = true, b = false, c = true, d = false, tier = 7, level = 99 },
    },
})

-- Delta wire-size catalogue ----------------------------------------------

local stateBase = stateOne()
local stateOneMut = table.clone(stateBase)
stateOneMut.posX = 999
local stateMultiMut = table.clone(stateBase)
stateMultiMut.posX = 1
stateMultiMut.posY = 2
stateMultiMut.posZ = 3
stateMultiMut.velX = 4
stateMultiMut.velY = 5
stateMultiMut.velZ = 6

local deltaCases = table.freeze({
    { label = "delta unchanged", seed = stateBase, value = stateBase },
    { label = "delta 1-field-mut", seed = stateBase, value = stateOneMut },
    { label = "delta 6-fields-mut", seed = stateBase, value = stateMultiMut },
})

-- Round-trip catalogue (CPU only) ----------------------------------------

local entitySample = entityArr(ENT_COUNT)
local boolSample = boolArr(BOOL_COUNT)
local stateSample = stateOne()

local roundTripCases = table.freeze({
    { label = "u8", codec = Lync.int(0, 255), value = 42 },
    { label = "f32", codec = Lync.f32, value = 3.14 },
    { label = "vec3", codec = Lync.vec3, value = Vector3.new(1, 2, 3) },
    { label = "cframe.lossless", codec = Lync.cframe, value = CFrame.identity },
    { label = "cframe.compact", codec = Lync.cframe(), value = CFrame.identity },
    { label = "state_struct", codec = stateCodec, value = stateSample },
    { label = "entity_arr_100", codec = entityArray, value = entitySample },
    { label = "bool_arr_1000", codec = boolArray, value = boolSample },
})

--[[
    Blink-comparable workloads. Mirrors github.com/1Axen/blink/benchmark
    exactly: 1000 fires/frame for 10 s; the same payload reused across
    every fire and frame; entity array generated with math.randomseed(0)
    so server and client agree; bool array is `table.create(1000, true)`.
]]
type NetCase = { label: string, packet: any, pool: { any } }

local nextPacketId = 0
local function defCase(label: string, codec: any, pool: { any }): NetCase
    nextPacketId += 1
    return { label = label, packet = Lync.packet("Bench_" .. nextPacketId, codec), pool = pool }
end

local blinkEntityArr = (function()
    math.randomseed(0)
    local a = table.create(ENT_COUNT)
    for i = 1, ENT_COUNT do
        a[i] = {
            id = math.random(1, 255),
            x = math.random(1, 255),
            y = math.random(1, 255),
            z = math.random(1, 255),
            orientation = math.random(1, 255),
            animation = math.random(1, 255),
        }
    end
    return table.freeze(a)
end)()

local blinkBoolArr = table.freeze(table.create(BOOL_COUNT, true))

local blinkCases: { NetCase } = table.freeze({
    defCase(
        "blink_entity_arr_100",
        entityArray,
        table.freeze(table.create(POOL_SIZE, blinkEntityArr) :: { any })
    ),
    defCase(
        "blink_bool_arr_1000",
        boolArray,
        table.freeze(table.create(POOL_SIZE, blinkBoolArr) :: { any })
    ),
})

--[[
    Extended workloads at 100 fires/frame. Pairs vary/stable cases on the
    same codec to expose XOR + delta savings: vary = worst case, stable =
    same array reused so XOR collapses, delta = single field flipping.
]]
local extendedCases: { NetCase } = table.freeze({
    defCase(
        "entity_arr_100__vary",
        entityArray,
        poolVarying(function()
            return entityArr(ENT_COUNT)
        end)
    ),
    defCase(
        "entity_arr_100__stable",
        entityArray,
        poolShared(function()
            return entityArr(ENT_COUNT)
        end)
    ),
    defCase(
        "bool_arr_1000__vary",
        boolArray,
        poolVarying(function()
            return boolArr(BOOL_COUNT)
        end)
    ),
    defCase("bool_arr_1000__1flip", boolArray, poolBoolFlip(BOOL_COUNT)),
    defCase(
        "cframe_arr_50__vary",
        cframeArray,
        poolVarying(function()
            return cframeArr(CFRAME_COUNT)
        end)
    ),
    defCase("state_full__vary", stateCodec, poolVarying(stateOne)),
    defCase("state_delta__1mut", stateDelta, poolStateOneMut()),
})

-- Handshake --------------------------------------------------------------

local handshake = table.freeze({
    ServerCpuDone = Lync.packet("BenchServerCpuDone", Lync.bool),
    ClientReady = Lync.packet("BenchClientReady", Lync.bool),
    ServerSwap = Lync.packet("BenchServerSwap", Lync.bool),
    ClientDone = Lync.packet("BenchClientDone", Lync.bool),
})

-- Config -----------------------------------------------------------------

local bench = table.freeze({
    channelMaxSize = 1048576,
    blinkFiresPerFrame = 1000,
    blinkSeconds = 10,
    extendedFiresPerFrame = 100,
    extendedSeconds = 8,
})

return table.freeze({
    handshake = handshake,
    bench = bench,
    wireCases = wireCases,
    deltaCases = deltaCases,
    roundTripCases = roundTripCases,
    blinkCases = blinkCases,
    extendedCases = extendedCases,
    stateDelta = stateDelta,
})
