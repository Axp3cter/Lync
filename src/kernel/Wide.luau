--!strict
--!optimize 2
-- Sixty-four bits: the platform's own where it has them, and two halves where it has not.

local Bits = require ("@src/kernel/Bits")

local Wide = {}

-- Constants -----------------------------------------------------------

-- Whether this platform carries a sixty-four bit integer.
local carried: any = integer
const NATIVE = carried ~= nil

--[[
    The piece a half is cut into for a multiply, what a piece and a word count to, and how wide a
    half is.
]]
const PIECE = 16
const PLACE = 65536
const WORD = PLACE * PLACE
const HALF = Bits.width (WORD - 1)

-- Where the low half of a word sits in the eight bytes it is written as, and where the high half.
const LOW = 0
const HIGH = 4

-- The base a word is spelled in, and how many of those digits one half spells.
const BASE = 16
const DIGITS = 8

-- The spelling itself, so the width a half is written to and the width one is read back at agree.
const SPELLING = `%0{DIGITS}X%0{DIGITS}X`

-- Types ---------------------------------------------------------------

-- A sixty-four bit word, which is one thing to every caller and two to this module.
export type Word = any

-- One carrier: every operation on a word, in the vocabulary this library asks them in.
export type Carrier = {
    read NONE: Word,
    read bit: (place: number) -> Word,
    read union: (a: Word, b: Word) -> Word,
    read meets: (a: Word, b: Word) -> boolean,
    read any: (of: Word) -> boolean,
    read lowest: (of: Word) -> number,
    read without: (of: Word) -> Word,
    read bxor: (a: Word, b: Word) -> Word,
    read mul: (a: Word, b: Word) -> Word,
    read of: (value: number) -> Word,
    read parse: (digits: string) -> Word,
    read same: (a: Word, b: Word) -> boolean,
    read below: (a: Word, b: Word) -> boolean,
    read read: (b: buffer, at: number) -> Word,
    read write: (b: buffer, at: number, of: Word) -> number,
    read ordered: (b: buffer, at: number) -> Word,
    read text: (of: Word) -> string,
}

-- Private -------------------------------------------------------------

-- The platform's own, which is every operation straight through.
local SPLIT = if NATIVE then carried.create (HALF) else nil
local NOTHING = if NATIVE then carried.create (0) else nil

local held: Carrier = {
    NONE = NOTHING,

    bit = function (place: number): Word
        return carried.lshift (carried.create (1), carried.create (place - 1))
    end,

    union = function (a: Word, b: Word): Word return carried.bor (a, b) end,
    meets = function (a: Word, b: Word): boolean return carried.btest (a, b) end,
    any = function (of: Word): boolean return carried.btest (of) end,
    lowest = function (of: Word): number return carried.tonumber (carried.countrz (of)) + 1 end,

    without = function (of: Word): Word
        return carried.band (of, carried.sub (of, carried.create (1)))
    end,

    bxor = function (a: Word, b: Word): Word return carried.bxor (a, b) end,
    mul = function (a: Word, b: Word): Word return carried.mul (a, b) end,
    of = function (value: number): Word return carried.create (value) end,
    parse = function (digits: string): Word return carried.fromstring (digits, BASE) end,
    same = function (a: Word, b: Word): boolean return a == b end,
    below = function (a: Word, b: Word): boolean return carried.ult (a, b) end,
    read = function (b: buffer, at: number): Word return buffer.readinteger (b, at) end,

    write = function (b: buffer, at: number, of: Word): number
        buffer.writeinteger (b, at, of)
        return at + HIGH + HIGH
    end,

    ordered = function (b: buffer, at: number): Word
        return carried.bswap (buffer.readinteger (b, at))
    end,

    text = function (of: Word): string
        return string.format (
            SPELLING,
            carried.tonumber (carried.extract (of, SPLIT, SPLIT)),
            carried.tonumber (carried.extract (of, NOTHING, SPLIT))
        )
    end,
}

