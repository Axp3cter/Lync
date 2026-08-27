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

--[[
    The four varint calls under their own names. Every one of them sits inside a closure this
    emits, so each is reached once a value rather than once a build, and the module they come
    from is the same table for the life of the place.
]]
const WRITE = Varint.write
const READ = Varint.read
const WRITE_SIGNED = Varint.writeSigned
const READ_SIGNED = Varint.readSigned

const BYTE = Protocol.BYTE_BITS
const EXACT = Protocol.EXACT

-- The widths a whole number of bytes is read and written in, and the value one word carries.
const PAIR = 2
const TRIO = PAIR + 1
const WORD = 4
const HALF = 2 ^ 16
const HIGH = 2 ^ (WORD * BYTE)

-- How many readings a byte has, which is how many spellings of eight flags there are to hold.
const BYTES = bit32.lshift (1, BYTE)

--[[
    Every byte as the eight flags it stands for, lowest first, which is the order `packed` lays
    them down in. A run of flags is taken apart the same way every time and there are only so many
    bytes it can meet, so the taking apart is done once here and read at one step a byte after.
]]
const SPELT = table.create (BYTES) :: { { number } }
for byte = 0, BYTES - 1 do
    local flags = table.create (BYTE) :: { number }

    local left = byte
    for spot = 1, BYTE do
        flags[spot] = left % 2
        left //= 2
    end

    SPELT[byte + 1] = table.freeze (flags)
end

-- One bit, which is what a flag takes and the width a whole byte of elements lands on exactly.
const FLAG = 1

-- Two to a byte, which is the one width over a flag that meets the boundary without carrying.
const NIBBLE = 4
const NIBBLES = 2 ^ NIBBLE

-- The width over a byte that one call still carries whole, which spares the loop below it.
const WIDE = PAIR * BYTE

-- The slot a reference nobody made takes, which is none, since the array it indexes starts at one.
const NOTHING = 0

-- How deep a value nobody declared may nest, and what each part of one opens with.
const DEPTH = Protocol.UNKNOWN_DEPTH
const REAL_BYTES = 8

const NOTHING_TAG = Protocol.UNKNOWN_NOTHING
const FALSE_TAG = Protocol.UNKNOWN_FALSE
const TRUE_TAG = Protocol.UNKNOWN_TRUE
const WHOLE_TAG = Protocol.UNKNOWN_WHOLE
const REAL_TAG = Protocol.UNKNOWN_REAL
const TEXT_TAG = Protocol.UNKNOWN_TEXT
const BYTES_TAG = Protocol.UNKNOWN_BYTES
const LIST_TAG = Protocol.UNKNOWN_LIST
const PAIRS_TAG = Protocol.UNKNOWN_PAIRS

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

