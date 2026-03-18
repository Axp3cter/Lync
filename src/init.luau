--!strict
--!optimize 2
-- Public API.

local RunService = game:GetService("RunService")

-- Codec: primitive
local BoolCodec = require(script.codec.primitive.Bool)
local Float16 = require(script.codec.primitive.Float16)
local NumberCodec = require(script.codec.primitive.Number)

-- Codec: datatype
local BufferCodec = require(script.codec.datatype.Buffer)
local CFrameCodec = require(script.codec.datatype.CFrame)
local ColorCodec = require(script.codec.datatype.Color)
local InstanceCodec = require(script.codec.datatype.Instance)
local IntVectorCodec = require(script.codec.datatype.IntVector)
local NumberRangeCodec = require(script.codec.datatype.NumberRange)
local RayCodec = require(script.codec.datatype.Ray)
local RectCodec = require(script.codec.datatype.Rect)
local RegionCodec = require(script.codec.datatype.Region)
local SequenceCodec = require(script.codec.datatype.Sequence)
local StringCodec = require(script.codec.datatype.String)
local UDimCodec = require(script.codec.datatype.UDim)
local VectorCodec = require(script.codec.datatype.Vector)

-- Codec: composite
local Array = require(script.codec.composite.Array)
local Map = require(script.codec.composite.Map)
local Optional = require(script.codec.composite.Optional)
local Struct = require(script.codec.composite.Struct)
local Tagged = require(script.codec.composite.Tagged)
local Tuple = require(script.codec.composite.Tuple)

-- Codec: meta
local Auto = require(script.codec.meta.Auto)
local Bitfield = require(script.codec.meta.Bitfield)
local Custom = require(script.codec.meta.Custom)
local EnumCodec = require(script.codec.meta.Enum)
local Nothing = require(script.codec.meta.Nothing)
local Quantized = require(script.codec.meta.Quantized)
local Unknown = require(script.codec.meta.Unknown)

-- Internal
local Channel = require(script.internal.Channel)
local Middleware = require(script.internal.Middleware)
local Pool = require(script.internal.Pool)

-- Transport
local Client = require(script.transport.Client)
local Gate = require(script.transport.Gate)
local Server = require(script.transport.Server)

-- API
local GroupModule = require(script.api.Group)
local NamespaceModule = require(script.api.Namespace)
local PacketModule = require(script.api.Packet)
local QueryModule = require(script.api.Query)
local ScopeModule = require(script.api.Scope)
local SignalModule = require(script.api.Signal)

-- Type re-exports -----------------------------------------------------

local Types = require(script.Types)

export type Codec<T> = Types.Codec<T>
export type InternalCodec<T> = Types.InternalCodec<T>
export type Connection = Types.Connection
export type RateLimitConfig = Types.RateLimitConfig
export type PacketConfig<T> = Types.PacketConfig<T>
export type QueryConfig<R, S> = Types.QueryConfig<R, S>

export type Packet = PacketModule.Packet
export type Query = QueryModule.Query
export type Group = GroupModule.Group
export type Scope = ScopeModule.Scope
export type Namespace = NamespaceModule.Namespace
export type Signal = SignalModule.Signal
export type NamespaceConfig = Types.NamespaceConfig

-- Constants -----------------------------------------------------------

local ALL = table.freeze({ _tag = "all" })

-- Private -------------------------------------------------------------

local function except(...: any): any
    local count = select("#", ...)
    local set = {} :: { [Player]: true }
    for i = 1, count do
        set[select(i, ...)] = true
    end
    return { _tag = "except", _set = set }
end

local function start(): ()
    if RunService:IsServer() then
        Server.start()
    else
        Client.start()
    end
end

-- Public --------------------------------------------------------------

local IS_SERVER = RunService:IsServer()

local function flush(): ()
    if IS_SERVER then
        Server.flush()
    else
        Client.flush()
    end
end

