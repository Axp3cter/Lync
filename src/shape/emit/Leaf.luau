--!strict
--!native
--!optimize 2
-- Every value that is not a bit region, as the pair of closures that writes it and reads it back.

local Bits = require ("@src/kernel/Bits")
local Bytes = require ("@src/wire/Bytes")
local Catalog = require ("@src/kernel/Catalog")
local Ir = require ("@src/shape/Ir")
local Log = require ("@src/kernel/Log")
local Protocol = require ("@src/wire/Protocol")
local Serial = require ("@src/shape/Serial")
local Types = require ("@src/Types")
local Varint = require ("@src/wire/Varint")
local Word = require ("@src/shape/emit/Word")

local Leaf = {}

-- Constants -----------------------------------------------------------

const BYTE = Protocol.BYTE_BITS
const EXACT = Protocol.EXACT

-- The widths a whole number of bytes is read and written in, and the value one word carries.
const PAIR = 2
const TRIO = PAIR + 1
const WORD = 4
const HALF = 2 ^ 16
const HIGH = 2 ^ (WORD * BYTE)

-- The slot a reference nobody made takes, which is none, since the array it indexes starts at one.
const NOTHING = 0

-- Types ---------------------------------------------------------------

-- What a node is told about itself, which is where it is and what it wanted, already in words.
type Named = {
    path: string,
    wanted: string,
    pathId: number,
    expectId: number,
}

-- Private -------------------------------------------------------------

local function named (tag: Ir.Tag, paths: Serial.Interner, expected: Serial.Interner): Named
    return {
        path = paths.texts[tag.pathId],
        wanted = expected.texts[tag.expectId],
        pathId = tag.pathId,
        expectId = tag.expectId,
    }
end

--[[
    A value the schema has no place for, as the line the caller reads. The same sentence a drop
    reads as, because a caller holds one vocabulary for what their schema wanted whether the value
    that did not fit was theirs going out or somebody else's coming in.
]]
local function refuse (of: Named, got: any): never return Word.refused (of.path, of.wanted, got) end

-- Bytes nobody here wrote, as the two numbers the boundary reads a line back out of.
local function reject (code: Catalog.Code, of: Named, got: any)
    Log.reject (code, { pathId = of.pathId, expectId = of.expectId, got = got })
end

