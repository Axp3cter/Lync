--!strict
--!optimize 2
-- The wire leaves, timed with nothing around them: the varint rows, the byte-order comparison, and
-- the accumulator an alphabet string packs through.

local Bytes = require("@src/wire/Bytes")
local Codecs = require("@src/codec")
local Protocol = require("@src/wire/Protocol")
local Shape = require("@src/shape")
local Varint = require("@src/wire/Varint")

local Harness = require("@bench/harness")

-- Where a value is written, and how much room it is given.
local AT = 0
local ROOM = 64

-- The two magnitudes a varint is timed at, one group and eight, each way round.
local SMALL = 100
local WIDEST = Protocol.EXACT - 1

-- The two lengths a byte-order comparison is read at, either side of one stride.
local WIDE = 24
local SHORT = 3

-- The alphabet a run is packed through, and how long a run is timed over.
local SYMBOLS = "0123456789abcdef"
local RUN = 16

-- Private -------------------------------------------------------------

-- A buffer with room to spare, which every row here writes into and none of them grows.
local function room(): buffer
    return buffer.create(ROOM)
end

-- The same, with one value already in it, for the row that reads rather than writes.
local function holding(value: number): buffer
    local out = room()
    Varint.write(out, AT, value)
    return out
end

-- Two ranges of one length, laid end to end and differing in their last byte.
local function ranges(length: number): buffer
    local out = buffer.create(length * 2)
    for at = 0, length * 2 - 1 do
        buffer.writeu8(out, at, at % 251)
    end
    buffer.writeu8(out, length * 2 - 1, buffer.readu8(out, length - 1) + 1)
    return out
end

-- One comparison of two ranges of one length, laid where `ranges` lays them.
local function ordered(out: buffer, length: number): boolean
    return Bytes.less(out, AT, length, length, length)
end

-- A varint written and the bytes it took, which at an offset of zero is the position after it.
local function unsigned(value: number): Harness.Row
    return Harness.row({
        name = `varint.vlq-{if value == SMALL then "one-group" else "eight-groups"}`,
        setup = room,
        run = function(out: buffer): number
            return Varint.write(out, AT, value)
        end,
        bytes = function(): number
            return Varint.write(room(), AT, value)
        end,
    })
end

local function signed(value: number): Harness.Row
    return Harness.row({
        name = `varint.vli-{if value == -SMALL then "one-group" else "eight-groups"}`,
        setup = room,
        run = function(out: buffer): number
            return Varint.writeSigned(out, AT, value)
        end,
        bytes = function(): number
            return Varint.writeSigned(room(), AT, value)
        end,
    })
end

-- One run packed, which is both what the row times and what it weighs.
local function packed(state: any): number
    return state.of.write(state.out, AT, state.run)
end

-- Public --------------------------------------------------------------

return {
    -- A vlq at the magnitude nearly every one of them is, and at the other end of the domain.
    unsigned(SMALL),
    unsigned(WIDEST),

    -- The decode leaf, which every id, count and length on every arriving frame goes through.
    Harness.row({
        name = "varint.vlq-read",
        setup = function(): buffer
            return holding(SMALL)
        end,
        run = function(out: buffer): number
            return (Varint.read(out, AT))
        end,
    }),

    -- A signed varint, negative because the sign folds into the first group, at both magnitudes.
    signed(-SMALL),
    signed(-WIDEST),

    -- The byte-order comparison over ranges long enough to take its stride, and over ranges
    -- shorter than one, which is the tail alone and the common case.
    Harness.row({
        name = "bytes.less-wide",
        setup = function(): buffer
            return ranges(WIDE)
        end,
        run = function(out: buffer): boolean
            return ordered(out, WIDE)
        end,
    }),
    Harness.row({
        name = "bytes.less-tail",
        setup = function(): buffer
            return ranges(SHORT)
        end,
        run = function(out: buffer): boolean
            return ordered(out, SHORT)
        end,
    }),

    -- An alphabet string, packed a character at a time.
    Harness.row({
        name = "shape.run-accumulator",
        setup = function(): any
            local of = Shape.build(Codecs.str.alphabet(SYMBOLS, RUN, RUN), "run")
            return { of = of, out = buffer.create(of.maxBytes), run = string.rep("f", RUN) }
        end,
        run = packed,
        bytes = packed,
    }),
}
