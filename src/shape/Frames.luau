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
const BYTE = Protocol.BYTE_BITS

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

    -- How many payloads one block of this form may carry, which only a running form answers.
    read runs: number?,
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

    --[[
        A head of one field lying in one piece, which is what a namespace's own is and what every
        header a run repeats is. The loops above walk arrays to find what is already known here, so
        the same work is one read, one cut and one store, and the two places the general form adds
        are held to being zero rather than assumed to be.
    ]]
    local first = plan[1]
    if
        held == 1
        and windows == 1
        and #first.parts == 1
        and first.at == 0
        and first.parts[1].offset == 0
    then
        local size = first.bytes
        local wide = first.parts[1].width

        local function lone (b: buffer, pos: number, of: { number })
            if size == ONE then
                buffer.writeu8 (b, pos, of[1])
            elseif size == PAIR then
                buffer.writeu16 (b, pos, of[1])
            else
                buffer.writeu32 (b, pos, of[1])
            end
        end

        local function sole (b: buffer, pos: number, into: { number })
            local acc = if size == ONE
                then buffer.readu8 (b, pos)
                elseif size == PAIR then buffer.readu16 (b, pos)
                else buffer.readu32 (b, pos)

            into[1] = bit32.extract (acc, 0, wide)
        end

        return lone, sole, bytes
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

--[[
    A block that may carry a run: `{ defId, more }`, one short of how many payloads it holds, so a
    block filled to its cap still fits the width the cap asks for. A payload says where it ends by
    being read, so nothing goes between two of them, and one shape serves a fire, a question and an
    answer alike: what separates those is the header each payload carries, not this one.
]]
function Frames.running (over: number): Head
    local id = named (over)

    --[[
        The count is spelled in the bits rounding the id up to its byte, which were spare before it
        wanted them. What that buys is a block that never runs costing exactly what it did when no
        block could, and what it costs is a cap that a crowded namespace holds to more tightly.
    ]]
    local spare = BYTE - id % BYTE
    local head = headed ({ id, spare })

    return table.freeze ({
        fields = head.fields,
        bytes = head.bytes,
        write = head.write,
        read = head.read,
        runs = 2 ^ spare,
    })
end

--[[
    A fire from a definition that declared an instant. Each has one of its own, so these never run
    together and the block carries the instant where a run would have carried its count.
]]
function Frames.stamped (over: number): Head return headed ({ named (over), STAMP }) end

-- One question of a run: the id it is owed an answer under.
function Frames.asking (): Head return headed ({ ASKED }) end

-- One answer of a run: the question it answers, and whether it is an answer or a refusal.
function Frames.answering (): Head return headed ({ ASKED, OUTCOME }) end

--[[
    A newest packet's block: `{ defId, seq }`, or `{ defId, stamp, seq }`. It never runs, because a
    newest sender coalesces to one value before it is sequenced and a second would be the first.
]]
function Frames.newest (over: number, stamped: boolean): Head
    local id = named (over)
    return headed (if stamped then { id, STAMP, SEQ } else { id, SEQ })
end

-- A state section's block: `{ defId, kind }`, and everything after it is the section's own grammar.
function Frames.section (over: number): Head return headed ({ named (over), KIND }) end

--[[
    A newest block: `{ defId, which, more, seq }`, where `more` counts the fields riding behind
    the first. Several fields that moved over the same slots in one flush spell those slots once,
    so what follows the header is the run, and then one column of values a field that shares it.
]]
function Frames.stream (over: number, fields: number): Head
    return headed ({ named (over), named (fields), named (fields), SEQ })
end

-- One of those fields behind the first: which it is, and the order its own stream stands in.
function Frames.follow (fields: number): Head return headed ({ named (fields), SEQ }) end

--[[
    What one payload's block comes to, which is the header, the payload, and whatever follows it.

    Stated once: the three parts are the grammar, and a caller adding two of them is one who will
    eventually add the wrong two.
]]
function Frames.block (of: Head, payload: number): number return of.bytes + payload end

return table.freeze (Frames)
