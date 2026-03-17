--!strict
--!native
-- Auto (self-describing) codec. Writes a u8 type tag then the value.

local Buffer = require (script.Parent.Parent.datatype.Buffer)
local CFrameCodec = require (script.Parent.Parent.datatype.CFrame)
local Channel = require (script.Parent.Parent.Parent.internal.Channel)
local alloc = Channel.alloc
local BoolCodec = require (script.Parent.Parent.primitive.Bool)
local Color = require (script.Parent.Parent.datatype.Color)
local IntVector = require (script.Parent.Parent.datatype.IntVector)
local Number = require (script.Parent.Parent.primitive.Number)
local NumberRangeCodec = require (script.Parent.Parent.datatype.NumberRange)
local RayCodec = require (script.Parent.Parent.datatype.Ray)
local RectCodec = require (script.Parent.Parent.datatype.Rect)
local Region = require (script.Parent.Parent.datatype.Region)
local Sequence = require (script.Parent.Parent.datatype.Sequence)
local String = require (script.Parent.Parent.datatype.String)
local Types = require (script.Parent.Parent.Parent.Types)
local UDimCodec = require (script.Parent.Parent.datatype.UDim)
local Varint = require (script.Parent.Parent.primitive.Varint)
local Vector = require (script.Parent.Parent.datatype.Vector)

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
local TAG_UDIM = 16
local TAG_UDIM2 = 17
local TAG_NUMBERRANGE = 18
local TAG_RECT = 19
local TAG_VEC2INT16 = 20
local TAG_VEC3INT16 = 21
local TAG_REGION3 = 22
local TAG_REGION3INT16 = 23
local TAG_RAY = 24
local TAG_NUMBERSEQUENCE = 25
local TAG_COLORSEQUENCE = 26

local floor = math.floor

local READ_DISPATCH = table.freeze ({
    [TAG_BOOL] = BoolCodec.bool,
    [TAG_U8] = Number.u8,
    [TAG_U16] = Number.u16,
    [TAG_U32] = Number.u32,
    [TAG_I8] = Number.i8,
    [TAG_I16] = Number.i16,
    [TAG_I32] = Number.i32,
    [TAG_F32] = Number.f32,
    [TAG_F64] = Number.f64,
    [TAG_STRING] = String.string,
    [TAG_VEC2] = Vector.vec2,
    [TAG_VEC3] = Vector.vec3,
    [TAG_COLOR3] = Color.color3,
    [TAG_CFRAME] = CFrameCodec.cframe,
    [TAG_BUFFER] = Buffer.buff,
    [TAG_UDIM] = UDimCodec.udim,
    [TAG_UDIM2] = UDimCodec.udim2,
    [TAG_NUMBERRANGE] = NumberRangeCodec.numberRange,
    [TAG_RECT] = RectCodec.rect,
    [TAG_VEC2INT16] = IntVector.vec2int16,
    [TAG_VEC3INT16] = IntVector.vec3int16,
    [TAG_REGION3] = Region.region3,
    [TAG_REGION3INT16] = Region.region3int16,
    [TAG_RAY] = RayCodec.ray,
    [TAG_NUMBERSEQUENCE] = Sequence.numberSequence,
    [TAG_COLORSEQUENCE] = Sequence.colorSequence,
})

local TYPE_DISPATCH = table.freeze ({
    boolean = { tag = TAG_BOOL, codec = BoolCodec.bool, size = 1, dw = nil },
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
    UDim = {
        tag = TAG_UDIM,
        codec = UDimCodec.udim,
        size = 8,
        dw = (UDimCodec.udim :: any)._directWrite,
    },
    UDim2 = {
        tag = TAG_UDIM2,
        codec = UDimCodec.udim2,
        size = 16,
        dw = (UDimCodec.udim2 :: any)._directWrite,
    },
    NumberRange = {
        tag = TAG_NUMBERRANGE,
        codec = NumberRangeCodec.numberRange,
        size = 8,
        dw = (NumberRangeCodec.numberRange :: any)._directWrite,
    },
    Rect = {
        tag = TAG_RECT,
        codec = RectCodec.rect,
        size = 16,
        dw = (RectCodec.rect :: any)._directWrite,
    },
    Vector2int16 = {
        tag = TAG_VEC2INT16,
        codec = IntVector.vec2int16,
        size = 4,
        dw = (IntVector.vec2int16 :: any)._directWrite,
    },
    Vector3int16 = {
        tag = TAG_VEC3INT16,
        codec = IntVector.vec3int16,
        size = 6,
        dw = (IntVector.vec3int16 :: any)._directWrite,
    },
    Region3 = {
        tag = TAG_REGION3,
        codec = Region.region3,
        size = 24,
        dw = (Region.region3 :: any)._directWrite,
    },
    Region3int16 = {
        tag = TAG_REGION3INT16,
        codec = Region.region3int16,
        size = 12,
        dw = (Region.region3int16 :: any)._directWrite,
    },
    Ray = {
        tag = TAG_RAY,
        codec = RayCodec.ray,
        size = 24,
        dw = (RayCodec.ray :: any)._directWrite,
    },
    NumberSequence = {
        tag = TAG_NUMBERSEQUENCE,
        codec = Sequence.numberSequence,
        size = nil,
        dw = nil,
    },
    ColorSequence = {
        tag = TAG_COLORSEQUENCE,
        codec = Sequence.colorSequence,
        size = nil,
        dw = nil,
    },
})

-- Numeric write dispatch: one lookup for both codec and payload size.
local NUM_SIZES = {} :: { [number]: number }
local NUM_DWRITES = {} :: { [number]: any }

for _, pair in
    {
        { TAG_U8, Number.u8, 1 },
        { TAG_U16, Number.u16, 2 },
        { TAG_U32, Number.u32, 4 },
        { TAG_I8, Number.i8, 1 },
        { TAG_I16, Number.i16, 2 },
        { TAG_I32, Number.i32, 4 },
        { TAG_F32, Number.f32, 4 },
        { TAG_F64, Number.f64, 8 },
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

local auto = table.freeze ({
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

        local valueType = typeof (value)
        local entry = TYPE_DISPATCH[valueType]
        if not entry then
            error (`[Lync] Auto unsupported type: {valueType}`)
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

return table.freeze ({ auto = auto })
