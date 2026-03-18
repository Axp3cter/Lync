--!strict
--!native
-- Auto(self-describing) codec. Writes a u8 type tag then the value.

local BoolCodec = require(script.Parent.Parent.primitive.Bool)
local BufferCodec = require(script.Parent.Parent.datatype.Buffer)
local CFrameCodec = require(script.Parent.Parent.datatype.CFrame)
local Channel = require(script.Parent.Parent.Parent.internal.Channel)
local ColorCodec = require(script.Parent.Parent.datatype.Color)
local IntVectorCodec = require(script.Parent.Parent.datatype.IntVector)
local NumberCodec = require(script.Parent.Parent.primitive.Number)
local NumberRangeCodec = require(script.Parent.Parent.datatype.NumberRange)
local RayCodec = require(script.Parent.Parent.datatype.Ray)
local RectCodec = require(script.Parent.Parent.datatype.Rect)
local RegionCodec = require(script.Parent.Parent.datatype.Region)
local SequenceCodec = require(script.Parent.Parent.datatype.Sequence)
local StringCodec = require(script.Parent.Parent.datatype.String)
local Types = require(script.Parent.Parent.Parent.Types)
local UDimCodec = require(script.Parent.Parent.datatype.UDim)
local Varint = require(script.Parent.Parent.primitive.Varint)
local VectorCodec = require(script.Parent.Parent.datatype.Vector)

type ChannelState = Types.ChannelState
type Codec<T> = Types.Codec<T>
type InternalCodec<T> = Types.InternalCodec<T>

local alloc = Channel.alloc
local floor = math.floor

-- Constants -----------------------------------------------------------

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

local READ_DISPATCH = table.freeze({
    [TAG_BOOL] = BoolCodec.bool,
    [TAG_U8] = NumberCodec.u8,
    [TAG_U16] = NumberCodec.u16,
    [TAG_U32] = NumberCodec.u32,
    [TAG_I8] = NumberCodec.i8,
    [TAG_I16] = NumberCodec.i16,
    [TAG_I32] = NumberCodec.i32,
    [TAG_F32] = NumberCodec.f32,
    [TAG_F64] = NumberCodec.f64,
    [TAG_STRING] = StringCodec.string,
    [TAG_VEC2] = VectorCodec.vec2,
    [TAG_VEC3] = VectorCodec.vec3,
    [TAG_COLOR3] = ColorCodec.color3,
    [TAG_CFRAME] = CFrameCodec.cframe,
    [TAG_BUFFER] = BufferCodec.buff,
    [TAG_UDIM] = UDimCodec.udim,
    [TAG_UDIM2] = UDimCodec.udim2,
    [TAG_NUMBERRANGE] = NumberRangeCodec.numberRange,
    [TAG_RECT] = RectCodec.rect,
    [TAG_VEC2INT16] = IntVectorCodec.vec2int16,
    [TAG_VEC3INT16] = IntVectorCodec.vec3int16,
    [TAG_REGION3] = RegionCodec.region3,
    [TAG_REGION3INT16] = RegionCodec.region3int16,
    [TAG_RAY] = RayCodec.ray,
    [TAG_NUMBERSEQUENCE] = SequenceCodec.numberSequence,
    [TAG_COLORSEQUENCE] = SequenceCodec.colorSequence,
})

local function extractDw(codec: any): any
    return (codec :: InternalCodec<any>)._directWrite
end

local TYPE_DISPATCH = table.freeze({
    boolean = { tag = TAG_BOOL, codec = BoolCodec.bool, size = 1, dw = nil },
    string = { tag = TAG_STRING, codec = StringCodec.string, size = nil, dw = nil },
    buffer = { tag = TAG_BUFFER, codec = BufferCodec.buff, size = nil, dw = nil },
    Vector2 = {
        tag = TAG_VEC2,
        codec = VectorCodec.vec2,
        size = 8,
        dw = extractDw(VectorCodec.vec2),
    },
    Vector3 = {
        tag = TAG_VEC3,
        codec = VectorCodec.vec3,
        size = 12,
        dw = extractDw(VectorCodec.vec3),
    },
    Color3 = {
        tag = TAG_COLOR3,
        codec = ColorCodec.color3,
        size = 3,
        dw = extractDw(ColorCodec.color3),
    },
    CFrame = {
        tag = TAG_CFRAME,
        codec = CFrameCodec.cframe,
        size = 24,
        dw = extractDw(CFrameCodec.cframe),
    },
    UDim = {
        tag = TAG_UDIM,
        codec = UDimCodec.udim,
        size = 8,
        dw = extractDw(UDimCodec.udim),
    },
    UDim2 = {
        tag = TAG_UDIM2,
        codec = UDimCodec.udim2,
        size = 16,
        dw = extractDw(UDimCodec.udim2),
    },
    NumberRange = {
        tag = TAG_NUMBERRANGE,
        codec = NumberRangeCodec.numberRange,
        size = 8,
        dw = extractDw(NumberRangeCodec.numberRange),
    },
    Rect = {
        tag = TAG_RECT,
        codec = RectCodec.rect,
        size = 16,
        dw = extractDw(RectCodec.rect),
    },
    Vector2int16 = {
        tag = TAG_VEC2INT16,
        codec = IntVectorCodec.vec2int16,
        size = 4,
        dw = extractDw(IntVectorCodec.vec2int16),
    },
    Vector3int16 = {
        tag = TAG_VEC3INT16,
        codec = IntVectorCodec.vec3int16,
        size = 6,
        dw = extractDw(IntVectorCodec.vec3int16),
    },
    Region3 = {
        tag = TAG_REGION3,
        codec = RegionCodec.region3,
        size = 24,
        dw = extractDw(RegionCodec.region3),
    },
    Region3int16 = {
        tag = TAG_REGION3INT16,
        codec = RegionCodec.region3int16,
        size = 12,
        dw = extractDw(RegionCodec.region3int16),
    },
    Ray = {
        tag = TAG_RAY,
        codec = RayCodec.ray,
        size = 24,
        dw = extractDw(RayCodec.ray),
    },
    NumberSequence = {
        tag = TAG_NUMBERSEQUENCE,
        codec = SequenceCodec.numberSequence,
        size = nil,
        dw = nil,
    },
    ColorSequence = {
        tag = TAG_COLORSEQUENCE,
        codec = SequenceCodec.colorSequence,
        size = nil,
        dw = nil,
    },
})

