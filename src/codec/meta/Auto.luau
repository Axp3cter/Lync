--!strict
--!native
-- Self-describing codec. u8 type tag + value payload.

local Base = require(script.Parent.Parent.Base)
local BoolC = require(script.Parent.Parent.primitive.Bool)
local BufferC = require(script.Parent.Parent.datatype.Buffer)
local CFrameC = require(script.Parent.Parent.datatype.CFrame)
local ColorC = require(script.Parent.Parent.datatype.Color)
local Float16C = require(script.Parent.Parent.primitive.Float16)
local IVC = require(script.Parent.Parent.datatype.IntVector)
local NRC = require(script.Parent.Parent.datatype.NumberRange)
local NumberC = require(script.Parent.Parent.primitive.Number)
local RayC = require(script.Parent.Parent.datatype.Ray)
local RectC = require(script.Parent.Parent.datatype.Rect)
local RegionC = require(script.Parent.Parent.datatype.Region)
local SeqC = require(script.Parent.Parent.datatype.Sequence)
local Types = require(script.Parent.Parent.Parent.Types)
local UDimC = require(script.Parent.Parent.datatype.UDim)
local Varint = require(script.Parent.Parent.primitive.Varint)
local VecC = require(script.Parent.Parent.datatype.Vector)

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

-- Private -------------------------------------------------------------

local alloc = Base.alloc
local writeu8 = buffer.writeu8
local readu8 = buffer.readu8
local floor = math.floor
local abs = math.abs

local F32_SCRATCH = NumberC._f32Scratch

--[[
    Write dispatch tables: tag → { directWrite, payloadSize }.
    Used for integer/float types where the codec has _directWrite + _size.
]]
local NUM_WRITE: { [number]: (buffer, number, number) -> () } = {
    [TAG_U8] = buffer.writeu8,
    [TAG_U16] = buffer.writeu16,
    [TAG_U32] = buffer.writeu32,
    [TAG_F32] = buffer.writef32,
    [TAG_F64] = buffer.writef64,
}

local NUM_SIZE: { [number]: number } = {
    [TAG_U8] = 1,
    [TAG_U16] = 2,
    [TAG_U32] = 4,
    [TAG_F32] = 4,
    [TAG_F64] = 8,
}

-- writei8/i16/i32 are NOT FASTCALL, so we use writeu* with two's complement conversion
local function writeI8(b: buffer, off: number, v: number): ()
    writeu8(b, off, if v < 0 then v + 0x100 else v)
end

local function writeI16(b: buffer, off: number, v: number): ()
    buffer.writeu16(b, off, if v < 0 then v + 0x10000 else v)
end

local function writeI32(b: buffer, off: number, v: number): ()
    buffer.writeu32(b, off, if v < 0 then v + 0x100000000 else v)
end

NUM_WRITE[TAG_I8] = writeI8
NUM_WRITE[TAG_I16] = writeI16
NUM_WRITE[TAG_I32] = writeI32
NUM_SIZE[TAG_I8] = 1
NUM_SIZE[TAG_I16] = 2
NUM_SIZE[TAG_I32] = 4

table.freeze(NUM_WRITE)
table.freeze(NUM_SIZE)

-- Selects the smallest integer/float tag for a number value
local function selectNumberTag(value: number): number
    -- NaN always f64
    if value ~= value then
        return TAG_F64
    end

    -- Integer path
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

    -- Float path: try f32 round-trip
    buffer.writef32(F32_SCRATCH, 0, value)
    if buffer.readf32(F32_SCRATCH, 0) == value then
        return TAG_F32
    end

    return TAG_F64
end

--[[
    Roblox type dispatch: typeof string → { tag, codec }.
    For types with _directWrite + _size, we use the fast path.
]]
type TypeEntry = {
    tag: number,
    codec: Types.InternalCodec<any>,
}

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
} :: any)

-- Read dispatch: tag → codec
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
} :: any)

-- Numeric read helpers
local function readI8(b: buffer, off: number): number
    local raw = readu8(b, off)
    return if raw >= 0x80 then raw - 0x100 else raw
end

local function readI16(b: buffer, off: number): number
    local raw = buffer.readu16(b, off)
    return if raw >= 0x8000 then raw - 0x10000 else raw
end

local function readI32(b: buffer, off: number): number
    local raw = buffer.readu32(b, off)
    return if raw >= 0x80000000 then raw - 0x100000000 else raw
end

