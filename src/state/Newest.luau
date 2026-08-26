--!strict
--!optimize 2
-- The lane a newest field travels on: what has moved, how often it may say so, and in what order.

local Apply = require ("@src/state/Apply")
local Bits = require ("@src/kernel/Bits")
local Fieldset = require ("@src/state/Fieldset")
local Protocol = require ("@src/wire/Protocol")
local Sections = require ("@src/state/Sections")
local Sequence = require ("@src/wire/Sequence")
local Store = require ("@src/state/Store")
local Types = require ("@src/Types")
local Varint = require ("@src/wire/Varint")

local Newest = {}

-- Constants -----------------------------------------------------------

-- What one fire carries, which a section of this lane is a block of and so has to fit inside.
const CAP = Protocol.UNRELIABLE_CAP

-- The bits one group of a varint carries, which is what a slot's width comes to bytes through.
const GROUP = Protocol.VARINT_BITS

--[[
    The generation a slot stands at, which is a byte a record at its widest and one bit less at its
    narrowest, so an entry is bounded by the byte.
]]
const STAMPED = 1

--[[
    The least an entry can spend, which is a slot varint at its shortest and nothing else that has
    to be there, and is what a count is held against before the lists it drives are walked.
]]
const LEAST = 1

--[[
    Where a stream header keeps the two fields a sender states outright, the third being the
    sequence. Which slot that one is comes off the form rather than being written down here, since
    the order is the wire's and its home is the frame that lays the header out.
]]
const WHOSE = 1
const WHICH = 2

const TOO_MANY = "a newest section naming more records than its own bytes could hold"
const OUT_OF_ORDER = "a newest section naming its slots out of order"

-- Types ---------------------------------------------------------------

-- One partition's streams, one to a newest field, and the four numbers each of them keeps.
export type Streams = {
    at: { number },
    last: { number? },
    heard: { number },
    took: { boolean },
    from: { number },
}

-- One set's newest lane, compiled: which fields ride it, how each is compared, and what it costs.
export type Lane = {
    read layout: Sections.Layout,
    read fields: { number },
    read place: { [number]: number },
    read streams: boolean,
    read hz: { number? },
    read mark: { (value: any) -> any },
    read spent: { number },
    read opening: number,
    read seqAt: number,
    key: any,
    read slots: { number },
    read gens: { number },
    read marks: { any },
    read values: { any },
    read head: { number },
}

-- Private -------------------------------------------------------------

-- What a field with no one index is remembered by, which is the value a caller handed over.
local function same (value: any): any return value end

-- Public --------------------------------------------------------------

-- A set's newest lane, as the closures and the scratch one partition's flush is written through.
function Newest.of (layout: Sections.Layout): Lane
    local def = layout.def
    local reach = #def.newestFields

    local fields = table.create (reach) :: { number }
    local place: { [number]: number } = {}
    local hz = table.create (reach) :: { number? }
    local mark = table.create (reach) :: { (value: any) -> any }
    local spent = table.create (reach) :: { number }

    local key = def.keyIndex
    local opening = def.stream.bytes + 1 + (if key == nil then 0 else def.fieldBuilt[key].maxBytes)

    local head = table.create (def.stream.fields, 0)
    head[WHOSE] = def.id

    for index, field in def.newestFields do
        local built = def.fieldBuilt[field]
        local grid = built.grid

        fields[index] = field
        place[field] = index
        hz[index] = built.cell.newestHz
        mark[index] = if grid == nil then same else grid.toIndex :: any
        spent[index] = STAMPED + layout.each[field]
    end

    return {
        layout = layout,
        fields = table.freeze (fields),
        place = table.freeze (place),
        streams = next (place) ~= nil,
        hz = table.freeze (hz),
        mark = table.freeze (mark),
        spent = table.freeze (spent),
        opening = opening,
        seqAt = def.stream.fields,
        key = nil,
        slots = {},
        gens = {},
        marks = {},
        values = {},
        head = head,
    }
end

-- A partition's streams, none of them having said anything yet.
function Newest.streams (of: Lane): Streams
    local reach = #of.fields
    local held: Streams = { at = {}, last = {}, heard = {}, took = {}, from = {} }

    for index = 1, reach do
        held.at[index] = 0
        held.heard[index] = 0
        held.took[index] = false
        held.from[index] = 0
    end
    return held
end

-- Every stream back to having said nothing, which a partition emptied is for all of them.
function Newest.sweep (of: Streams)
    for index = 1, #of.at do
        of.at[index] = 0
        of.last[index] = nil
        of.heard[index] = 0
        of.took[index] = false
        of.from[index] = 0
    end
end

-- Every newest field of the listed slots, recorded as sent.
function Newest.established (of: Lane, store: Store.Store, slots: { number }, count: number)
    for at = 1, #of.fields do
        local field = of.fields[at]
        local column = store.columns[field]
        local sent = store.sent[field] :: { [number]: any }
        local mark = of.mark[at]

        for index = 1, count do
            local slot = slots[index]
            sent[slot] = mark (column[slot])
        end
    end
