--!strict
--!native
-- Self-describing codec. u8 type tag + value payload.

local Base = require(script.Parent.Parent.Base)
local BufferC = require(script.Parent.Parent.datatype.Buffer)
local CFrameC = require(script.Parent.Parent.datatype.CFrame)
local Channel = require(script.Parent.Parent.Parent.internal.Channel)
local ColorC = require(script.Parent.Parent.datatype.Color)
local IVC = require(script.Parent.Parent.datatype.IntVector)
local Log = require(script.Parent.Parent.Parent.util.Log)
local NRC = require(script.Parent.Parent.datatype.NumberRange)
local NumberC = require(script.Parent.Parent.primitive.Number)
local RayC = require(script.Parent.Parent.datatype.Ray)
local RectC = require(script.Parent.Parent.datatype.Rect)
local RegionC = require(script.Parent.Parent.datatype.Region)
local SeqC = require(script.Parent.Parent.datatype.Sequence)
local Signed = require(script.Parent.Parent.primitive.Signed)
local Types = require(script.Parent.Parent.Parent.Types)
local UDimC = require(script.Parent.Parent.datatype.UDim)
local Varint = require(script.Parent.Parent.primitive.Varint)
local VecC = require(script.Parent.Parent.datatype.Vector)

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
local TAG_NUMRANGE = 18
local TAG_RECT = 19
local TAG_V2I16 = 20
local TAG_V3I16 = 21
local TAG_REGION3 = 22
local TAG_R3I16 = 23
local TAG_RAY = 24
local TAG_NUMSEQ = 25
local TAG_COLSEQ = 26

local INLINE_MAX = Varint.INLINE_MAX
local F32_SCRATCH = NumberC._f32Scratch

-- Tag -> numeric primitive dispatch tables.
local NUM_SIZE: { [number]: number } = table.freeze({
    [TAG_U8] = 1,
    [TAG_I8] = 1,
    [TAG_U16] = 2,
    [TAG_I16] = 2,
    [TAG_U32] = 4,
    [TAG_I32] = 4,
    [TAG_F32] = 4,
    [TAG_F64] = 8,
})

local NUM_WRITE: { [number]: (buffer, number, number) -> () } = table.freeze({
    [TAG_U8] = buffer.writeu8,
    [TAG_U16] = buffer.writeu16,
    [TAG_U32] = buffer.writeu32,
    [TAG_I8] = Signed.writeI8,
    [TAG_I16] = Signed.writeI16,
    [TAG_I32] = Signed.writeI32,
    [TAG_F32] = buffer.writef32,
    [TAG_F64] = buffer.writef64,
})

local NUM_READ: { [number]: (buffer, number) -> number } = table.freeze({
    [TAG_U8] = buffer.readu8,
    [TAG_U16] = buffer.readu16,
    [TAG_U32] = buffer.readu32,
    [TAG_I8] = buffer.readi8,
    [TAG_I16] = buffer.readi16,
    [TAG_I32] = buffer.readi32,
    [TAG_F32] = buffer.readf32,
    [TAG_F64] = buffer.readf64,
})

type TypeEntry = { tag: number, codec: Types.InternalCodec<any> }

local TYPE_DISPATCH: { [string]: TypeEntry } = table.freeze({
    Vector2 = { tag = TAG_VEC2, codec = VecC.vec2 },
    Vector3 = { tag = TAG_VEC3, codec = VecC.vec3 },
    Color3 = { tag = TAG_COLOR3, codec = ColorC.color3 },
    CFrame = { tag = TAG_CFRAME, codec = CFrameC.cframe },
    UDim = { tag = TAG_UDIM, codec = UDimC.udim },
    UDim2 = { tag = TAG_UDIM2, codec = UDimC.udim2 },
    NumberRange = { tag = TAG_NUMRANGE, codec = NRC.numberRange },
    Rect = { tag = TAG_RECT, codec = RectC.rect },
    Vector2int16 = { tag = TAG_V2I16, codec = IVC.vec2int16 },
    Vector3int16 = { tag = TAG_V3I16, codec = IVC.vec3int16 },
    Region3 = { tag = TAG_REGION3, codec = RegionC.region3 },
    Region3int16 = { tag = TAG_R3I16, codec = RegionC.region3int16 },
    Ray = { tag = TAG_RAY, codec = RayC.ray },
    NumberSequence = { tag = TAG_NUMSEQ, codec = SeqC.numberSequence },
    ColorSequence = { tag = TAG_COLSEQ, codec = SeqC.colorSequence },
})

local READ_DISPATCH: { [number]: Types.InternalCodec<any> } = table.freeze({
    [TAG_VEC2] = VecC.vec2,
    [TAG_VEC3] = VecC.vec3,
    [TAG_COLOR3] = ColorC.color3,
    [TAG_CFRAME] = CFrameC.cframe,
    [TAG_UDIM] = UDimC.udim,
    [TAG_UDIM2] = UDimC.udim2,
    [TAG_NUMRANGE] = NRC.numberRange,
    [TAG_RECT] = RectC.rect,
    [TAG_V2I16] = IVC.vec2int16,
    [TAG_V3I16] = IVC.vec3int16,
    [TAG_REGION3] = RegionC.region3,
    [TAG_R3I16] = RegionC.region3int16,
    [TAG_RAY] = RayC.ray,
    [TAG_NUMSEQ] = SeqC.numberSequence,
    [TAG_COLSEQ] = SeqC.colorSequence,
})