-- Two halves, each a `bit32` word, most significant first.
local halved: Carrier = {
    NONE = table.freeze ({ 0, 0 }),

    bit = function (place: number): Word
        local value = 2 ^ (place - 1)
        if value < WORD then return table.freeze ({ 0, value }) end

        return table.freeze ({ value / WORD, 0 })
    end,

    union = function (a: Word, b: Word): Word
        return { bit32.bor (a[1], b[1]), bit32.bor (a[2], b[2]) }
    end,

    meets = function (a: Word, b: Word): boolean
        return bit32.btest (a[1], b[1]) or bit32.btest (a[2], b[2])
    end,

    any = function (of: Word): boolean return of[1] ~= 0 or of[2] ~= 0 end,

    lowest = function (of: Word): number
        if of[2] ~= 0 then return bit32.countrz (of[2]) + 1 end
        return bit32.countrz (of[1]) + HALF + 1
    end,

    -- The lowest set bit cleared, which is the one place a half borrows from nothing.
    without = function (of: Word): Word
        if of[2] ~= 0 then return { of[1], bit32.band (of[2], of[2] - 1) } end
        return { bit32.band (of[1], of[1] - 1), 0 }
    end,

    bxor = function (a: Word, b: Word): Word
        return { bit32.bxor (a[1], b[1]), bit32.bxor (a[2], b[2]) }
    end,

    -- A product modulo 2^64, in four sixteen bit pieces.
    mul = function (a: Word, b: Word): Word
        local a0 = bit32.band (a[2], PLACE - 1)
        local a1 = bit32.rshift (a[2], PIECE)
        local a2 = bit32.band (a[1], PLACE - 1)
        local a3 = bit32.rshift (a[1], PIECE)

        local b0 = bit32.band (b[2], PLACE - 1)
        local b1 = bit32.rshift (b[2], PIECE)
        local b2 = bit32.band (b[1], PLACE - 1)
        local b3 = bit32.rshift (b[1], PIECE)

        local c0 = a0 * b0
        local c1 = a0 * b1 + a1 * b0
        local c2 = a0 * b2 + a1 * b1 + a2 * b0
        local c3 = a0 * b3 + a1 * b2 + a2 * b1 + a3 * b0

        local r0 = c0 % PLACE
        local up = (c0 - r0) / PLACE + c1

        local r1 = up % PLACE
        up = (up - r1) / PLACE + c2

        local r2 = up % PLACE
        up = (up - r2) / PLACE + c3

        local r3 = up % PLACE
        return { r3 * PLACE + r2, r1 * PLACE + r0 }
    end,

    of = function (value: number): Word return { 0, value } end,

    parse = function (digits: string): Word
        local high = tonumber (string.sub (digits, 1, #digits - DIGITS), BASE)
        local low = tonumber (string.sub (digits, #digits - DIGITS + 1), BASE)

        return { high or 0, low or 0 }
    end,

    same = function (a: Word, b: Word): boolean return a[1] == b[1] and a[2] == b[2] end,

    below = function (a: Word, b: Word): boolean
        if a[1] ~= b[1] then return a[1] < b[1] end
        return a[2] < b[2]
    end,

    -- The low half first, which is where a little endian sixty-four bit read finds it.
    read = function (b: buffer, at: number): Word
        return { buffer.readu32 (b, at + HIGH), buffer.readu32 (b, at + LOW) }
    end,

    write = function (b: buffer, at: number, of: Word): number
        buffer.writeu32 (b, at + LOW, of[2])
        buffer.writeu32 (b, at + HIGH, of[1])
        return at + HIGH + HIGH
    end,

    -- The first byte most significant, which is what a bytewise order compares.
    ordered = function (b: buffer, at: number): Word
        return {
            bit32.byteswap (buffer.readu32 (b, at + LOW)),
            bit32.byteswap (buffer.readu32 (b, at + HIGH)),
        }
    end,

    text = function (of: Word): string return string.format (SPELLING, of[1], of[2]) end,
}

local chosen = if NATIVE then held else halved

-- Every bit that has been asked for, made once.
local bits: { Word } = {}

-- Public --------------------------------------------------------------

--[[
    Which carrier this build got. Reported so a place can say so, and read by the suites that hold
    the two to each other wherever both exist.
]]
Wide.native = NATIVE

-- Both carriers, under names, where this build has both.
local both: { [string]: Carrier } = { halves = halved }
if NATIVE then both.own = held end

Wide.carriers = table.freeze (both)

-- A word of no bits, which is what a mask starts as and what an empty union comes to.
Wide.NONE = chosen.NONE

-- Everything a word is asked, in the vocabulary the library asks it in rather than the platform's.
Wide.union = chosen.union
Wide.meets = chosen.meets
Wide.any = chosen.any
Wide.lowest = chosen.lowest
Wide.without = chosen.without
Wide.bxor = chosen.bxor
Wide.mul = chosen.mul
Wide.of = chosen.of
Wide.parse = chosen.parse
Wide.same = chosen.same
Wide.below = chosen.below
Wide.read = chosen.read
Wide.write = chosen.write
Wide.ordered = chosen.ordered
Wide.text = chosen.text

--[[
    One bit at a place, counted from one the way a field index is.

    Answered from the pile above where it has been asked for before, which is every ask after the
    first for any place a schema actually names.
]]
function Wide.bit (place: number): Word
    local found = bits[place]
    if found ~= nil then return found end

    found = chosen.bit (place)
    bits[place] = found
    return found
end

return table.freeze (Wide)
