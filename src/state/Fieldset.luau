--!strict
--!optimize 2
-- Which fields a delta section carries, and which of them changed on every slot it lists.

local Bits = require ("@src/kernel/Bits")
local Bytes = require ("@src/wire/Bytes")
local Catalog = require ("@src/kernel/Catalog")
local Log = require ("@src/kernel/Log")
local Protocol = require ("@src/wire/Protocol")

local Fieldset = {}

-- Constants -----------------------------------------------------------

const LIST = Protocol.FIELDSET_LIST
const MASK = Protocol.FIELDSET_MASK

-- The two one-bit fields here, named apart because they say different things at different places.
const MODE = 1
const FLAG = 1

const BYTE = Protocol.BYTE_BITS

const NO_FIELD = "a fieldset naming a field this set has not got"
const NO_FIELDS = "a fieldset naming no fields at all"
const OUT_OF_ORDER = "a fieldset naming its fields out of order"
const PADDED = "a fieldset leaving something in the bits above it"

-- Types ---------------------------------------------------------------

-- The fields a delta selected, and how each of them is covered.
export type Chosen = {
    mode: number,
    count: number,
    fields: { number },
    full: { number },
}

export type Write = (b: buffer, at: number, of: Chosen) -> number
export type Read = (b: buffer, at: number, into: Chosen) -> number

-- One set's fieldset, compiled once, since which of its two forms a section takes is per section.
export type Fieldset = {
    read over: number,
    read width: number,
    read widest: number,
    read write: Write,
    read read: Read,
}

-- Private -------------------------------------------------------------

--[[
    A section this endpoint could not have written, refused under the one code every such refusal
    carries and the phrase the site that found it holds.
]]
function Fieldset.broken (said: string): never
    local facts: Log.Facts = { said = said }
    return Log.reject (Catalog.SECTION, facts)
end

-- Public --------------------------------------------------------------

-- A set's fieldset, as the pair that lays one down and takes it back up.
function Fieldset.of (over: number): Fieldset
    local width = Bits.width (over - 1)
    local listed = width * (over + 1)

    local function write (b: buffer, at: number, of: Chosen): number
        local count = of.count
        local mode = if width * (count + 1) <= over then LIST else MASK
        of.mode = mode

        local held = Bytes.put (b, at * BYTE, MODE, mode)

        if mode == LIST then
            --[[
                One less than the count, because a delta selecting nothing is not a delta. That is
                what lets a set of one field spend nothing at all on its fieldset past the mode bit:
                the count is a ranged int over one possibility and so is the field index, and both
                are no bits.
            ]]
            held = Bytes.put (b, held, width, count - 1)
            for index = 1, count do
                held = Bytes.put (b, held, width, of.fields[index] - 1)
            end
        else
            --[[
                The cursor is held to the count, because what sits past it is the section before
                this one's. A leftover equal to the field being asked about would set a bit for a
                field this delta does not carry, and the reader would then read every field after it
                at the wrong offset.
            ]]
            local reached = 1
            for field = 1, over do
                local on = if reached <= count and of.fields[reached] == field then 1 else 0
                held = Bytes.put (b, held, FLAG, on)
                reached += on
            end
        end

        --[[
            The coverage flags ride the same bit run rather than sitting beside the values they
            speak for. Every boundary in a section is on a byte, so a flag there would cost a byte
            per selected field where this costs a bit, and nothing else moves: a reader knows how
            many follow the moment it has read the fieldset.
        ]]
        for index = 1, count do
            held = Bytes.put (b, held, FLAG, of.full[index])
        end

        local byte = Bytes.aligned (b, held)
        return byte
    end

    --[[
        A reader turns away a fieldset an encoder could not have written, and stops there. Out of
        order and empty are one comparison each, and the order test convicts a repeat as well. A
        count past the field count needs no test: that many ascending indices inside it do not
        exist.
    ]]
    local function read (b: buffer, at: number, into: Chosen): number
        local mode, held = Bytes.take (b, at * BYTE, MODE)
        into.mode = mode

        local count = 0
        if mode == LIST then
            count, held = Bytes.take (b, held, width)
            count += 1

            local last = 0
            for index = 1, count do
                local one
                one, held = Bytes.take (b, held, width)
                one += 1

                if one > over then Fieldset.broken (NO_FIELD) end
                if one <= last then Fieldset.broken (OUT_OF_ORDER) end

                into.fields[index] = one
                last = one
            end
        else
            for field = 1, over do
                local on
                on, held = Bytes.take (b, held, FLAG)
                if on == 0 then continue end

                count += 1
                into.fields[count] = field
            end
            if count == 0 then Fieldset.broken (NO_FIELDS) end
        end

        into.count = count

        for index = 1, count do
            into.full[index], held = Bytes.take (b, held, FLAG)
        end

        local byte, clean = Bytes.aligned (b, held)
        if not clean then Fieldset.broken (PADDED) end
        return byte
    end

    return table.freeze ({
        over = over,
        width = width,
        widest = math.ceil ((MODE + math.min (listed, over) + over) / BYTE),
        write = write,
        read = read,
    })
end

-- The record a caller fills and a reader fills back, empty, which is one per set that has a delta.
function Fieldset.chosen (): Chosen return { mode = LIST, count = 0, fields = {}, full = {} } end

return table.freeze (Fieldset)
