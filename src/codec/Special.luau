--!strict
--!optimize 2
-- Special.luau — Nothing, unknown, and auto (self-describing) codecs.

local Buffer      = require(script.Parent.Buffer)
local Channel     = require(script.Parent.Parent.core.Channel)
local Color       = require(script.Parent.Color)
local CFrameCodec = require(script.Parent.CFrame)
local Primitive   = require(script.Parent.Primitive)
local String      = require(script.Parent.String)
local Types       = require(script.Parent.Parent.Types)
local Vector      = require(script.Parent.Vector)

type ChannelState = Types.ChannelState
type Codec<T>     = Types.Codec<T>

-- Constants --------------------------------------------------------------

local TAG_NIL    = 0
local TAG_BOOL   = 1
local TAG_U8     = 2
local TAG_U16    = 3
local TAG_U32    = 4
local TAG_I8     = 5
local TAG_I16    = 6
local TAG_I32    = 7
local TAG_F32    = 8
local TAG_F64    = 9
local TAG_STRING = 10
local TAG_VEC2   = 11
local TAG_VEC3   = 12
local TAG_COLOR3 = 13
local TAG_CFRAME = 14
local TAG_BUFFER = 15

local floor = math.floor

local READ_DISPATCH = table.freeze({
    [TAG_BOOL]   = Primitive.bool,
    [TAG_U8]     = Primitive.u8,
    [TAG_U16]    = Primitive.u16,
    [TAG_U32]    = Primitive.u32,
    [TAG_I8]     = Primitive.i8,
    [TAG_I16]    = Primitive.i16,
    [TAG_I32]    = Primitive.i32,
    [TAG_F32]    = Primitive.f32,
    [TAG_F64]    = Primitive.f64,
    [TAG_STRING] = String.string,
    [TAG_VEC2]   = Vector.vec2,
    [TAG_VEC3]   = Vector.vec3,
    [TAG_COLOR3] = Color.color3,
    [TAG_CFRAME] = CFrameCodec.cframe,
    [TAG_BUFFER] = Buffer.buff,
})

local TYPE_DISPATCH = table.freeze({
    boolean = { tag = TAG_BOOL,   codec = Primitive.bool,   size = 1 },
    string  = { tag = TAG_STRING, codec = String.string,    size = nil },
    Vector2 = { tag = TAG_VEC2,   codec = Vector.vec2,      size = 8 },
    Vector3 = { tag = TAG_VEC3,   codec = Vector.vec3,      size = 12 },
    Color3  = { tag = TAG_COLOR3, codec = Color.color3,     size = 3 },
    CFrame  = { tag = TAG_CFRAME, codec = CFrameCodec.cframe, size = 24 },
    buffer  = { tag = TAG_BUFFER, codec = Buffer.buff,      size = nil },
})

-- Size of the wire encoding for each numeric tag (excludes the 1-byte tag)
local NUM_SIZE = table.freeze({
    [TAG_U8]  = 1,
    [TAG_U16] = 2,
    [TAG_U32] = 4,
    [TAG_I8]  = 1,
    [TAG_I16] = 2,
    [TAG_I32] = 4,
    [TAG_F32] = 4,
    [TAG_F64] = 8,
})

-- Private ----------------------------------------------------------------

local _f32Temp = buffer.create(4)

local function selectNumberTag(value: number): number
    if value ~= value then return TAG_F64 end

    if value == floor(value) then
        if value >= 0 then
            if value <= 255 then return TAG_U8 end
            if value <= 65535 then return TAG_U16 end
            if value <= 4294967295 then return TAG_U32 end
        else
            if value >= -128 and value <= 127 then return TAG_I8 end
            if value >= -32768 and value <= 32767 then return TAG_I16 end
            if value >= -2147483648 and value <= 2147483647 then return TAG_I32 end
        end
        return TAG_F64
    end

    buffer.writef32(_f32Temp, 0, value)
    if buffer.readf32(_f32Temp, 0) == value then return TAG_F32 end

    return TAG_F64
end

-- Public -----------------------------------------------------------------

local Special = {}

Special.nothing = table.freeze({
    write = function(_ch: ChannelState, _value: any): () end,
    read = function(_src: buffer, _pos: number, _refs: { Instance }?): (any, number)
        return nil, 0
    end,
})

--[[
    Escape hatch: passes value through the Roblox remote argument sidecar
    instead of binary-serializing it. Bypasses bandwidth control entirely.
    Use only when no typed codec exists for the value.
]]
Special.unknown = table.freeze({
    write = function(ch: ChannelState, value: any): ()
        local refs = ch.refs
        local idx  = #refs + 1
        if idx > 65535 then error(`[Lync] Unknown ref overflow: {idx} exceeds u16 max`) end

        refs[idx] = value

        Channel.alloc(ch, 2)
        buffer.writeu16(ch.buff, ch.cursor, idx)
        ch.cursor += 2
    end,
    read = function(src: buffer, pos: number, refs: { Instance }?): (any, number)
        local idx = buffer.readu16(src, pos)
        return if refs then refs[idx] else nil, 2
    end,
})

Special.auto = table.freeze({
    write = function(ch: ChannelState, value: any): ()
        if value == nil then
            Channel.alloc(ch, 1)
            buffer.writeu8(ch.buff, ch.cursor, TAG_NIL)
            ch.cursor += 1
            return
        end

        -- type() is cheaper than typeof() for primitives/tables.
        -- typeof() only needed for userdata (Vector2, Vector3, etc).
        local t = type(value)

        if t == "number" then
            local tag  = selectNumberTag(value)
            local size = NUM_SIZE[tag]

            -- Single alloc: 1 byte tag + N bytes payload
            Channel.alloc(ch, 1 + size)
            buffer.writeu8(ch.buff, ch.cursor, tag)
            ch.cursor += 1
            READ_DISPATCH[tag].write(ch, value)
            return
        end

        if t == "string" then
            Channel.alloc(ch, 1)
            buffer.writeu8(ch.buff, ch.cursor, TAG_STRING)
            ch.cursor += 1
            String.string.write(ch, value)
            return
        end

        if t == "boolean" then
            Channel.alloc(ch, 2)
            buffer.writeu8(ch.buff, ch.cursor, TAG_BOOL)
            ch.cursor += 1
            Primitive.bool.write(ch, value)
            return
        end

        -- Userdata / vector types — need typeof()
        local ut    = typeof(value)
        local entry = TYPE_DISPATCH[ut]
        if not entry then error(`[Lync] auto: unsupported type {ut}`) end

        local size = entry.size
        if size then
            Channel.alloc(ch, 1 + size)
        else
            Channel.alloc(ch, 1)
        end

        buffer.writeu8(ch.buff, ch.cursor, entry.tag)
        ch.cursor += 1
        entry.codec.write(ch, value)
    end,
    read = function(src: buffer, pos: number, refs: { Instance }?): (any, number)
        local tag = buffer.readu8(src, pos)
        if tag == TAG_NIL then return nil, 1 end

        local codec = READ_DISPATCH[tag]
        if not codec then error(`[Lync] auto: unknown tag {tag}`) end

        local value, n = codec.read(src, pos + 1, refs)
        return value, 1 + n
    end,
})

return table.freeze(Special)