end

-- What one stream has to say this flush, gathered where a section reads it.
function Newest.changed (
    of: Lane,
    streams: Streams,
    store: Store.Store,
    at: number,
    now: number
): number
    if not Sequence.opened (now, streams.last[at], of.hz[at]) then return 0 end

    local field = of.fields[at]
    local column = store.columns[field]
    local sent = store.sent[field] :: { [number]: any }
    local gens = store.gens :: { [number]: number }
    local mark = of.mark[at]
    local ids = store.ids

    --[[
        How many fit one fire, worked out here because the slot is the piece a schema cannot bound.
        A partition of a hundred spells every slot in a byte and one of a million in three, and the
        difference is a section three times the size for the same values.
    ]]
    local wide = math.max (1, math.ceil (Bits.width (store.high) / GROUP))
    local reach = math.max (1, (CAP - of.opening) // (wide + of.spent[at]))
    local held = 0

    for slot = streams.from[at] + 1, store.high do
        if ids[slot] == nil then continue end

        local value = column[slot]
        local one = mark (value)
        if one == sent[slot] then continue end

        held += 1
        of.slots[held] = slot
        of.values[held] = value
        of.marks[held] = one
        of.gens[held] = gens[slot]

        if held == reach then break end
    end

    streams.from[at] = if held < reach then 0 else of.slots[held]
    return held
end

-- One stream's section, and the stream moved on past it.
function Newest.section (
    of: Lane,
    streams: Streams,
    store: Store.Store,
    at: number,
    b: buffer,
    pos: number,
    now: number,
    count: number
): number
    local layout = of.layout
    local def = layout.def
    local field = of.fields[at]

    local seq = Sequence.next (streams.at[at])
    streams.at[at] = seq

    of.head[WHICH] = field - 1
    of.head[of.seqAt] = seq
    def.stream.write (b, pos, of.head)

    local held = pos + def.stream.bytes
    local key = def.keyIndex
    if key ~= nil then held = def.fieldBuilt[key].write (b, held, of.key) end

    held = Varint.write (b, held, count)
    for index = 1, count do
        held = Varint.write (b, held, of.slots[index])
    end

    held = layout.generations.whole (b, held, of.gens :: any, layout.spare, count)
    held = layout.fields[field].whole (b, held, of.values, layout.spare, count)

    local sent = store.sent[field] :: { [number]: any }
    for index = 1, count do
        sent[of.slots[index]] = of.marks[index]
    end

    streams.last[at] = now
    return held
end

--[[
    Whatever section is at this position, as the stream it is for, the sequence it carries and the
    byte past it.
]]
function Newest.taken (
    of: Lane,
    b: buffer,
    pos: number,
    ctx: Types.ValidateContext
): (number, number, number, number)
    local layout = of.layout
    local def = layout.def

    def.stream.read (b, pos, of.head)
    local at = of.place[of.head[WHICH] + 1]
    local seq = of.head[of.seqAt]

    local held = pos + def.stream.bytes
    local key = def.keyIndex
    if key ~= nil then
        held, of.key = def.fieldBuilt[key].read (b, held, ctx)
    end

    local count
    count, held = Varint.read (b, held)
    if count * LEAST > buffer.len (b) - held then Fieldset.broken (TOO_MANY) end

    local last = 0
    for index = 1, count do
        local slot
        slot, held = Varint.read (b, held)
        if slot <= last then Fieldset.broken (OUT_OF_ORDER) end

        of.slots[index] = slot
        last = slot
    end

    held = layout.generations.back (b, held, of.gens :: any, layout.spare, count, ctx)
    held = layout.fields[of.fields[at]].back (b, held, of.values, layout.spare, count, ctx)

    return at, seq, count, held
end

--[[
    A section applied, where it is newer than what this stream has taken and where a slot's
    generation is the one its keyframe stated.
]]
function Newest.apply (
    of: Lane,
    streams: Streams,
    store: Store.Store,
    heard: Apply.Heard,
    at: number,
    seq: number,
    count: number
)
    if streams.took[at] and not Sequence.isNewer (seq, streams.heard[at]) then return end

    streams.took[at] = true
    streams.heard[at] = seq

    local field = of.fields[at]
    local gens = store.gens :: { [number]: number }
    local ids = store.ids

    for index = 1, count do
        local slot = of.slots[index]
        local id = ids[slot]
        if id == nil or gens[slot] ~= of.gens[index] then continue end

        -- A value the record already holds is not a change and is not written.
        local value = of.values[index]
        if store.columns[field][slot] == value then continue end

        Apply.snapped (heard, store, id)
        Store.write (store, slot, field, value)
        Apply.moved (heard, id)
    end
end

return table.freeze (Newest)
