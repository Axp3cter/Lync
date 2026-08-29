--!strict
--!optimize 2
-- What a shape costs and what it weighs, one fixture at a time, in both directions.

local Shape = require ("@src/shape")
local Types = require ("@src/Types")

local Schemas = require ("@fixtures/Schemas")

local Harness = require ("@bench/harness")

-- Constants -----------------------------------------------------------

-- Where a value is written, which is the start of a buffer of its own.
const AT = 0

--[[
    The context a read is handed. Nothing in the fixtures validates against it, and it is passed
    anyway because a read taking two arguments in a bench and three in the library would be a
    signature this file agrees with alone.
]]
const CTX: Types.ValidateContext = table.freeze ({ player = nil, now = 0, last = nil })

-- The cases a row is cut from.
const TYPICAL = "typical"
const LARGEST = "largest"
const ON = "on"

-- Private -------------------------------------------------------------

--[[
    What an encode row needs, built once outside every timing: the shape, a buffer at exactly the
    width the shape says it can need, and the value.
]]
local function writing (of: Schemas.Fixture, name: string): any
    local built = Shape.build (of.codec, of.name)
    return { of = built, out = buffer.create (built.maxBytes), value = Schemas.cased (of, name) }
end

-- The same for a decode row, with the value already on the wire for it to read back.
local function reading (of: Schemas.Fixture, name: string): any
    local state = writing (of, name)

    state.of.write (state.out, AT, state.value)
    return state
end

--[[
    One encode, answering the position after it, which at an offset of zero is the byte count. It
    weighs every row here and times the encoding half.
]]
local function wrote (state: any): number return state.of.write (state.out, AT, state.value) end

-- One decode, whose value lands in the harness's sink and is read by nothing.
local function took (state: any): any
    local _, value = state.of.read (state.out, AT, CTX)
    return value
end

-- Public --------------------------------------------------------------

return {
    -- One flag, which is the floor.
    Harness.row ({
        name = "roundtrip.encode-flag-on",
        setup = function (): any return writing (Schemas.flag, ON) end,
        run = wrote,
        bytes = wrote,
    }),

    Harness.row ({
        name = "roundtrip.decode-flag-on",
        setup = function (): any return reading (Schemas.flag, ON) end,
        run = took,
        bytes = wrote,
    }),

    -- Six bit-continuous integers, which is what most real traffic looks like.
    Harness.row ({
        name = "roundtrip.encode-entity-typical",
        setup = function (): any return writing (Schemas.entity, TYPICAL) end,
        run = wrote,
        bytes = wrote,
    }),

    Harness.row ({
        name = "roundtrip.decode-entity-typical",
        setup = function (): any return reading (Schemas.entity, TYPICAL) end,
        run = took,
        bytes = wrote,
    }),

    -- A frame of movement, which is the shape that sends every tick.
    Harness.row ({
        name = "roundtrip.encode-motion-typical",
        setup = function (): any return writing (Schemas.motion, TYPICAL) end,
        run = wrote,
        bytes = wrote,
    }),

    Harness.row ({
        name = "roundtrip.decode-motion-typical",
        setup = function (): any return reading (Schemas.motion, TYPICAL) end,
        run = took,
        bytes = wrote,
    }),

    --[[
        The join payload, which is the shape where a length is a cost rather than a bound. Read
        against the row above it, since the two differ in whether anything varies.
    ]]
    Harness.row ({
        name = "roundtrip.encode-profile-typical",
        setup = function (): any return writing (Schemas.profile, TYPICAL) end,
        run = wrote,
        bytes = wrote,
    }),

    Harness.row ({
        name = "roundtrip.decode-profile-typical",
        setup = function (): any return reading (Schemas.profile, TYPICAL) end,
        run = took,
        bytes = wrote,
    }),

    -- A list and a dictionary at the size a caller usually holds.
    Harness.row ({
        name = "roundtrip.encode-inventory-typical",
        setup = function (): any return writing (Schemas.inventory, TYPICAL) end,
        run = wrote,
        bytes = wrote,
    }),

    Harness.row ({
        name = "roundtrip.decode-inventory-typical",
        setup = function (): any return reading (Schemas.inventory, TYPICAL) end,
        run = took,
        bytes = wrote,
    }),

    --[[
        The same collections at their declared bound, which is the second point on the only line
        this bench has.
    ]]
    Harness.row ({
        name = "roundtrip.encode-inventory-largest",
        setup = function (): any return writing (Schemas.inventory, LARGEST) end,
        run = wrote,
        bytes = wrote,
    }),

    Harness.row ({
        name = "roundtrip.decode-inventory-largest",
        setup = function (): any return reading (Schemas.inventory, LARGEST) end,
        run = took,
        bytes = wrote,
    }),

    -- Every constructor and every modifier in one record, which bounds the rest.
    Harness.row ({
        name = "roundtrip.encode-everything-typical",
        setup = function (): any return writing (Schemas.everything, TYPICAL) end,
        run = wrote,
        bytes = wrote,
    }),

    Harness.row ({
        name = "roundtrip.decode-everything-typical",
        setup = function (): any return reading (Schemas.everything, TYPICAL) end,
        run = took,
        bytes = wrote,
    }),
}
