--!strict
--!optimize 2
-- One block of a frame: the bytes a producer laid down, and how many places still hold them.

local Bytes = require ("@src/wire/Bytes")

local Blocks = {}

-- Constants -----------------------------------------------------------

--[[
    The five classes a reliable frame's blocks drain in, which is that drain order as the buckets a
    queue has.
]]
const RESPONSE = 1
const REQUEST = RESPONSE + 1
const PACKET = REQUEST + 1
const ESTABLISH = PACKET + 1
const DELTA = ESTABLISH + 1

-- What a block on the lossy lane is classed as, which is nothing.
const LOOSE = 0

-- What a released block points at until its next build, so a pooled record pins no bytes.
const EMPTY = buffer.create (0)

-- Types ---------------------------------------------------------------

-- One block, queued and copied and eventually let go.
export type Block = {
    buf: buffer,
    len: number,
    class: number,
    seq: number,
    refs: { Instance }?,
    rc: number,
}

-- State ---------------------------------------------------------------

-- Blocks nobody holds any more, kept for the next build rather than collected.
local free: { Block } = {}

-- Public --------------------------------------------------------------

Blocks.RESPONSE = RESPONSE
Blocks.REQUEST = REQUEST
Blocks.PACKET = PACKET
Blocks.ESTABLISH = ESTABLISH
Blocks.DELTA = DELTA
Blocks.LOOSE = LOOSE

-- How many classes there are, which is the last of them, since they are numbered from one.
Blocks.CLASSES = DELTA

-- What a caller runs to fill one block, which is everything this layer refuses to know.
export type Produce = (b: buffer, pos: number) -> number

--[[
    One block over bytes already in scratch, sealed at a length rather than run from a producer,
    because a planner writes a section to decide whether it fits and the frame has moved on by the
    time the block is wanted. What is sealed is exactly the bytes written, so a frame is the sum of
    its blocks, and `refs` is copied because the array it came from is about to be refilled.
]]
function Blocks.sealed (
    into: buffer,
    len: number,
    class: number,
    seq: number,
    refs: { Instance }?
): Block
    local held = if refs == nil then nil else table.clone (refs)
    local sealed = Bytes.seal (into, len)

    local of = table.remove (free)
    if of == nil then
        return { buf = sealed, len = len, class = class, seq = seq, refs = held, rc = 1 }
    end

    of.buf = sealed
    of.len = len
    of.class = class
    of.seq = seq
    of.refs = held
    of.rc = 1
    return of
end

-- One block, built by running a producer into scratch and sealing what it wrote.
function Blocks.build (
    into: buffer,
    class: number,
    seq: number,
    refs: { Instance }?,
    produce: Produce
): Block
    return Blocks.sealed (into, produce (into, 0), class, seq, refs)
end

-- One more hold, taken by whatever is about to keep a block past the call that handed it over.
function Blocks.retain (of: Block)
    of.rc += 1
end

-- One hold fewer, and the pool where the last one leaves it.
function Blocks.release (of: Block)
    of.rc -= 1
    if of.rc > 0 then return end

    of.buf = EMPTY
    of.len = 0
    of.refs = nil
    table.insert (free, of)
end

-- Every block in a list let go, and the list emptied.
function Blocks.drain (held: { Block })
    for _, of in held do
        Blocks.release (of)
    end
    table.clear (held)
end

return table.freeze (Blocks)