-- A whole number of bytes, little end first, for every field that is one.
local function laid (b: buffer, at: number, bytes: number, value: number)
    if bytes <= WORD then
        if bytes == 0 then return end
        if bytes == 1 then return buffer.writeu8 (b, at, value) end
        if bytes == PAIR then return buffer.writeu16 (b, at, value) end
        if bytes == TRIO then
            buffer.writeu16 (b, at, value % HALF)
            return buffer.writeu8 (b, at + PAIR, value // HALF)
        end
        return buffer.writeu32 (b, at, value)
    end

    buffer.writeu32 (b, at, value % HIGH)

    local high = value // HIGH
    if bytes == 5 then return buffer.writeu8 (b, at + WORD, high) end
    if bytes == 6 then return buffer.writeu16 (b, at + WORD, high) end

    buffer.writeu16 (b, at + WORD, high % HALF)
    buffer.writeu8 (b, at + WORD + PAIR, high // HALF)
end

local function taken (b: buffer, at: number, bytes: number): number
    if bytes <= WORD then
        if bytes == 0 then return 0 end
        if bytes == 1 then return buffer.readu8 (b, at) end
        if bytes == PAIR then return buffer.readu16 (b, at) end
        if bytes == TRIO then
            return buffer.readu16 (b, at) + buffer.readu8 (b, at + PAIR) * HALF
        end
        return buffer.readu32 (b, at)
    end

    local low = buffer.readu32 (b, at)
    if bytes == 5 then return low + buffer.readu8 (b, at + WORD) * HIGH end
    if bytes == 6 then return low + buffer.readu16 (b, at + WORD) * HIGH end

    local high = buffer.readu16 (b, at + WORD) + buffer.readu8 (b, at + WORD + PAIR) * HALF
    return low + high * HIGH
end

-- Public --------------------------------------------------------------

-- Elements of one width with nothing between them, which is the 24-bit law's whole point.
function Leaf.packed (
    b: buffer,
    at: number,
    width: number,
    count: number,
    indices: { number }
): number
    --[[
        A run of whole bytes, which the loop below would take apart and put back together a byte at
        a time. There is nothing to carry between two elements that start and end on a boundary.
    ]]
    if width == BYTE then
        for index = 1, count do
            buffer.writeu8 (b, at, indices[index])
            at += 1
        end

        return at
    end

    local acc, used = 0, 0

    for index = 1, count do
        acc = bit32.bor (acc, bit32.lshift (indices[index], used))
        used += width

        while used >= BYTE do
            buffer.writeu8 (b, at, bit32.band (acc, 0xFF))
            at += 1
            acc = bit32.rshift (acc, BYTE)
            used -= BYTE
        end
    end

    if used == 0 then return at end

    buffer.writeu8 (b, at, acc)
    return at + 1
end

--[[
    The same run, taken apart. The bits left over when the last element is out are the pad the
    stream aligns on, and they are held to being zero: padding that could differ would make two
    encodings of one value, which is what the ordering of map keys rests on not being possible.
]]
function Leaf.unpacked (
    b: buffer,
    at: number,
    width: number,
    count: number,
    into: { number }
): (number, boolean)
    -- The same run, and the same reason. A whole byte leaves no bits over, so the pad is never set.
    if width == BYTE then
        for index = 1, count do
            into[index] = buffer.readu8 (b, at)
            at += 1
        end

        return at, true
    end

    local acc, used = 0, 0
    local mask = bit32.lshift (1, width) - 1

    for index = 1, count do
        while used < width do
            acc = bit32.bor (acc, bit32.lshift (buffer.readu8 (b, at), used))
            at += 1
            used += BYTE
        end

        into[index] = bit32.band (acc, mask)
        acc = bit32.rshift (acc, width)
        used -= width
    end

    return at, acc == 0
end

-- An IEEE span, which has a place for every bit pattern a double takes and so refuses no number.
function Leaf.float (
    of: Ir.Float,
    paths: Serial.Interner,
    expected: Serial.Interner
): (Ir.Write, Ir.Read)
    local at = named (of.tag, paths, expected)
    local bytes = of.maxBytes

    if of.op == "f32" then
        local function write (b: buffer, pos: number, value: any): number
            if type (value) ~= "number" then refuse (at, value) end

            buffer.writef32 (b, pos, value)
            return pos + bytes
        end

        local function read (b: buffer, pos: number, _ctx: Types.ValidateContext): (number, any)
            return pos + bytes, buffer.readf32 (b, pos)
        end

        return write, read
    end

    local function write (b: buffer, pos: number, value: any): number
        if type (value) ~= "number" then refuse (at, value) end

        buffer.writef64 (b, pos, value)
        return pos + bytes
    end

    local function read (b: buffer, pos: number, _ctx: Types.ValidateContext): (number, any)
        return pos + bytes, buffer.readf64 (b, pos)
    end

    return write, read
end

-- One fixed field the run accumulator cannot pack, written as whole bytes of its own.
function Leaf.wide (
    of: Ir.Wide,
    paths: Serial.Interner,
    expected: Serial.Interner
): (Ir.Write, Ir.Read)
    local at = named (of.tag, paths, expected)
    local grid = of.grid
    local toIndex, fromIndex, span = grid.toIndex, grid.fromIndex, grid.span
    local bytes = of.maxBytes
    local ceiling = 2 ^ grid.width - 1

    local function write (b: buffer, pos: number, value: any): number
        local index = toIndex (value)
        if index == nil then refuse (at, value) end

        laid (b, pos, bytes, index :: number)
        return pos + bytes
    end

    local function read (b: buffer, pos: number, _ctx: Types.ValidateContext): (number, any)
        local index = taken (b, pos, bytes)
        if index > ceiling then reject (Catalog.PAD, at, index) end
        if index > span then reject (Catalog.TAG, at, index) end

        return pos + bytes, fromIndex (index)
    end

    return write, read
end

-- A varint, through the one module that spells the groups.
function Leaf.varint (
    of: Ir.Varint,
    paths: Serial.Interner,
    expected: Serial.Interner
): (Ir.Write, Ir.Read)
    local at = named (of.tag, paths, expected)

    -- Whole as well as within the ceiling, on both forms.
    if of.op == "vlq" then
        local function write (b: buffer, pos: number, value: any): number
            if not (value >= 0 and value < EXACT and value % 1 == 0) then refuse (at, value) end
            return Varint.write (b, pos, value)
        end

        local function read (b: buffer, pos: number, _ctx: Types.ValidateContext): (number, any)
            local ok, value, after = pcall (Varint.read, b, pos)
            if not ok then reject (Catalog.VARINT, at, value) end

            return after :: number, value
        end

        return write, read
    end

    local function write (b: buffer, pos: number, value: any): number
        if not (value > -EXACT and value < EXACT and value % 1 == 0) then refuse (at, value) end
        return Varint.writeSigned (b, pos, value)
    end

    local function read (b: buffer, pos: number, _ctx: Types.ValidateContext): (number, any)
        local ok, value, after = pcall (Varint.readSigned, b, pos)
        if not ok then reject (Catalog.VARINT, at, value) end

        return after :: number, value
    end

    return write, read
end

-- A string or a buffer, as its count and then its bytes.
function Leaf.bytes (
    of: Ir.Bytes,
    paths: Serial.Interner,
    expected: Serial.Interner
): (Ir.Write, Ir.Read)
    local at = named (of.tag, paths, expected)
    local low, high = of.count.min, of.count.max
    local span = high - low
    local held = Bytes.whole (Bits.width (span))
    local text = of.form == "string"

    local alphabet = of.alphabet
    if alphabet == nil then
        local function write (b: buffer, pos: number, value: any): number
            local count = if text then #value else buffer.len (value)
            if count < low or count > high then refuse (at, count) end

            laid (b, pos, held, count - low)
            local after = pos + held

            if text then
                buffer.writestring (b, after, value)
            else
                buffer.copy (b, after, value)
            end
            return after + count
        end

        local function read (b: buffer, pos: number, _ctx: Types.ValidateContext): (number, any)
            local index = taken (b, pos, held)
            if index > span then reject (Catalog.COUNT, at, index) end

            local count = index + low
            local after = pos + held
            if text then return after + count, buffer.readstring (b, after, count) end

            local out = buffer.create (count)
            buffer.copy (out, 0, b, after, count)
            return after + count, out
        end

        return write, read
    end

    local width = Bits.width (#alphabet - 1)
    local index: { [string]: number } = {}
    local symbol: { string } = {}

    for place = 1, #alphabet do
        local one = string.sub (alphabet, place, place)
        index[one] = place - 1
        symbol[place] = one
    end

    local scratch: { number } = {}

    local function write (b: buffer, pos: number, value: any): number
        local count = #value
        if count < low or count > high then refuse (at, count) end

        for place = 1, count do
            local one = index[string.sub (value, place, place)]
            if one == nil then refuse (at, value) end
            scratch[place] = one :: number
        end

        laid (b, pos, held, count - low)
        return Leaf.packed (b, pos + held, width, count, scratch)
    end

    local function read (b: buffer, pos: number, _ctx: Types.ValidateContext): (number, any)
        local counted = taken (b, pos, held)
        if counted > span then reject (Catalog.COUNT, at, counted) end

        local count = counted + low
        local after, clean = Leaf.unpacked (b, pos + held, width, count, scratch)
        if not clean then reject (Catalog.PAD, at, count) end

        local out = table.create (count) :: { string }
        for place = 1, count do
            local one = symbol[scratch[place] + 1]
            if one == nil then reject (Catalog.TAG, at, scratch[place]) end
            out[place] = one :: string
        end

        return after, table.concat (out)
    end

    return write, read
end

-- Elements of one width, counted and then packed with nothing between them.
function Leaf.run (
    of: Ir.Run,
    paths: Serial.Interner,
    expected: Serial.Interner
): (Ir.Write, Ir.Read)
    local at = named (of.tag, paths, expected)
    local low, high = of.count.min, of.count.max
    local span = high - low
    local held = Bytes.whole (Bits.width (span))

    local elem = of.elem
    local toIndex, fromIndex, reach = elem.toIndex, elem.fromIndex, elem.span
    local width = elem.width

    --[[
        A grid from zero at a whole step reads back whatever it was given, so asking it costs a call
        for an answer already in hand. A run is where that call is paid for once an element rather
        than once a field, which is what makes it worth asking about at all.
    ]]
    local plain = elem.plain == true

    local scratch: { number } = {}

    local function write (b: buffer, pos: number, value: any): number
        local count = #value
        if count < low or count > high then refuse (at, count) end

        for place = 1, count do
            local one = toIndex (value[place])
            if one == nil then refuse (at, value[place]) end
            scratch[place] = one :: number
        end

        laid (b, pos, held, count - low)
        return Leaf.packed (b, pos + held, width, count, scratch)
    end

    local function read (b: buffer, pos: number, _ctx: Types.ValidateContext): (number, any)
        local counted = taken (b, pos, held)
        if counted > span then reject (Catalog.COUNT, at, counted) end

        local count = counted + low
        local after, clean = Leaf.unpacked (b, pos + held, width, count, scratch)
        if not clean then reject (Catalog.PAD, at, count) end

        local out = table.create (count) :: { any }

        if plain then
            for place = 1, count do
                local one = scratch[place]
                if one > reach then reject (Catalog.TAG, at, one) end
                out[place] = one
            end

            return after, out
        end

        for place = 1, count do
            local one = scratch[place]
            if one > reach then reject (Catalog.TAG, at, one) end
            out[place] = fromIndex (one)
        end

        return after, out
    end

    return write, read
end

-- An instance, as its slot in the array that rides beside the frame rather than in the bytes.
function Leaf.slot (
    of: Ir.Slot,
    paths: Serial.Interner,
    expected: Serial.Interner,
    side: Ir.Sidecar
): (Ir.Write, Ir.Read)
    local at = named (of.tag, paths, expected)
    local class = of.class

    local refs, slotOf = side.refs, side.slotOf
    side.bears = true

    local function write (b: buffer, pos: number, value: any): number
        if value == nil then return Varint.write (b, pos, NOTHING) end

        local held = slotOf[value]
        if held == nil then
            held = #refs + 1
            refs[held] = value
            slotOf[value] = held
        end

        return Varint.write (b, pos, held :: number)
    end

    local function read (b: buffer, pos: number, _ctx: Types.ValidateContext): (number, any)
        local ok, slot, after = pcall (Varint.read, b, pos)
        if not ok then reject (Catalog.VARINT, at, slot) end

        local one = refs[slot :: number]
        if one == nil then return after :: number, nil end

        --[[
            The sender fills this array, so what arrives in it is a claim rather than a promise.
            Held to being an instance before the class is asked for, since asking a number for its
            class raises where a refusal is what a reader is owed.
        ]]
        if typeof (one) ~= "Instance" then reject (Catalog.SIDECAR, at, typeof (one)) end
        if class ~= nil and not one:IsA (class) then reject (Catalog.SIDECAR, at, one.ClassName) end

        return after :: number, one
    end

    return write, read
end

return table.freeze (Leaf)
