--!strict
--!optimize 2
-- The state sections: one partition's flush, as the bytes it becomes.

local Bits = require ("@src/kernel/Bits")
local Column = require ("@src/shape/emit/Column")
local Compile = require ("@src/shape/Compile")
local Fieldset = require ("@src/state/Fieldset")
local Protocol = require ("@src/wire/Protocol")
local Shape = require ("@src/shape")
local Slots = require ("@src/state/Slots")
local Types = require ("@src/Types")
local Varint = require ("@src/wire/Varint")

local Sections = {}

-- Constants -----------------------------------------------------------

const KEYFRAME = Protocol.SECTION_KEYFRAME
const DELTA = Protocol.SECTION_DELTA
const REMOVAL = Protocol.SECTION_REMOVAL
const CLEAR = Protocol.SECTION_CLEAR

-- The bits a keyframe states a slot's generation in, which is what the modulus asks for.
const GENS = Bits.width (Protocol.NEWEST_GENS - 1)

-- The presence run's element, and the value of the flag that says a field covered every slot.
const PRESENT = 1
const COVERS = 1

-- What a field's history has to be worth before a difference is taken against it.
const CHEAPER = 8

-- How wide an element a run packs, past which a column is a stride rather than a run.
const RUNS = Protocol.BIT_CEILING

-- What the widest varint spends, which is what a slot and an id are each bounded by.
const WIDEST = Protocol.VARINT_GROUPS

-- What a keyframe carries beside each slot, which is the id it is bound to and at least a byte.
const PAIRED = Protocol.BYTE_BITS

-- What the other kinds carry beside a slot, which is nothing at all.
const LONE = 0

-- What a slot run of this lane refuses under.
const SAID: Slots.Said = table.freeze ({
    many = "a section naming more records than its own bytes could hold",
    order = "a section naming its slots out of order",
    pad = "a section padding its slot run with something other than zero",
})
const GENERATIONS = "a generation run"
const PRESENCE = "a presence run"

-- Types ---------------------------------------------------------------

-- One field's values across a partition's slots, and the last index each was sent at.
export type Columns = { { [number]: any } }
export type History = { { [number]: number }? }

-- One section, as the caller fills it and as a reader fills it back.
export type Frame = {
    key: any,
    count: number,
    slots: { number },
    steps: { number },
    ids: { number },
    gens: { number },
    chosen: Fieldset.Chosen,
    present: { { number } },
    under: { { number } },
    covered: { number },
    values: { { any } },
    at: { { number } },
}

-- One set's sections, compiled: what each field's column is, and what a section of them costs.
export type Layout = {
    read def: Compile.Set,
    read set: Fieldset.Fieldset,
    read fields: { Field },
    read generations: Field,
    read presence: Field,
    read frame: Frame,
    read held: { number },
    read spare: { number },
    read opening: number,
    read entry: number,
    read each: { number },
    read gained: { number },
}

-- What one field of a set becomes at both ends: whole always, and as a difference where it can.
export type Field = {
    read whole: Column.Write,
    read back: Column.Read,
    read gain: Column.Gain?,
    read regain: Column.Regain?,
}

-- Private -------------------------------------------------------------

-- A run of the section's own numbers, which is a field-shaped thing with no difference to take.
local function run (width: number, said: string): Field
    local whole, back = Column.bits (width, said)
    return { whole = whole, back = back, gain = nil, regain = nil }
end

-- One field, as the pair or two that lay its column down.
local function made (built: Shape.Built): Field
    local grid = built.grid
    local deltas = grid ~= nil and built.marker ~= "newest" and grid.width > CHEAPER

    local whole: Column.Write, back: Column.Read
    if grid == nil or grid.width > RUNS then
        -- Stating its indices only where something will take a difference against them.
        whole, back = Column.each (built.write, built.read, if deltas then grid else nil)
    else
        whole, back = Column.grid (built.tag, built.paths, built.expected, grid)
    end

    if not deltas then return { whole = whole, back = back, gain = nil, regain = nil } end

    local gain, regain = Column.gain (
        built.tag,
        built.paths,
        built.expected,
        grid :: any,
        built.marker ~= "monotonic"
    )
    return { whole = whole, back = back, gain = gain, regain = regain }
end

-- The slots a field covers and where its values sit, gathered where the column reads them.
local function gathered (
    of: Frame,
    place: number,
    field: number,
    columns: Columns,
    count: number
): number
    local under = of.under[place]
    local values = of.values[field]
    local held = columns[field]

    if of.chosen.full[place] == COVERS then
        for index = 1, count do
            local slot = of.slots[index]
            under[index] = slot
            values[index] = held[slot]
        end

        of.covered[place] = count
        return count
    end

    local present = of.present[place]
    local reach = 0

    for index = 1, count do
        if present[index] == 0 then continue end

        local slot = of.slots[index]
        reach += 1
        under[reach] = slot
        values[reach] = held[slot]
    end

    of.covered[place] = reach
    return reach