--[[
    A whole number of bytes, little end first, for every field that is one. How many bytes a field
    takes is settled when it is built, so the answer is picked over once here and the pair handed
    back asks nothing of it again.
]]
local function laying (bytes: number): (buffer, number, number) -> ()
    if bytes == 0 then
        return function () end
    end
    if bytes == 1 then return buffer.writeu8 end
    if bytes == PAIR then return buffer.writeu16 end

    if bytes == TRIO then
        return function (b: buffer, at: number, value: number)
            buffer.writeu16 (b, at, value % HALF)
            buffer.writeu8 (b, at + PAIR, value // HALF)
        end
    end

    if bytes == WORD then return buffer.writeu32 end

    if bytes == WORD + 1 then
        return function (b: buffer, at: number, value: number)
            buffer.writeu32 (b, at, value % HIGH)
            buffer.writeu8 (b, at + WORD, value // HIGH)
        end
    end

    if bytes == WORD + PAIR then
        return function (b: buffer, at: number, value: number)
            buffer.writeu32 (b, at, value % HIGH)
            buffer.writeu16 (b, at + WORD, value // HIGH)
        end
    end

    return function (b: buffer, at: number, value: number)
        buffer.writeu32 (b, at, value % HIGH)

        local high = value // HIGH
        buffer.writeu16 (b, at + WORD, high % HALF)
        buffer.writeu8 (b, at + WORD + PAIR, high // HALF)
    end
end

-- The same number taken back up, picked over the same once.
local function taking (bytes: number): (buffer, number) -> number
    if bytes == 0 then
        return function () return 0 end
    end
    if bytes == 1 then return buffer.readu8 end
    if bytes == PAIR then return buffer.readu16 end

    if bytes == TRIO then
        return function (b: buffer, at: number): number
            return buffer.readu16 (b, at) + buffer.readu8 (b, at + PAIR) * HALF
        end
    end

    if bytes == WORD then return buffer.readu32 end

    if bytes == WORD + 1 then
        return function (b: buffer, at: number): number
            return buffer.readu32 (b, at) + buffer.readu8 (b, at + WORD) * HIGH
        end
    end

    if bytes == WORD + PAIR then
        return function (b: buffer, at: number): number
            return buffer.readu32 (b, at) + buffer.readu16 (b, at + WORD) * HIGH
        end
    end

    return function (b: buffer, at: number): number
        local high = buffer.readu16 (b, at + WORD) + buffer.readu8 (b, at + WORD + PAIR) * HALF
        return buffer.readu32 (b, at) + high * HIGH
    end
end

-- Public --------------------------------------------------------------

-- Elements of one width with nothing between them, which is the 24-bit law's whole point.
local function packed (
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

    --[[
        The same where a call carries the whole of an element. One of those starts on the byte the
        one before it ended on, so there is nothing to carry between two of them, and the low byte
        goes down first either way.
    ]]
    if width == WIDE then
        for index = 1, count do
            buffer.writeu16 (b, at, indices[index])
            at += PAIR
        end

        return at
    end

    --[[
        Flags, eight to a byte. The loop below carries part of an element into the next byte and
        looks for a boundary after every one, where single bits meet the boundary exactly and
        there is never anything to carry, so a byte is gathered and put down on its own.
    ]]
    if width == FLAG then
        local index = 1
        while index + BYTE - 1 <= count do
            local byte = 0
            for spot = index + BYTE - 1, index, -1 do
                byte = byte * 2 + indices[spot]
            end

            buffer.writeu8 (b, at, byte)
            at += 1
            index += BYTE
        end

        if index > count then return at end

        local byte = 0
        for spot = count, index, -1 do
            byte = byte * 2 + indices[spot]
        end

        buffer.writeu8 (b, at, byte)
        return at + 1
    end

    --[[
        Two elements to a byte, laid as the pair they are. Four bits meet the boundary exactly, so
        nothing is carried between one byte and the next and the walk below has nothing to hold
        between two of them either.
    ]]
    if width == NIBBLE then
        local index = 1
        while index < count do
            buffer.writeu8 (b, at, indices[index] + indices[index + 1] * NIBBLES)

            at += 1
            index += PAIR
        end

        if index > count then return at end

        buffer.writeu8 (b, at, indices[index])
        return at + 1
    end

    local acc, used = 0, 0

    for index = 1, count do
        acc = bit32.bor (acc, bit32.lshift (indices[index], used))
        used += width

        while used >= BYTE do
            -- Handed whole, the write itself keeping the low byte and dropping what carries.
            buffer.writeu8 (b, at, acc)
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
local function unpacked (
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

    -- The same back, which leaves no bits over and so has no pad to hold to nothing.
    if width == WIDE then
        for index = 1, count do
            into[index] = buffer.readu16 (b, at)
            at += PAIR
        end

        return at, true
    end

    -- The same run of flags, taken back a byte at a time. What is left over is the pad.
    if width == FLAG then
        local index = 1
        while index + BYTE - 1 <= count do
            table.move (SPELT[buffer.readu8 (b, at) + 1], 1, BYTE, index, into)

            at += 1
            index += BYTE
        end

        if index > count then return at, true end

        local byte = buffer.readu8 (b, at)
        local left = count - index + 1
        table.move (SPELT[byte + 1], 1, left, index, into)

        -- Whatever the run did not ask for has to be nothing, which is the byte inside those bits.
        return at + 1, byte < bit32.lshift (1, left)
    end

    local acc, used = 0, 0
    local mask = bit32.lshift (1, width) - 1

    --[[
        How many bytes the run is, so a top up never reaches past it: what is left over when the
        last element is out is the pad, and a byte taken from beyond the run would put something
        else there. Two at a time where the width leaves room under the thirty two an accumulator
        carries, which halves what the walk asks of the buffer.
    ]]
    local left = Bytes.whole (count * width)
    local paired = width <= WIDE

    for index = 1, count do
        while used < width do
            if paired and left >= PAIR then
                acc = bit32.bor (acc, bit32.lshift (buffer.readu16 (b, at), used))
                at += PAIR
                used += WIDE
                left -= PAIR
            else
                acc = bit32.bor (acc, bit32.lshift (buffer.readu8 (b, at), used))
                at += 1
                used += BYTE
                left -= 1
            end
        end

        into[index] = bit32.band (acc, mask)
        acc = bit32.rshift (acc, width)
        used -= width
    end

    return at, acc == 0
end

--[[
    The two run walkers, held under their own names above and put here for the modules that walk
    a run of their own. Both sit inside closures this file emits, so a name spares the table a
    reach once a run rather than once a build.
]]
Leaf.packed = packed
Leaf.unpacked = unpacked

--[[
    A value the schema says nothing about, spelled out as it stands. Each part opens with the tag
    saying what it is, so a reader walks one without being told its shape, and nothing is packed
    because there is no width to pack against when the shape arrives beside the value it describes.
]]
function Leaf.unknown (
    of: Ir.Unknown,
    paths: Serial.Interner,
    expected: Serial.Interner
): (Ir.Write, Ir.Read)
    local at = named (of.tag, paths, expected)
    local high = of.count.max

    -- Whether every key of a table is a whole number from one up, which is what a list is.
    local function listed (value: { [any]: any }): number?
        local count = 0
        for _ in value do
            count += 1
        end

        for index = 1, count do
            if value[index] == nil then return nil end
        end
        return count
    end

    local function put (b: buffer, pos: number, value: any, upto: number, deep: number): number
        if pos >= upto then refuse (at, "more bytes than it was given") end
        if deep > DEPTH then refuse (at, `a value nested past {DEPTH}`) end

        local kind = type (value)
        if value == nil then
            buffer.writeu8 (b, pos, NOTHING_TAG)
            return pos + 1
        end

        if kind == "boolean" then
            buffer.writeu8 (b, pos, if value then TRUE_TAG else FALSE_TAG)
            return pos + 1
        end

        if kind == "number" then
            local whole = value % 1 == 0 and value > -EXACT and value < EXACT
            buffer.writeu8 (b, pos, if whole then WHOLE_TAG else REAL_TAG)

            --[[
                Written before it is held to the bound, because a varint says how wide it is by
                being written. The frame keeps the slack for exactly this, so the bytes past the
                bound land in room nothing else was given and the refusal drops the frame anyway.
            ]]
            local after = if whole then WRITE_SIGNED (b, pos + 1, value) else pos + 1 + REAL_BYTES
            if not whole then buffer.writef64 (b, pos + 1, value) end

            if after > upto then refuse (at, "more bytes than it was given") end
            return after
        end

        if kind == "string" or kind == "buffer" then
            local text = kind == "string"
            local count = if text then #value else buffer.len (value)

            buffer.writeu8 (b, pos, if text then TEXT_TAG else BYTES_TAG)
            local after = WRITE (b, pos + 1, count)
            if after + count > upto then refuse (at, "more bytes than it was given") end

            if text then
                buffer.writestring (b, after, value)
            else
                buffer.copy (b, after, value)
            end
            return after + count
        end

        if kind ~= "table" then refuse (at, `a {kind}`) end

        local count = listed (value)
        if count ~= nil then
            buffer.writeu8 (b, pos, LIST_TAG)

            local after = WRITE (b, pos + 1, count)
            for index = 1, count do
                after = put (b, after, value[index], upto, deep + 1)
            end
            return after
        end

        local held = 0
        for _ in value do
            held += 1
        end

        buffer.writeu8 (b, pos, PAIRS_TAG)
        local after = WRITE (b, pos + 1, held)

        for key, held2 in value do
            after = put (b, after, key, upto, deep + 1)
            after = put (b, after, held2, upto, deep + 1)
        end
        return after
    end

    local function take (b: buffer, pos: number, upto: number, deep: number): (number, any)
        if pos >= upto then reject (Catalog.COUNT, at, pos) end
        if deep > DEPTH then reject (Catalog.TAG, at, deep) end

        local tag = buffer.readu8 (b, pos)
        if tag == NOTHING_TAG then return pos + 1, nil end
        if tag == FALSE_TAG then return pos + 1, false end
        if tag == TRUE_TAG then return pos + 1, true end

        if tag == WHOLE_TAG then
            local whole, after = READ_SIGNED (b, pos + 1)
            if after > upto then reject (Catalog.COUNT, at, after) end

            return after, whole
        end

        if tag == REAL_TAG then
            if pos + 1 + REAL_BYTES > upto then reject (Catalog.COUNT, at, pos) end
            return pos + 1 + REAL_BYTES, buffer.readf64 (b, pos + 1)
        end

        if tag == TEXT_TAG or tag == BYTES_TAG then
            local count, after = READ (b, pos + 1)
            if after + count > upto then reject (Catalog.COUNT, at, count) end

            if tag == TEXT_TAG then return after + count, buffer.readstring (b, after, count) end

            local out = buffer.create (count)
            buffer.copy (out, 0, b, after, count)
            return after + count, out
        end

        if tag == LIST_TAG or tag == PAIRS_TAG then
            local count, after = READ (b, pos + 1)
            if after + count > upto then reject (Catalog.COUNT, at, count) end

            local out: any = {}
            if tag == LIST_TAG then
                for index = 1, count do
                    after, out[index] = take (b, after, upto, deep + 1)
                end
                return after, out
            end

            for _ = 1, count do
                local key, value
                after, key = take (b, after, upto, deep + 1)
                after, value = take (b, after, upto, deep + 1)

                if key == nil then reject (Catalog.TAG, at, tag) end
                out[key] = value
            end
            return after, out
        end

        reject (Catalog.TAG, at, tag)
        return pos, nil
    end

    local function write (b: buffer, pos: number, value: any): number
        return put (b, pos, value, pos + high, 0)
    end

    local function read (b: buffer, pos: number, _ctx: Types.ValidateContext): (number, any)
        local upto = math.min (pos + high, buffer.len (b))
        return take (b, pos, upto, 0)
    end

    return write, read
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
    local put, take = laying (bytes), taking (bytes)
    local ceiling = 2 ^ grid.width - 1

    local function write (b: buffer, pos: number, value: any): number
        local index = toIndex (value)
        if index == nil then refuse (at, value) end

        put (b, pos, index :: number)
        return pos + bytes
    end

    local function read (b: buffer, pos: number, _ctx: Types.ValidateContext): (number, any)
        local index = take (b, pos)
        if index > ceiling then reject (Catalog.PAD, at, index) end
        if index > span then reject (Catalog.TAG, at, index) end

        return pos + bytes, fromIndex (index)
    end

    return write, read
end

--[[
    Nothing, both ways. There is no value to hold to a domain and no bytes to walk, so the offset
    goes back untouched and a reader is handed the nothing that was sent rather than a stand-in
    for it, which is what makes the fact of the call the whole of what arrived.
]]
function Leaf.none (): (Ir.Write, Ir.Read)
    local function write (_b: buffer, pos: number, _value: any): number return pos end

    local function read (_b: buffer, pos: number, _ctx: Types.ValidateContext): (number, any)
        return pos, nil
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
            return WRITE (b, pos, value)
        end

        local function read (b: buffer, pos: number, _ctx: Types.ValidateContext): (number, any)
            local ok, value, after = pcall (READ, b, pos)
            if not ok then reject (Catalog.VARINT, at, value) end

            return after :: number, value
        end

        return write, read
    end

    local function write (b: buffer, pos: number, value: any): number
        if not (value > -EXACT and value < EXACT and value % 1 == 0) then refuse (at, value) end
        return WRITE_SIGNED (b, pos, value)
    end

    local function read (b: buffer, pos: number, _ctx: Types.ValidateContext): (number, any)
        local ok, value, after = pcall (READ_SIGNED, b, pos)
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
    local put, take = laying (held), taking (held)
    local text = of.form == "string"

    local alphabet = of.alphabet
    if alphabet == nil then
        local function write (b: buffer, pos: number, value: any): number
            local count = if text then #value else buffer.len (value)
            if count < low or count > high then refuse (at, count) end

            put (b, pos, count - low)
            local after = pos + held

            if text then
                buffer.writestring (b, after, value)
            else
                buffer.copy (b, after, value)
            end
            return after + count
        end

        local function read (b: buffer, pos: number, _ctx: Types.ValidateContext): (number, any)
            local index = take (b, pos)
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

        put (b, pos, count - low)
        return packed (b, pos + held, width, count, scratch)
    end

    local function read (b: buffer, pos: number, _ctx: Types.ValidateContext): (number, any)
        local counted = take (b, pos)
        if counted > span then reject (Catalog.COUNT, at, counted) end

        local count = counted + low
        local after, clean = unpacked (b, pos + held, width, count, scratch)
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
    local put, take = laying (held), taking (held)

    local elem = of.elem
    local toIndex, fromIndex, reach = elem.toIndex, elem.fromIndex, elem.span
    local toIndices, fromIndices = elem.toIndices, elem.fromIndices
    local width = elem.width

    --[[
        A grid from zero at a whole step reads back whatever it was given, so asking it costs a call
        for an answer already in hand. A run is where that call is paid for once an element rather
        than once a field, which is what makes it worth asking about at all.
    ]]
    local plain = elem.plain == true

    --[[
        Whether the width spells nothing the grid has no point for. A run of those has none to turn
        away on the way back, and one that is its own index besides has nothing at all to do to the
        numbers between the bytes and the list they come out as.
    ]]
    local whole = elem.whole == true

    local scratch: { number } = {}

    local function write (b: buffer, pos: number, value: any): number
        local count = #value
        if count < low or count > high then refuse (at, count) end

        --[[
            The whole run put onto the grid at once where the grid offers that, which is asked
            once a run rather than once an element and is the only thing between the two.
        ]]
        if toIndices ~= nil then
            local off = toIndices (value, scratch, count)
            if off ~= nil then refuse (at, value[off]) end
        else
            for place = 1, count do
                local one = toIndex (value[place])
                if one == nil then refuse (at, value[place]) end
                scratch[place] = one :: number
            end
        end

        put (b, pos, count - low)
        return packed (b, pos + held, width, count, scratch)
    end

    local function read (b: buffer, pos: number, _ctx: Types.ValidateContext): (number, any)
        local counted = take (b, pos)
        if counted > span then reject (Catalog.COUNT, at, counted) end

        local count = counted + low
        local after, clean = unpacked (b, pos + held, width, count, scratch)
        if not clean then reject (Catalog.PAD, at, count) end

        local out = table.create (count) :: { any }

        -- The same the other way, where the width itself says no reading of it is off the grid.
        if whole and fromIndices ~= nil then
            fromIndices (scratch, out, count)
            return after, out
        end

        if plain then
            if whole then
                table.move (scratch, 1, count, 1, out)
                return after, out
            end

            for place = 1, count do
                local one = scratch[place]
                if one > reach then reject (Catalog.TAG, at, one) end
                out[place] = one
            end

            return after, out
        end

        if whole then
            for place = 1, count do
                out[place] = fromIndex (scratch[place])
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
        if value == nil then return WRITE (b, pos, NOTHING) end

        local held = slotOf[value]
        if held == nil then
            held = #refs + 1
            refs[held] = value
            slotOf[value] = held
        end

        return WRITE (b, pos, held :: number)
    end

    local function read (b: buffer, pos: number, _ctx: Types.ValidateContext): (number, any)
        local ok, slot, after = pcall (READ, b, pos)
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