local function setFlushRate(hz: number): ()
    if IS_SERVER then
        Server.setFlushRate(hz)
    else
        Client.setFlushRate(hz)
    end
end

local function getPlayerStats(player: Player): any?
    return Server.getPlayerStats(player)
end

local function resetStats(): ()
    Server.resetStats()
end

local function setBandwidthLimit(softLimit: number, maxStrikes: number): ()
    Server.setBandwidthLimit(softLimit, maxStrikes)
end

local Lync = {
    VERSION = "2.0.0",

    -- Lifecycle
    start = start,

    -- Definition
    definePacket = PacketModule.define,
    defineQuery = QueryModule.define,
    defineNamespace = NamespaceModule.define,

    -- Primitives
    u8 = NumberCodec.u8,
    u16 = NumberCodec.u16,
    u32 = NumberCodec.u32,
    i8 = NumberCodec.i8,
    i16 = NumberCodec.i16,
    i32 = NumberCodec.i32,
    f32 = NumberCodec.f32,
    f64 = NumberCodec.f64,
    bool = BoolCodec.bool,
    f16 = Float16.f16,

    -- Datatypes
    string = StringCodec.string,
    boundedString = StringCodec.bounded,
    vec2 = VectorCodec.vec2,
    vec3 = VectorCodec.vec3,
    cframe = CFrameCodec.cframe,
    color3 = ColorCodec.color3,
    inst = InstanceCodec.inst,
    buff = BufferCodec.buff,
    udim = UDimCodec.udim,
    udim2 = UDimCodec.udim2,
    numberRange = NumberRangeCodec.numberRange,
    rect = RectCodec.rect,
    vec2int16 = IntVectorCodec.vec2int16,
    vec3int16 = IntVectorCodec.vec3int16,
    region3 = RegionCodec.region3,
    region3int16 = RegionCodec.region3int16,
    ray = RayCodec.ray,
    numberSequence = SequenceCodec.numberSequence,
    colorSequence = SequenceCodec.colorSequence,

    -- Composites
    struct = Struct.struct,
    deltaStruct = Struct.deltaStruct,
    deltaArray = Array.deltaArray,
    deltaMap = Map.deltaMap,
    array = Array.array,
    map = Map.map,
    optional = Optional.optional,
    tuple = Tuple.define,
    tagged = Tagged.define,

    -- Meta
    enum = EnumCodec.define,
    quantizedFloat = Quantized.float,
    quantizedVec3 = Quantized.vec3,
    bitfield = Bitfield.define,
    custom = Custom.define,

    nothing = Nothing.nothing,
    unknown = Unknown.unknown,
    auto = Auto.auto,

    -- Hooks
    onDrop = Gate.onDrop,
    onSend = Middleware.addSend,
    onReceive = Middleware.addReceive,

    -- Target descriptors
    all = ALL,
    except = except,

    -- Middleware sentinel
    DROP = Middleware.DROP,

    -- Groups
    createGroup = GroupModule.create,

    -- Scope
    scope = ScopeModule.create,

    -- Configuration (call before start)
    setChannelMaxSize = Channel.setMaxSize,
    setValidationDepth = Gate.setMaxDepth,
    setPoolSize = Pool.setMaxSize,

    -- Runtime configuration
    flush = flush,
    setFlushRate = setFlushRate,

    -- Stats (default off; call enableStats() to activate)
    enableStats = Channel.enableStats,
    getPlayerStats = getPlayerStats,
    resetStats = resetStats,

    -- Security (server-only)
    setBandwidthLimit = setBandwidthLimit,

    -- Introspection
    queryPendingCount = QueryModule.pendingCount,

    -- Packet capture (server-only, debug)
    startCapture = if IS_SERVER then Server.startCapture else nil,
    stopCapture = if IS_SERVER then Server.stopCapture else nil,
    dumpCaptures = if IS_SERVER then Server.dumpCaptures else nil,
}

Lync.default = Lync
return table.freeze(Lync)