-- Private ----------------------------------------------------------------

local alloc = Base.alloc
local writeByte = Channel.writeByte
local writeu8 = buffer.writeu8
local readu8 = buffer.readu8
local floor = math.floor
local isnan = math.isnan

--[[
    Pick the narrowest tag for a number. NaN forces F64 (no integer or F32
    can represent it). Integers walk u8 -> u16 -> u32 / i8 -> i16 -> i32; non-
    integers try f32 by round-tripping through scratch (see Number.luau) and
    fall through to f64 if precision is lost.
]]
local function selectNumberTag(value: number): number
    if isnan(value) then
        return TAG_F64
    end

    if floor(value) == value then
        if value >= 0 then
            if value <= 0xFF then
                return TAG_U8
            end
            if value <= 0xFFFF then
                return TAG_U16
            end
            if value <= 0xFFFFFFFF then
                return TAG_U32
            end
        else
            if value >= -0x80 then
                return TAG_I8
            end
            if value >= -0x8000 then
                return TAG_I16
            end
            if value >= -0x80000000 then
                return TAG_I32
            end
        end
    end

    buffer.writef32(F32_SCRATCH, 0, value)
    if buffer.readf32(F32_SCRATCH, 0) == value then
        return TAG_F32
    end
    return TAG_F64
end

local function writeAuto(ch: Types.ChannelState, value: any): ()
    if value == nil then
        writeByte(ch, TAG_NIL)
        return
    end

    local t = typeof(value)

    if t == "boolean" then
        local cursor = ch.cursor
        if cursor + 2 > ch.size then
            alloc(ch, 2)
        end
        local b = ch.buff
        writeu8(b, cursor, TAG_BOOL)
        writeu8(b, cursor + 1, if value then 1 else 0)
        ch.cursor = cursor + 2
        return
    end

    if t == "number" then
        local tag = selectNumberTag(value)
        local size = NUM_SIZE[tag]
        local total = 1 + size
        local cursor = ch.cursor
        if cursor + total > ch.size then
            alloc(ch, total)
        end
        local b = ch.buff
        writeu8(b, cursor, tag)
        NUM_WRITE[tag](b, cursor + 1, value)
        ch.cursor = cursor + total
        return
    end

    if t == "string" then
        writeByte(ch, TAG_STRING)

        local len = #value
        local cursor = ch.cursor
        -- Inline single-byte length fast path; matches String.luau.
        if len <= INLINE_MAX then
            if cursor + 1 + len > ch.size then
                alloc(ch, 1 + len)
            end
            local b = ch.buff
            writeu8(b, cursor, len)
            if len > 0 then
                buffer.writestring(b, cursor + 1, value)
            end
            ch.cursor = cursor + 1 + len
            return
        end
        Varint.write(ch, len)
        cursor = ch.cursor
        if cursor + len > ch.size then
            alloc(ch, len)
        end
        buffer.writestring(ch.buff, cursor, value)
        ch.cursor = cursor + len
        return
    end

    if t == "buffer" then
        writeByte(ch, TAG_BUFFER)
        BufferC.buff.write(ch, value)
        return
    end

    local entry = TYPE_DISPATCH[t]
    if not entry then
        Log.error(`unsupported type "{t}"`)
    end
    local codec = entry.codec
    local size = codec._size
    local dw = codec._directWrite
    -- Fixed-size + direct writer: single alloc + tag + payload.
    if size and dw then
        local total = 1 + size
        local cursor = ch.cursor
        if cursor + total > ch.size then
            alloc(ch, total)
        end
        local b = ch.buff
        writeu8(b, cursor, entry.tag)
        dw(b, cursor + 1, value)
        ch.cursor = cursor + total
        return
    end

    writeByte(ch, entry.tag)
    codec.write(ch, value)
end

local function readAuto(src: buffer, pos: number, refs: { Instance }?): (any, number)
    local tag = readu8(src, pos)

    if tag == TAG_NIL then
        return nil, 1
    end
    if tag == TAG_BOOL then
        return readu8(src, pos + 1) ~= 0, 2
    end

    if tag >= TAG_U8 and tag <= TAG_F64 then
        return NUM_READ[tag](src, pos + 1), 1 + NUM_SIZE[tag]
    end

    if tag == TAG_STRING then
        local len, lenBytes = Varint.readLengthPrefix(src, pos + 1)
        if len == 0 then
            return "", 1 + lenBytes
        end
        return buffer.readstring(src, pos + 1 + lenBytes, len), 1 + lenBytes + len
    end

    if tag == TAG_BUFFER then
        local value, consumed = BufferC.buff.read(src, pos + 1, refs)
        return value, 1 + consumed
    end

    local codec = READ_DISPATCH[tag]
    if not codec then
        Log.error(`unknown tag {tag}`)
    end
    local value, consumed = codec.read(src, pos + 1, refs)
    return value, 1 + consumed
end

-- Public -----------------------------------------------------------------

local AutoModule = {}

AutoModule.auto = table.freeze({
    write = writeAuto,
    read = readAuto,
})

return table.freeze(AutoModule)
