--!strict
--!native
-- Self-describing codec. u8 type tag + value payload.

local Base = require(script.Parent.Parent.Base)
local BufferC = require(script.Parent.Parent.datatype.Buffer)
local CFrameC = require(script.Parent.Parent.datatype.CFrame)
local Channel = require(script.Parent.Parent.Parent.internal.Channel)
local ColorC = require(script.Parent.Parent.datatype.Color)
local IVC = require(script.Parent.Parent.datatype.IntVector)
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

-- Private ----------------------------------------------------------------

local alloc = Base.alloc
local writeByte = Channel.writeByte
local writeu8 = buffer.writeu8
local readu8 = buffer.readu8
local floor = math.floor
local isnan = math.isnan

local writeI8 = Signed.writeI8
local writeI16 = Signed.writeI16
local writeI32 = Signed.writeI32

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

    -- Roblox is single-threaded so a module scratch cannot be aliased.
    buffer.writef32(F32_SCRATCH, 0, value)
    if buffer.readf32(F32_SCRATCH, 0) == value then
        return TAG_F32
    end
    return TAG_F64
end

local function numberSize(tag: number): number
    if tag == TAG_U8 or tag == TAG_I8 then
        return 1
    end
    if tag == TAG_U16 or tag == TAG_I16 then
        return 2
    end
    if tag == TAG_U32 or tag == TAG_I32 or tag == TAG_F32 then
        return 4
    end
    return 8
end

local function writeNumber(b: buffer, off: number, tag: number, value: number): ()
    if tag == TAG_U8 then
        buffer.writeu8(b, off, value)
        return
    end
    if tag == TAG_U16 then
        buffer.writeu16(b, off, value)
        return
    end
    if tag == TAG_U32 then
        buffer.writeu32(b, off, value)
        return
    end
    if tag == TAG_I8 then
        writeI8(b, off, value)
        return
    end
    if tag == TAG_I16 then
        writeI16(b, off, value)
        return
    end
    if tag == TAG_I32 then
        writeI32(b, off, value)
        return
    end
    if tag == TAG_F32 then
        buffer.writef32(b, off, value)
        return
    end
    buffer.writef64(b, off, value)
end

local function readNumber(b: buffer, off: number, tag: number): number
    if tag == TAG_U8 then
        return buffer.readu8(b, off)
    end
    if tag == TAG_U16 then
        return buffer.readu16(b, off)
    end
    if tag == TAG_U32 then
        return buffer.readu32(b, off)
    end
    if tag == TAG_I8 then
        return buffer.readi8(b, off)
    end
    if tag == TAG_I16 then
        return buffer.readi16(b, off)
    end
    if tag == TAG_I32 then
        return buffer.readi32(b, off)
    end
    if tag == TAG_F32 then
        return buffer.readf32(b, off)
    end
    return buffer.readf64(b, off)
end

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
        local totalSize = 1 + numberSize(tag)
        local cursor = ch.cursor
        if cursor + totalSize > ch.size then
            alloc(ch, totalSize)
        end
        local b = ch.buff
        writeu8(b, cursor, tag)
        writeNumber(b, cursor + 1, tag, value)
        ch.cursor = cursor + totalSize
        return
    end

    if t == "string" then
        writeByte(ch, TAG_STRING)

        local len = #value
        local cursor = ch.cursor
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
        error(`[Lync] Auto.write: unsupported type "{t}"`)
    end

    local codec = entry.codec
    local size = codec._size
    local dw = codec._directWrite
    if size and dw then
        local totalSize = 1 + size
        local cursor = ch.cursor
        if cursor + totalSize > ch.size then
            alloc(ch, totalSize)
        end
        local b = ch.buff
        writeu8(b, cursor, entry.tag)
        dw(b, cursor + 1, value)
        ch.cursor = cursor + totalSize
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
        return readNumber(src, pos + 1, tag), 1 + numberSize(tag)
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
        error(`[Lync] Auto.read: unknown tag {tag}`)
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
