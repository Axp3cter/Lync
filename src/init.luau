--!strict
--!optimize 2
-- Public API.

local RunService = game:GetService ("RunService")

-- Codec: primitive
local BoolCodec = require (script.codec.primitive.Bool)
local Float16 = require (script.codec.primitive.Float16)
local Number = require (script.codec.primitive.Number)

-- Codec: datatype
local Buffer = require (script.codec.datatype.Buffer)
local CFrameCodec = require (script.codec.datatype.CFrame)
local Color = require (script.codec.datatype.Color)
local InstanceCodec = require (script.codec.datatype.Instance)
local IntVector = require (script.codec.datatype.IntVector)
local NumberRangeCodec = require (script.codec.datatype.NumberRange)
local RayCodec = require (script.codec.datatype.Ray)
local RectCodec = require (script.codec.datatype.Rect)
local Region = require (script.codec.datatype.Region)
local Sequence = require (script.codec.datatype.Sequence)
local String = require (script.codec.datatype.String)
local UDimCodec = require (script.codec.datatype.UDim)
local Vector = require (script.codec.datatype.Vector)

-- Codec: composite
local Array = require (script.codec.composite.Array)
local Map = require (script.codec.composite.Map)
local Optional = require (script.codec.composite.Optional)
local Struct = require (script.codec.composite.Struct)
local Tagged = require (script.codec.composite.Tagged)
local Tuple = require (script.codec.composite.Tuple)

-- Codec: meta
local Auto = require (script.codec.meta.Auto)
local Bitfield = require (script.codec.meta.Bitfield)
local Custom = require (script.codec.meta.Custom)
local EnumCodec = require (script.codec.meta.Enum)
local Nothing = require (script.codec.meta.Nothing)
local Quantized = require (script.codec.meta.Quantized)
local Unknown = require (script.codec.meta.Unknown)

-- Internal
local Channel = require (script.internal.Channel)
local Gate = require (script.transport.Gate)
local Middleware = require (script.internal.Middleware)
local Pool = require (script.internal.Pool)

-- API
local Group = require (script.api.Group)
local Namespace = require (script.api.Namespace)
local Packet = require (script.api.Packet)
local Query = require (script.api.Query)
local Scope = require (script.api.Scope)

-- Transport
local Client = require (script.transport.Client)
local Server = require (script.transport.Server)

-- Sentinels --------------------------------------------------------------

local ALL = table.freeze ({ _tag = "all" })

local function except (...: any): any
    local count = select ("#", ...)
    local set = {} :: { [Player]: true }
    for i = 1, count do
        set[select (i, ...)] = true
    end
    return { _tag = "except", _set = set }
end

-- Public -----------------------------------------------------------------

local function start (): ()
    if RunService:IsServer () then
        Server.start ()
    else
        Client.start ()
    end
end

local Lync = {
    VERSION = "1.4.0",

    -- Lifecycle
    start = start,

    -- Definition
    definePacket = Packet.define,
    defineQuery = Query.define,
    defineNamespace = Namespace.define,

    -- Primitives
    u8 = Number.u8,
    u16 = Number.u16,
    u32 = Number.u32,
    i8 = Number.i8,
    i16 = Number.i16,
    i32 = Number.i32,
    f32 = Number.f32,
    f64 = Number.f64,
    bool = BoolCodec.bool,
    f16 = Float16.f16,

    -- Datatypes
    string = String.string,
    boundedString = String.bounded,
    vec2 = Vector.vec2,
    vec3 = Vector.vec3,
    cframe = CFrameCodec.cframe,
    color3 = Color.color3,
    inst = InstanceCodec.inst,
    buff = Buffer.buff,
    udim = UDimCodec.udim,
    udim2 = UDimCodec.udim2,
    numberRange = NumberRangeCodec.numberRange,
    rect = RectCodec.rect,
    vec2int16 = IntVector.vec2int16,
    vec3int16 = IntVector.vec3int16,
    region3 = Region.region3,
    region3int16 = Region.region3int16,
    ray = RayCodec.ray,
    numberSequence = Sequence.numberSequence,
    colorSequence = Sequence.colorSequence,

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
    createGroup = Group.create,

    -- Scope
    scope = Scope.create,

    -- Configuration (call before start)
    setChannelMaxSize = Channel.setMaxSize,
    setValidationDepth = Gate.setMaxDepth,
    setPoolSize = Pool.setMaxSize,

    -- Introspection
    queryPendingCount = Query.pendingCount,
}

Lync.default = Lync
return table.freeze (Lync)