-- Numeric write dispatch: one lookup for both codec and payload size.
local NUM_SIZES = {} :: { [number]: number }
local NUM_DWRITES = {} :: { [number]: any }

for _, pair in
    {
        { TAG_U8, NumberCodec.u8, 1 },
        { TAG_U16, NumberCodec.u16, 2 },
        { TAG_U32, NumberCodec.u32, 4 },
        { TAG_I8, NumberCodec.i8, 1 },
        { TAG_I16, NumberCodec.i16, 2 },
        { TAG_I32, NumberCodec.i32, 4 },
        { TAG_F32, NumberCodec.f32, 4 },
        { TAG_F64, NumberCodec.f64, 8 },
    }
do
    NUM_SIZES[pair[1]] = pair[3]
    NUM_DWRITES[pair[1]] = (pair[2] :: InternalCodec<number>)._directWrite
end

table.freeze(NUM_SIZES)
table.freeze(NUM_DWRITES)

-- Private -------------------------------------------------------------

local _f32Temp = buffer.create(4)

local function selectNumberTag(value: number): number
    if value ~= value then
        return TAG_F64
    end

    if value == floor(value) then
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

    buffer.writef32(_f32Temp, 0, value)
    if buffer.readf32(_f32Temp, 0) == value then
        return TAG_F32
    end

    return TAG_F64
end

-- Public --------------------------------------------------------------

local auto = table.freeze({
    write = function(ch: ChannelState, value: any): ()
        if value == nil then
            local c = ch.cursor
            if c + 1 > ch.size then
                alloc(ch, 1)
            end
            buffer.writeu8(ch.buff, c, TAG_NIL)
            ch.cursor = c + 1
            return
        end

        local t = type(value)

        if t == "number" then
            local tag = selectNumberTag(value)
            local payloadSize = NUM_SIZES[tag]
            local totalSize = 1 + payloadSize

            local c = ch.cursor
            if c + totalSize > ch.size then
                alloc(ch, totalSize)
            end
            local b = ch.buff
            buffer.writeu8(b, c, tag)
            NUM_DWRITES[tag](b, c + 1, value)
            ch.cursor = c + totalSize
            return
        end

        if t == "string" then
            local len = #value
            local total = 6 + len
            local c = ch.cursor
            if c + total > ch.size then
                alloc(ch, total)
            end
            buffer.writeu8(ch.buff, c, TAG_STRING)
            ch.cursor = c + 1
            Varint.write(ch, len)
            local c2 = ch.cursor
            buffer.writestring(ch.buff, c2, value)
            ch.cursor = c2 + len
            return
        end

        if t == "boolean" then
            local c = ch.cursor
            if c + 2 > ch.size then
                alloc(ch, 2)
            end
            local b = ch.buff
            buffer.writeu8(b, c, TAG_BOOL)
            buffer.writeu8(b, c + 1, if value then 1 else 0)
            ch.cursor = c + 2
            return
        end

        local valueType = typeof(value)
        local entry = TYPE_DISPATCH[valueType]
        if not entry then
            error(`[Lync] Auto unsupported type: {valueType}`)
        end

        local entryDw = entry.dw
        local entrySize = entry.size
        if entryDw and entrySize then
            local totalSize = 1 + entrySize
            local c = ch.cursor
            if c + totalSize > ch.size then
                alloc(ch, totalSize)
            end
            local b = ch.buff
            buffer.writeu8(b, c, entry.tag)
            entryDw(b, c + 1, value)
            ch.cursor = c + totalSize
        else
            local c = ch.cursor
            if c + 1 > ch.size then
                alloc(ch, 1)
            end
            buffer.writeu8(ch.buff, c, entry.tag)
            ch.cursor = c + 1
            entry.codec.write(ch, value)
        end
    end,
    read = function(src: buffer, pos: number, refs: { Instance }?): (any, number)
        local tag = buffer.readu8(src, pos)
        if tag == TAG_NIL then
            return nil, 1
        end

        local codec = READ_DISPATCH[tag]
        if not codec then
            error(`[Lync] Auto unknown tag: {tag}`)
        end

        local value, n = codec.read(src, pos + 1, refs)
        return value, 1 + n
    end,
})

local AutoModule = {}
AutoModule.auto = auto
return table.freeze(AutoModule)
