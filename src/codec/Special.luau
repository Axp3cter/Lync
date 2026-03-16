--!strict
--!native
-- Nothing, unknown, and auto (self-describing) codecs.

local Buffer = require (script.Parent.Buffer)
local CFrameCodec = require (script.Parent.CFrame)
local Channel = require (script.Parent.Parent.core.Channel)
local alloc = Channel.alloc
local Color = require (script.Parent.Color)
local Primitive = require (script.Parent.Primitive)
local String = require (script.Parent.String)
local Types = require (script.Parent.Parent.Types)
local Varint = require (script.Parent.Varint)
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
local TAG_BUFFER = 15

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
    [TAG_BUFFER] = Buffer.buff,
})

local TYPE_DISPATCH = table.freeze ({
    boolean = { tag = TAG_BOOL, codec = Primitive.bool, size = 1, dw = nil },
    string = { tag = TAG_STRING, codec = String.string, size = nil, dw = nil },
    Vector2 = {
        tag = TAG_VEC2,
        codec = Vector.vec2,
        size = 8,
        dw = (Vector.vec2 :: any)._directWrite,
    },
    Vector3 = {
        tag = TAG_VEC3,
        codec = Vector.vec3,
        size = 12,
        dw = (Vector.vec3 :: any)._directWrite,
    },
    Color3 = {
        tag = TAG_COLOR3,
        codec = Color.color3,
        size = 3,
        dw = (Color.color3 :: any)._directWrite,
    },
    CFrame = {
        tag = TAG_CFRAME,
        codec = CFrameCodec.cframe,
        size = 24,
        dw = (CFrameCodec.cframe :: any)._directWrite,
    },
    buffer = { tag = TAG_BUFFER, codec = Buffer.buff, size = nil, dw = nil },
})

-- Numeric write dispatch: one lookup for both codec and payload size.
local NUM_SIZES = {} :: { [number]: number }
local NUM_DWRITES = {} :: { [number]: any }

for _, pair in
    {
        { TAG_U8, Primitive.u8, 1 },
        { TAG_U16, Primitive.u16, 2 },
        { TAG_U32, Primitive.u32, 4 },
        { TAG_I8, Primitive.i8, 1 },
        { TAG_I16, Primitive.i16, 2 },
        { TAG_I32, Primitive.i32, 4 },
        { TAG_F32, Primitive.f32, 4 },
        { TAG_F64, Primitive.f64, 8 },
    }
do
    NUM_SIZES[pair[1]] = pair[3]
    NUM_DWRITES[pair[1]] = (pair[2] :: any)._directWrite
end

table.freeze (NUM_SIZES)
table.freeze (NUM_DWRITES)

-- Private ----------------------------------------------------------------

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

-- Public -----------------------------------------------------------------

local Special = {}

Special.nothing = table.freeze ({
    _size = 0,
    _directWrite = function (_b: buffer, _offset: number, _value: any): () end,
    _directRead = function (_b: buffer, _offset: number): any
        return nil
    end,
    write = function (_ch: ChannelState, _value: any): () end,
    read = function (_src: buffer, _pos: number, _refs: { Instance }?): (any, number)
        return nil, 0
    end,
})

-- Passes value through the Roblox remote argument sidecar instead of
-- binary-serializing it. Use when no typed codec exists for the value.
Special.unknown = table.freeze ({
    write = function (ch: ChannelState, value: any): ()
        local refs = ch.refs
        local idx = #refs + 1
        if idx > 65535 then
            error (`[Lync] Unknown ref overflow: {idx} exceeds u16 max`)
        end

        refs[idx] = value

        local c = ch.cursor
        if c + 2 > ch.size then
            alloc (ch, 2)
        end
        buffer.writeu16 (ch.buff, c, idx)
        ch.cursor = c + 2
    end,
    read = function (src: buffer, pos: number, refs: { Instance }?): (any, number)
        local idx = buffer.readu16 (src, pos)
        return if refs then refs[idx] else nil, 2
    end,
})

Special.auto = table.freeze ({
    write = function (ch: ChannelState, value: any): ()
        if value == nil then
            local c = ch.cursor
            if c + 1 > ch.size then
                alloc (ch, 1)
            end
            buffer.writeu8 (ch.buff, c, TAG_NIL)
            ch.cursor = c + 1
            return
        end

        local t = type (value)

        if t == "number" then
            local tag = selectNumberTag (value)
            local payloadSize = NUM_SIZES[tag]
            local totalSize = 1 + payloadSize

            local c = ch.cursor
            if c + totalSize > ch.size then
                alloc (ch, totalSize)
            end
            local b = ch.buff
            buffer.writeu8 (b, c, tag)
            NUM_DWRITES[tag] (b, c + 1, value)
            ch.cursor = c + totalSize
            return
        end

        if t == "string" then
            local len = #value
            local total = 6 + len
            local c = ch.cursor
            if c + total > ch.size then
                alloc (ch, total)
            end
            buffer.writeu8 (ch.buff, c, TAG_STRING)
            ch.cursor = c + 1
            Varint.write (ch, len)
            local c2 = ch.cursor
            buffer.writestring (ch.buff, c2, value)
            ch.cursor = c2 + len
            return
        end

        if t == "boolean" then
            local c = ch.cursor
            if c + 2 > ch.size then
                alloc (ch, 2)
            end
            local b = ch.buff
            buffer.writeu8 (b, c, TAG_BOOL)
            buffer.writeu8 (b, c + 1, if value then 1 else 0)
            ch.cursor = c + 2
            return
        end

        local ut = typeof (value)
        local entry = TYPE_DISPATCH[ut]
        if not entry then
            error (`[Lync] Auto unsupported type: {ut}`)
        end

        local dw = entry.dw
        local size = entry.size
        if dw and size then
            local totalSize = 1 + size
            local c = ch.cursor
            if c + totalSize > ch.size then
                alloc (ch, totalSize)
            end
            local b = ch.buff
            buffer.writeu8 (b, c, entry.tag)
            dw (b, c + 1, value)
            ch.cursor = c + totalSize
        else
            local c = ch.cursor
            if c + 1 > ch.size then
                alloc (ch, 1)
            end
            buffer.writeu8 (ch.buff, c, entry.tag)
            ch.cursor = c + 1
            entry.codec.write (ch, value)
        end
    end,
    read = function (src: buffer, pos: number, refs: { Instance }?): (any, number)
        local tag = buffer.readu8 (src, pos)
        if tag == TAG_NIL then
            return nil, 1
        end

        local codec = READ_DISPATCH[tag]
        if not codec then
            error (`[Lync] Auto unknown tag: {tag}`)
        end

        local value, n = codec.read (src, pos + 1, refs)
        return value, 1 + n
    end,
})

return table.freeze (Special)
