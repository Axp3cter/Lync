--!strict
--!optimize 2
-- Public API.

local RunService = game:GetService ("RunService")

local Bitfield = require (script.codec.Bitfield)
local Buffer = require (script.codec.Buffer)
local CFrameCodec = require (script.codec.CFrame)
local Client = require (script.transport.Client)
local Color = require (script.codec.Color)
local Composite = require (script.codec.Composite)
local EnumCodec = require (script.codec.Enum)
local Float16 = require (script.codec.Float16)
local Gate = require (script.transport.Gate)
local Group = require (script.event.Group)
local InstanceCodec = require (script.codec.Instance)
local Middleware = require (script.core.Middleware)
local Packet = require (script.event.Packet)
local Primitive = require (script.codec.Primitive)
local Quantized = require (script.codec.Quantized)
local Query = require (script.event.Query)
local Server = require (script.transport.Server)
local Special = require (script.codec.Special)
local String = require (script.codec.String)
local Tagged = require (script.codec.Tagged)
local Tuple = require (script.codec.Tuple)
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
    VERSION = "0.4.0-alpha",

    -- Lifecycle
    start = start,

    -- Definition
    definePacket = Packet.define,
    defineQuery = Query.define,

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

    -- Composites
    struct = Composite.struct,
    deltaStruct = Composite.deltaStruct,
    deltaArray = Composite.deltaArray,
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
    forEachInGroup = Group.forEach,
}

return table.freeze (Lync)
