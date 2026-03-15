--!strict
--!optimize 2
-- Special.luau — Nothing, unknown, and auto (self-describing) codecs.

local CFrameCodec = require (script.Parent.CFrame)
local Channel = require (script.Parent.Parent.core.Channel)
local Color = require (script.Parent.Color)
local Primitive = require (script.Parent.Primitive)
local String = require (script.Parent.String)
local Types = require (script.Parent.Parent.Types)
local Vector = require (script.Parent.Vector)

type ChannelState = Types.ChannelState
type Codec<T> = Types.Codec<T>

-- Constants --------------------------------------------------------------

local TAG_NIL = 0
local TAG_BOOL = 1
local TAG_U8 = 2
local TAG_U16 = 3
local TAG_U32 = 4
local TAG_I8 = 5
local TAG_I16 = 6
local TAG_I32 = 7
local TAG_F32 = 8
local TAG_F64 = 9
local TAG_STRING = 10
local TAG_VEC2 = 11
local TAG_VEC3 = 12
local TAG_COLOR3 = 13
local TAG_CFRAME = 14

local floor = math.floor

local READ_DISPATCH = table.freeze ({
    [TAG_BOOL] = Primitive.bool,
    [TAG_U8] = Primitive.u8,
    [TAG_U16] = Primitive.u16,
    [TAG_U32] = Primitive.u32,
    [TAG_I8] = Primitive.i8,
    [TAG_I16] = Primitive.i16,
    [TAG_I32] = Primitive.i32,
    [TAG_F32] = Primitive.f32,
    [TAG_F64] = Primitive.f64,
    [TAG_STRING] = String.string,
    [TAG_VEC2] = Vector.vec2,
    [TAG_VEC3] = Vector.vec3,
    [TAG_COLOR3] = Color.color3,
    [TAG_CFRAME] = CFrameCodec.cframe,
})

local TYPE_DISPATCH = table.freeze ({
    boolean = { tag = TAG_BOOL, codec = Primitive.bool },
    string = { tag = TAG_STRING, codec = String.string },
    Vector2 = { tag = TAG_VEC2, codec = Vector.vec2 },
    Vector3 = { tag = TAG_VEC3, codec = Vector.vec3 },
    Color3 = { tag = TAG_COLOR3, codec = Color.color3 },
    CFrame = { tag = TAG_CFRAME, codec = CFrameCodec.cframe },
})

local NUM_CODECS = table.freeze ({
    [TAG_U8] = Primitive.u8,
    [TAG_U16] = Primitive.u16,
    [TAG_U32] = Primitive.u32,
    [TAG_I8] = Primitive.i8,
    [TAG_I16] = Primitive.i16,
    [TAG_I32] = Primitive.i32,
    [TAG_F32] = Primitive.f32,
    [TAG_F64] = Primitive.f64,
})

-- Private ----------------------------------------------------------------

-- Hoisted f32 round-trip buffer — one allocation, reused forever
local _f32Temp = buffer.create (4)

local function selectNumberTag (value: number): number
    if value ~= value then
        return TAG_F64
    end

    if value == floor (value) then
        if value >= 0 then
            if value <= 255 then
                return TAG_U8
            end
            if value <= 65535 then
                return TAG_U16
            end
            if value <= 4294967295 then
                return TAG_U32
            end
        else
            if value >= -128 and value <= 127 then
                return TAG_I8
            end
            if value >= -32768 and value <= 32767 then
                return TAG_I16
            end
            if value >= -2147483648 and value <= 2147483647 then
                return TAG_I32
            end
        end
        return TAG_F64
    end

    buffer.writef32 (_f32Temp, 0, value)
    if buffer.readf32 (_f32Temp, 0) == value then
        return TAG_F32
    end

    return TAG_F64
end

local function writeTag (ch: ChannelState, tag: number): ()
    Channel.alloc (ch, 1)
    buffer.writeu8 (ch.buff, ch.cursor, tag)
    ch.cursor += 1
end

-- Public -----------------------------------------------------------------

local Special = {}

Special.nothing = table.freeze ({
    write = function (_ch: ChannelState, _value: any): () end,
    read = function (_src: buffer, _pos: number, _refs: { Instance }?): (any, number)
        return nil, 0
    end,
})

Special.unknown = table.freeze ({
    write = function (ch: ChannelState, value: any): ()
        local refs = ch.refs
        local idx = #refs + 1
        refs[idx] = value
        if idx > 65535 then
            error (`[Lync] Unknown ref overflow: {idx} exceeds u16 max`)
        end

        Channel.alloc (ch, 2)
        buffer.writeu16 (ch.buff, ch.cursor, idx)
        ch.cursor += 2
    end,
    read = function (src: buffer, pos: number, refs: { Instance }?): (any, number)
        local idx = buffer.readu16 (src, pos)
        return if refs then refs[idx] else nil, 2
    end,
})

Special.auto = table.freeze ({
    write = function (ch: ChannelState, value: any): ()
        if value == nil then
            writeTag (ch, TAG_NIL)
            return
        end

        local t = typeof (value)

        if t == "number" then
            local tag = selectNumberTag (value)
            writeTag (ch, tag)
            NUM_CODECS[tag].write (ch, value)
            return
        end

        local entry = TYPE_DISPATCH[t]
        if not entry then
            error (`[Lync] auto: unsupported type {t}`)
        end

        writeTag (ch, entry.tag)
        entry.codec.write (ch, value)
    end,
    read = function (src: buffer, pos: number, refs: { Instance }?): (any, number)
        local tag = buffer.readu8 (src, pos)
        if tag == TAG_NIL then
            return nil, 1
        end

        local codec = READ_DISPATCH[tag]
        if not codec then
            error (`[Lync] auto: unknown tag {tag}`)
        end

        local value, n = codec.read (src, pos + 1, refs)
        return value, 1 + n
    end,
})

return table.freeze (Special)
