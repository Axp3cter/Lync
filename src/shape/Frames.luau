--!strict
--!optimize 2
-- The block headers: the bits before a payload, as the pair that lays each form down.

local Bits = require ("@src/kernel/Bits")
local Protocol = require ("@src/wire/Protocol")
local Words = require ("@src/shape/Words")

local Frames = {}

-- Constants -----------------------------------------------------------

-- What a header's fields are wide.
const STAMP = Protocol.STAMP_BITS
const SEQ = Bits.width (Protocol.NEWEST_WINDOW * 2 - 1)
const ASKED = Bits.width (Protocol.QUERY_CAP * 2 - 1)
const OUTCOME = Protocol.OUTCOME_BITS
const KIND = Bits.width (Protocol.SECTION_CLEAR)

-- The narrow windows a plan cuts, read from the module that cuts them. The widest is the last arm.
const ONE = Words.ONE
const PAIR = Words.PAIR

-- Types ---------------------------------------------------------------

-- One block header, as the pair that lays it down and takes it back up.
export type Write = (b: buffer, pos: number, of: { number }) -> ()
export type Read = (b: buffer, pos: number, into: { number }) -> ()

export type Head = {
    read fields: number,
    read bytes: number,
    read write: Write,
    read read: Read,
}

-- Private -------------------------------------------------------------

-- A run of fixed-width fields, as the pair that composes it into windows and takes it apart.
local function run (widths: { number }): (Write, Read, number)
    local plan = Words.plan (widths)
    local windows = #plan
    local held = #widths

    local bytes = 0
    for _, window in plan do
        bytes += window.bytes
    end

    local function write (b: buffer, pos: number, of: { number })
        for index = 1, windows do
            local window = plan[index]
            local acc = 0

            for _, part in window.parts do
                local piece = bit32.extract (of[part.field], part.shift, part.width)
                acc = bit32.bor (acc, bit32.lshift (piece, part.offset))
            end

            local at = pos + window.at
            if window.bytes == ONE then
                buffer.writeu8 (b, at, acc)
            elseif window.bytes == PAIR then
                buffer.writeu16 (b, at, acc)
            else
                buffer.writeu32 (b, at, acc)
            end
        end
    end

    --[[
        Every field cleared first, because a piece at no shift is written and every piece above it
        is merged, and what is under a field the caller reused is whatever the last header left.
    ]]
    local function read (b: buffer, pos: number, into: { number })
        for index = 1, held do
            into[index] = 0
        end

        for index = 1, windows do
            local window = plan[index]
            local at = pos + window.at
            local acc = if window.bytes == ONE
                then buffer.readu8 (b, at)
                elseif window.bytes == PAIR then buffer.readu16 (b, at)
                else buffer.readu32 (b, at)

            for _, part in window.parts do
                local piece = bit32.extract (acc, part.offset, part.width)
                local field = part.field
                into[field] = bit32.bor (into[field], bit32.lshift (piece, part.shift))
            end
        end
    end

    return write, read, bytes
end

-- A form's fields, as the head that writes them.
local function headed (widths: { number }): Head
    local write, read, bytes = run (widths)

    return table.freeze ({
        fields = #widths,
        bytes = bytes,
        write = write,
        read = read,
    })
end

local function named (over: number): number return Bits.width (over - 1) end

-- Public --------------------------------------------------------------

-- The defId on its own, which is the one field every form opens with.
function Frames.naming (over: number): Head return headed ({ named (over) }) end

-- A packet block: `{ defId }`, or `{ defId, stamp }` where the definition declared one.
function Frames.packet (over: number, stamped: boolean): Head
    local id = named (over)
    return headed (if stamped then { id, STAMP } else { id })
end

-- A newest packet block: `{ defId, seq }`, or `{ defId, stamp, seq }`.
function Frames.newest (over: number, stamped: boolean): Head
    local id = named (over)
    return headed (if stamped then { id, STAMP, SEQ } else { id, SEQ })
end

-- A request block: `{ defId, id }`, where the id is the one its response comes back under.
function Frames.request (over: number): Head return headed ({ named (over), ASKED }) end

-- A response block: `{ defId, id, outcome }`.
function Frames.response (over: number): Head
    local id = named (over)
    return headed ({ id, ASKED, OUTCOME })
end

-- A state section's block: `{ defId, kind }`, and everything after it is the section's own grammar.
function Frames.section (over: number): Head return headed ({ named (over), KIND }) end

-- A newest state section's block: `{ defId, fieldId, seq }`.
function Frames.stream (over: number, fields: number): Head
    return headed ({ named (over), named (fields), SEQ })
end

--[[
    What one payload's block comes to, which is the header, the payload, and whatever follows it.

    Stated once: the three parts are the grammar, and a caller adding two of them is one who will
    eventually add the wrong two.
]]
function Frames.block (of: Head, payload: number): number return of.bytes + payload end

return table.freeze (Frames)