end

-- The same slots, without the values, which is what a reader has before a column has answered.
local function covering (of: Frame, place: number, count: number): number
    local under = of.under[place]

    if of.chosen.full[place] == COVERS then
        table.move (of.slots, 1, count, 1, under)
        of.covered[place] = count
        return count
    end

    local present = of.present[place]
    local reach = 0

    for index = 1, count do
        if present[index] == 0 then continue end

        reach += 1
        under[reach] = of.slots[index]
    end

    of.covered[place] = reach
    return reach
end

-- A section's header and the key of the partition it is about, which every kind opens with.
local function opened (of: Layout, b: buffer, pos: number, kind: number): number
    local def = of.def
    of.held[2] = kind
    def.head.write (b, pos, of.held)

    local at = pos + def.head.bytes
    local key = def.keyIndex
    if key == nil then return at end

    return def.fieldBuilt[key].write (b, at, of.frame.key)
end

-- Public --------------------------------------------------------------

-- A set's sections, as the closures and the scratch one partition's flush is written through.
function Sections.of (def: Compile.Set): Layout
    local reach = def.fieldCount
    local fields = table.create (reach) :: { Field }
    local each = table.create (reach) :: { number }
    local gained = table.create (reach) :: { number }

    local values = table.create (reach) :: { { any } }
    local at = table.create (reach) :: { { number } }
    local present = table.create (reach) :: { { number } }
    local under = table.create (reach) :: { { number } }

    local entry = WIDEST * 2 + if #def.newestFields == 0 then 0 else 1

    for index = 1, reach do
        local built = def.fieldBuilt[index]
        local one = made (built)

        fields[index] = one
        each[index] = built.maxBytes
        gained[index] = if one.gain == nil then each[index] else WIDEST
        entry += each[index]

        values[index] = {}
        at[index] = {}
        present[index] = {}
        under[index] = {}
    end

    local key = def.keyIndex
    local set = Fieldset.of (reach)

    return table.freeze ({
        def = def,
        set = set,
        fields = table.freeze (fields),
        generations = table.freeze (run (GENS, GENERATIONS)),
        presence = table.freeze (run (PRESENT, PRESENCE)),
        frame = {
            key = nil,
            count = 0,
            slots = {},
            steps = {},
            ids = {},
            gens = {},
            chosen = Fieldset.chosen (),
            present = present,
            under = under,
            covered = {},
            values = values,
            at = at,
        },
        held = { def.id, KEYFRAME },
        spare = {},
        opening = def.head.bytes + (if key == nil then 0 else def.fieldBuilt[key].maxBytes) + 1,
        entry = entry,
        each = table.freeze (each),
        gained = table.freeze (gained),
    })
end

--[[
    A keyframe: the listed slots, the ids they are bound to, the generations they stand at, and
    every field of every one of them.
]]
function Sections.keyframe (of: Layout, b: buffer, pos: number, columns: Columns): number
    local frame = of.frame
    local def = of.def
    local count = frame.count

    local at = Slots.wrote (b, opened (of, b, pos, KEYFRAME), frame.slots, frame.steps, count)
    local ids = frame.ids
    local steps = frame.steps

    --[[
        Each id as the step from the id before it. A keyframe names its records in slot order and
        slots go out as records arrive, so ids numbered in the order they were added climb, and a
        run that climbs packs at the width its widest step needs. One that does not is spelled in
        signed varints, which is the only form that carries a caller numbering them any way at all.
    ]]
    local climbs = true
    for index = 2, count do
        local step = ids[index] - ids[index - 1]

        steps[index - 1] = step
        if step <= 0 then
            climbs = false
            break
        end
    end

    local width = if climbs then Slots.width (steps, count - 1) else 0
    buffer.writeu8 (b, at, width)
    at += 1

    if count ~= 0 then at = Varint.writeSigned (b, at, ids[1]) end
    if width ~= 0 then
        at = Slots.laid (b, at, steps, count - 1, width)
    else
        for index = 2, count do
            at = Varint.writeSigned (b, at, ids[index] - ids[index - 1])
        end
    end

    if #def.newestFields > 0 then
        at = of.generations.whole (b, at, frame.gens :: any, of.spare, count)
    end

    for field = 1, def.fieldCount do
        local values = frame.values[field]
        local held = columns[field]

        for index = 1, count do
            values[index] = held[frame.slots[index]]
        end

        at = of.fields[field].whole (b, at, values, frame.at[field], count)
    end

    return at
