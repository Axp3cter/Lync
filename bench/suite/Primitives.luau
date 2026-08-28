--!strict
--!optimize 2
--[[
    The wire leaves, timed with nothing around them: the varint rows, the byte-order stride, and
    the accumulator an alphabet string packs through.
]]

local Bytes = require ("@src/wire/Bytes")
local Lync = require ("@src")
local Protocol = require ("@src/wire/Protocol")
local Shape = require ("@src/shape")
local Varint = require ("@src/wire/Varint")

local Harness = require ("@bench/harness")

-- Constants -----------------------------------------------------------

-- Where a value is written, and how much room it is given.
const AT = 0
const ROOM = 64

-- The two magnitudes a `vlq` is read at.
const SMALL = 100
const WIDEST = Protocol.EXACT - 1

-- The two magnitudes a `vli` is written at, either side of `VLI_EDGE`.
const INNER = -(Protocol.VLI_EDGE // 2)
const BEYOND = -Protocol.VLI_EDGE - 1

-- The two lengths `rangeLess` is read at, either side of one stride.
const WIDE = 24
const SHORT = 3

-- The alphabet a run is packed through, and how long a run is timed over.
const SYMBOLS = "0123456789abcdef"
const RUN = 16

-- Private -------------------------------------------------------------

-- A buffer with room to spare, which every row here writes into and none of them grows.
local function room (): buffer return buffer.create (ROOM) end

-- The same, with one value already in it, for the rows that read rather than write.
local function holding (value: number): buffer
    local out = room ()
    Varint.write (out, AT, value)
    return out
end

-- Two ranges of one length, laid end to end and differing in their last byte.
local function ranges (length: number): buffer
    local out = buffer.create (length * 2)
    for at = 0, length * 2 - 1 do
        buffer.writeu8 (out, at, at % 251)
    end

    buffer.writeu8 (out, length * 2 - 1, buffer.readu8 (out, length - 1) + 1)
    return out
end

--[[
    One comparison of two ranges of one length, laid where `ranges` lays them.

    Both rows go through it, so the only thing that differs between them is the length, which is the
    one thing they are about.
]]
local function ordered (out: buffer, length: number): boolean
    return Bytes.rangeLess (out, AT, length, length, length)
end

-- What a row writing a varint put on the wire, which is the row's own byte count.
local function wrote (value: number): number return Varint.write (room (), AT, value) - AT end

--[[
    One run packed, which is both what the row times and what it weighs: the write answers the
    position after it, and at an offset of zero that position is the byte count. One function rather
    than two, because a bench asking for a size a different call produced would be reporting a size
    for a row it did not measure.
]]
local function packed (state: any): number return state.of.write (state.out, AT, state.run) end

-- Public --------------------------------------------------------------

return {
    -- A `vlq` at the magnitude nearly every one of them is.
    Harness.row ({
        name = "varint.vlq-one-group",
        setup = room,
        run = function (out: buffer): number return Varint.write (out, AT, SMALL) end,
        bytes = function (): number return wrote (SMALL) end,
    }),

    -- The same call at the other end of the domain.
    Harness.row ({
        name = "varint.vlq-eight-groups",
        setup = room,
        run = function (out: buffer): number return Varint.write (out, AT, WIDEST) end,
        bytes = function (): number return wrote (WIDEST) end,
    }),

    --[[
        The decode leaf, which every id, count and length on every arriving frame goes through.
        Timed at one group for the same reason the write is.
    ]]
    Harness.row ({
        name = "varint.vlq-read",
        setup = function (): buffer return holding (SMALL) end,
        run = function (out: buffer): number
            local value = Varint.read (out, AT)
            return value
        end,
    }),

    --[[
        A signed varint inside the range a double holds exactly.

        The zigzag here is plain arithmetic, which the inner range rests on. Negative, because a
        zigzag branches on the sign and the positive branch never has to borrow.
    ]]
    Harness.row ({
        name = "varint.vli-inner",
        setup = room,
        run = function (out: buffer): number return Varint.writeSigned (out, AT, INNER) end,
        bytes = function (): number return Varint.writeSigned (room (), AT, INNER) - AT end,
    }),

    --[[
        The same call one step past the edge, where the zigzag needs a bit a double does not have
        and the integer domain was expected.
    ]]
    Harness.row ({
        name = "varint.vli-wide",
        setup = room,
        run = function (out: buffer): number return Varint.writeSigned (out, AT, BEYOND) end,
        bytes = function (): number return Varint.writeSigned (room (), AT, BEYOND) - AT end,
    }),

    -- The byte-order stride, over ranges long enough to take it.
    Harness.row ({
        name = "bytes.range-less-wide",
        setup = function (): buffer return ranges (WIDE) end,
        run = function (out: buffer): boolean return ordered (out, WIDE) end,
    }),

    --[[
        The same comparison over ranges shorter than one stride, which is the tail alone.

        A one-word key never reaches the loop above, and short keys are the common ones, so a stride
        that was fast and a tail that was not would read as a fast comparison and a slow map.
    ]]
    Harness.row ({
        name = "bytes.range-less-tail",
        setup = function (): buffer return ranges (SHORT) end,
        run = function (out: buffer): boolean return ordered (out, SHORT) end,
    }),

    -- An alphabet string, packed a character at a time.
    Harness.row ({
        name = "shape.run-accumulator",
        setup = function (): any
            local of = Shape.build (Lync.str.alphabet (SYMBOLS, RUN, RUN), "run")
            return { of = of, out = buffer.create (of.maxBytes), run = string.rep ("f", RUN) }
        end,
        run = packed,
        bytes = packed,
    }),
}
