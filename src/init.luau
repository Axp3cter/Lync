--!strict
--!optimize 2
-- Public API.

local RunService = game:GetService ("RunService")

local Bitfield = require (script.codec.Bitfield)
local Buffer = require (script.codec.Buffer)
local CFrameCodec = require (script.codec.CFrame)
local Channel = require (script.core.Channel)
local Client = require (script.transport.Client)
local Color = require (script.codec.Color)
local Composite = require (script.codec.Composite)
local Custom = require (script.codec.Custom)
local EnumCodec = require (script.codec.Enum)
local Float16 = require (script.codec.Float16)
local Gate = require (script.transport.Gate)
local Group = require (script.event.Group)
local InstanceCodec = require (script.codec.Instance)
local IntVector = require (script.codec.IntVector)
local Middleware = require (script.core.Middleware)
local Namespace = require (script.event.Namespace)
local NumberRangeCodec = require (script.codec.NumberRange)
local Packet = require (script.event.Packet)
local Pool = require (script.core.Pool)
local Primitive = require (script.codec.Primitive)
local Quantized = require (script.codec.Quantized)
local Query = require (script.event.Query)
local RayCodec = require (script.codec.Ray)
local RectCodec = require (script.codec.Rect)
local Region = require (script.codec.Region)
local Sequence = require (script.codec.Sequence)
local Server = require (script.transport.Server)
local Special = require (script.codec.Special)
local String = require (script.codec.String)
local Tagged = require (script.codec.Tagged)
local Tuple = require (script.codec.Tuple)
local UDimCodec = require (script.codec.UDim)
local Vector = require (script.codec.Vector)

-- Public -----------------------------------------------------------------

local function start (): ()
    if RunService:IsServer () then
        Server.start ()
    else
        Client.start ()
    end
end

local Lync = {
    VERSION = "1.1.0",
    version = "1.1.0",

    -- Lifecycle
    start = start,

    -- Definition
    definePacket = Packet.define,
    defineQuery = Query.define,
    defineNamespace = Namespace.define,

    -- Primitives
    u8 = Primitive.u8,
    u16 = Primitive.u16,
    u32 = Primitive.u32,
    i8 = Primitive.i8,
    i16 = Primitive.i16,
    i32 = Primitive.i32,
    f32 = Primitive.f32,
    f64 = Primitive.f64,
    bool = Primitive.bool,
    f16 = Float16.f16,

    -- Complex types
    string = String.string,
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
    struct = Composite.struct,
    deltaStruct = Composite.deltaStruct,
    deltaArray = Composite.deltaArray,
    deltaMap = Composite.deltaMap,
    array = Composite.array,
    map = Composite.map,
    optional = Composite.optional,

    -- Specialized
    enum = EnumCodec.define,
    quantizedFloat = Quantized.float,
    quantizedVec3 = Quantized.vec3,
    bitfield = Bitfield.define,
    tagged = Tagged.define,
    tuple = Tuple.define,
    custom = Custom.define,

    -- Special
    nothing = Special.nothing,
    unknown = Special.unknown,
    auto = Special.auto,

    -- Hooks
    onDrop = Gate.onDrop,
    onSend = Middleware.addSend,
    onReceive = Middleware.addReceive,

    -- Groups
    createGroup = Group.create,
    destroyGroup = Group.destroy,
    addToGroup = Group.add,
    removeFromGroup = Group.remove,
    hasInGroup = Group.has,
    getGroupSet = Group.getSet,
    groupCount = Group.count,
    forEachInGroup = Group.forEach,

    -- Configuration (call before start)
    setChannelMaxSize = Channel.setMaxSize,
    setValidationDepth = Gate.setMaxDepth,
    setPoolSize = Pool.setMaxSize,

    -- Introspection
    queryPendingCount = Query.pendingCount,
}

return table.freeze (Lync)