local NUM_READ: { [number]: (buffer, number) -> number } = table.freeze({
    [TAG_U8] = buffer.readu8,
    [TAG_U16] = buffer.readu16,
    [TAG_U32] = buffer.readu32,
    [TAG_I8] = readI8,
    [TAG_I16] = readI16,
    [TAG_I32] = readI32,
    [TAG_F32] = buffer.readf32,
    [TAG_F64] = buffer.readf64,
})

-- Public --------------------------------------------------------------

local AutoModule = {}

AutoModule.auto = table.freeze({
    write = function(ch: Types.ChannelState, value: any): ()
        if value == nil then
            local cursor = ch.cursor
            if cursor + 1 > ch.size then
                alloc(ch, 1)
            end
            writeu8(ch.buff, cursor, TAG_NIL)
            ch.cursor = cursor + 1
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
            local payloadSize = NUM_SIZE[tag]
            local totalSize = 1 + payloadSize
            local cursor = ch.cursor
            if cursor + totalSize > ch.size then
                alloc(ch, totalSize)
            end
            local b = ch.buff
            writeu8(b, cursor, tag)
            NUM_WRITE[tag](b, cursor + 1, value)
            ch.cursor = cursor + totalSize
            return
        end

        if t == "string" then
            local cursor = ch.cursor
            if cursor + 1 > ch.size then
                alloc(ch, 1)
            end
            writeu8(ch.buff, cursor, TAG_STRING)
            ch.cursor = cursor + 1
            -- Inline string write (same as String codec)
            local len = #value
            cursor = ch.cursor
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
            else
                Varint.write(ch, len)
                cursor = ch.cursor
                if cursor + len > ch.size then
                    alloc(ch, len)
                end
                buffer.writestring(ch.buff, cursor, value)
                ch.cursor = cursor + len
            end
            return
        end

        if t == "buffer" then
            local cursor = ch.cursor
            if cursor + 1 > ch.size then
                alloc(ch, 1)
            end
            writeu8(ch.buff, cursor, TAG_BUFFER)
            ch.cursor = cursor + 1
            BufferC.buff.write(ch, value)
            return
        end

        -- Roblox type dispatch
        local entry = TYPE_DISPATCH[t]
        if entry then
            local codec = entry.codec
            local size = codec._size
            local dw = codec._directWrite

            if size and dw then
                -- Fast path: direct write
                local totalSize = 1 + size
                local cursor = ch.cursor
                if cursor + totalSize > ch.size then
                    alloc(ch, totalSize)
                end
                local b = ch.buff
                writeu8(b, cursor, entry.tag)
                dw(b, cursor + 1, value)
                ch.cursor = cursor + totalSize
            else
                -- Generic path
                local cursor = ch.cursor
                if cursor + 1 > ch.size then
                    alloc(ch, 1)
                end
                writeu8(ch.buff, cursor, entry.tag)
                ch.cursor = cursor + 1
                codec.write(ch, value)
            end
            return
        end

        error(`[Lync] Auto: unsupported type "{t}"`)
    end,

    read = function(src: buffer, pos: number, refs: { Instance }?): (any, number)
        local tag = readu8(src, pos)

        -- Nil
        if tag == TAG_NIL then
            return nil, 1
        end

        -- Bool
        if tag == TAG_BOOL then
            return readu8(src, pos + 1) ~= 0, 2
        end

        -- Numeric types (tags 2-9)
        local numRead = NUM_READ[tag]
        if numRead then
            local payloadSize = NUM_SIZE[tag]
            return numRead(src, pos + 1), 1 + payloadSize
        end

        -- String
        if tag == TAG_STRING then
            local b0 = readu8(src, pos + 1)
            local len: number
            local lenBytes: number

            if b0 <= INLINE_MAX then
                len = b0
                lenBytes = 1
            else
                len, lenBytes = Varint.read(src, pos + 1)
            end

            if len == 0 then
                return "", 1 + lenBytes
            end

            local dataStart = pos + 1 + lenBytes
            return buffer.readstring(src, dataStart, len), 1 + lenBytes + len
        end

        -- Buffer
        if tag == TAG_BUFFER then
            local value, consumed = BufferC.buff.read(src, pos + 1, refs)
            return value, 1 + consumed
        end

        -- Roblox types
        local codec = READ_DISPATCH[tag]
        if codec then
            local value, consumed = codec.read(src, pos + 1, refs)
            return value, 1 + consumed
        end

        error(`[Lync] Auto: unknown tag {tag}`)
    end,
} :: any)

return table.freeze(AutoModule)
