--!strict
--!optimize 2
-- What a shape costs and what it weighs, one fixture at a time, in both directions.

local Shape = require("@src/shape")
local Types = require("@src/Types")

local Schemas = require("@fixtures/Schemas")

local Harness = require("@bench/harness")

-- Where a value is written, which is the start of a buffer of its own.
local AT = 0

-- The context a read is handed, which nothing in the fixtures reads.
local CTX: Types.ValidateContext = table.freeze({ player = nil, now = 0, last = nil })

-- The cases a row is cut from.
local TYPICAL = "typical"
local LARGEST = "largest"
local ON = "on"

-- Private -------------------------------------------------------------

-- What an encode row needs, built once outside every timing: the shape, a buffer at exactly the
-- width the shape says it can need, and the value.
local function writing(of: Schemas.Fixture, name: string): any
    local built = Shape.build(of.codec, of.name)
    return { of = built, out = buffer.create(built.maxBytes), value = Schemas.cased(of, name) }
end

-- The same for a decode row, with the value already on the wire for it to read back.
local function reading(of: Schemas.Fixture, name: string): any
    local state = writing(of, name)
    state.of.write(state.out, AT, state.value)
    return state
end

-- One encode, answering the position after it, which at an offset of zero is the byte count. It
-- weighs every row here and times the encoding half.
local function wrote(state: any): number
    return state.of.write(state.out, AT, state.value)
end

-- One decode, whose value lands in the harness's sink and is read by nothing.
local function took(state: any): any
    local _, value = state.of.read(state.out, AT, CTX)
    return value
end

-- Both directions of one fixture case, as the pair of rows they are.
local function both(of: Schemas.Fixture, name: string): (Harness.Row, Harness.Row)
    return Harness.row({
        name = `roundtrip.encode-{of.name}-{name}`,
        setup = function(): any
            return writing(of, name)
        end,
        run = wrote,
        bytes = wrote,
    }),
        Harness.row({
            name = `roundtrip.decode-{of.name}-{name}`,
            setup = function(): any
                return reading(of, name)
            end,
            run = took,
            bytes = wrote,
        })
end

-- Public --------------------------------------------------------------

local rows = {}
local function paired(of: Schemas.Fixture, name: string)
    local encode, decode = both(of, name)
    table.insert(rows, encode)
    table.insert(rows, decode)
end

-- One flag, which is the floor. Six bit-continuous integers, which is what most real traffic
-- looks like. A frame of movement, which is the shape that sends every tick. The join payload,
-- where a length is a cost rather than a bound. A list and a dictionary at the size a caller
-- usually holds, then at their declared bound. And nearly every constructor in one record.
paired(Schemas.flag, ON)
paired(Schemas.entity, TYPICAL)
paired(Schemas.motion, TYPICAL)
paired(Schemas.profile, TYPICAL)
paired(Schemas.inventory, TYPICAL)
paired(Schemas.inventory, LARGEST)
paired(Schemas.everything, TYPICAL)

return rows