end

-- A delta: the fields that changed, the slots they changed on, and the differences.
function Sections.delta (of: Layout, b: buffer, pos: number, columns: Columns, was: History): number
    local frame = of.frame
    local chosen = frame.chosen
    local count = frame.count

    local at = of.set.write (b, opened (of, b, pos, DELTA), chosen)
    at = Slots.wrote (b, at, frame.slots, frame.steps, count)

    for place = 1, chosen.count do
        if chosen.full[place] ~= COVERS then
            at = of.presence.whole (b, at, frame.present[place] :: any, of.spare, count)
        end

        local field = chosen.fields[place]
        local covered = gathered (frame, place, field, columns, count)

        local one = of.fields[field]
        local gain = one.gain
        local values, answered = frame.values[field], frame.at[field]

        if gain == nil then
            at = one.whole (b, at, values, answered, covered)
            continue
        end

        local base = was[field] :: { [number]: number }
        at = gain (b, at, values, frame.under[place], base, answered, covered)
    end

    return at
end

--[[
    A removal: the slots and nothing else, deliberately, since a cause would announce a record past
    the audience that was meant to be the only thing that knew of it.
]]
function Sections.removal (of: Layout, b: buffer, pos: number): number
    local frame = of.frame

    return Slots.wrote (b, opened (of, b, pos, REMOVAL), frame.slots, frame.steps, frame.count)
end

-- A clear: the partition and nothing about it, which is the whole of what emptying one says.
function Sections.clear (of: Layout, b: buffer, pos: number): number
    return opened (of, b, pos, CLEAR)
end

-- Which kind of section is at this position and which partition it is about, and nothing else.
function Sections.about (
    of: Layout,
    b: buffer,
    pos: number,
    ctx: Types.ValidateContext
): (number, any)
    local def = of.def
    local held = of.held

    def.head.read (b, pos, held)

    local key = def.keyIndex
    if key == nil then return held[2], nil end

    local _, value = def.fieldBuilt[key].read (b, pos + def.head.bytes, ctx)
    return held[2], value
end

-- Whatever section is at this position, as its kind and the byte past it.
function Sections.taken (
    of: Layout,
    b: buffer,
    pos: number,
    was: History,
    ctx: Types.ValidateContext
): (number, number)
    local frame = of.frame
    local def = of.def
    local held = of.held

    def.head.read (b, pos, held)
    local kind = held[2]
    local at = pos + def.head.bytes

    local key = def.keyIndex
    if key ~= nil then
        at, frame.key = def.fieldBuilt[key].read (b, at, ctx)
    end
    if kind == CLEAR then return kind, at end

    local chosen = frame.chosen
    if kind == DELTA then at = of.set.read (b, at, chosen) end

    local count
    count, at = Slots.read (
        b,
        at,
        frame.slots,
        frame.steps,
        if kind == KEYFRAME then PAIRED else LONE,
        SAID
    )
    frame.count = count
    if kind == REMOVAL then return kind, at end

    if kind == KEYFRAME then
        local ids = frame.ids
        local steps = frame.steps

        local width = buffer.readu8 (b, at)
        at += 1

        local last = 0
        if count ~= 0 then
            last, at = Varint.readSigned (b, at)
            ids[1] = last
        end

        if width ~= 0 then
            local clean
            at, clean = Slots.taken (b, at, steps, count - 1, width)
            if not clean then Fieldset.broken (SAID.pad) end

            for index = 2, count do
                last += steps[index - 1]
                ids[index] = last
            end
        else
            for index = 2, count do
                local step
                step, at = Varint.readSigned (b, at)

                last += step
                ids[index] = last
            end
        end

        if #def.newestFields > 0 then
            at = of.generations.back (b, at, frame.gens :: any, of.spare, count, ctx)
        end

        for field = 1, def.fieldCount do
            at = of.fields[field].back (b, at, frame.values[field], frame.at[field], count, ctx)
        end

        return kind, at
    end

    for place = 1, chosen.count do
        if chosen.full[place] ~= COVERS then
            at = of.presence.back (b, at, frame.present[place] :: any, of.spare, count, ctx)
        end

        local covered = covering (frame, place, count)
        local field = chosen.fields[place]

        local one = of.fields[field]
        local regain = one.regain
        local values, answered = frame.values[field], frame.at[field]

        if regain == nil then
            at = one.back (b, at, values, answered, covered, ctx)
            continue
        end

        local base = was[field] :: { [number]: number }
        at = regain (b, at, values, frame.under[place], base, answered, covered)
    end

    return kind, at
end

return table.freeze (Sections)
