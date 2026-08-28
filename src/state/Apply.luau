--!strict
--!optimize 2
-- The one path a section becomes a store by, which both machines run over the same sections.

local Protocol = require ("@src/wire/Protocol")
local Sections = require ("@src/state/Sections")
local Store = require ("@src/state/Store")
local Types = require ("@src/Types")

local Apply = {}

-- Constants -----------------------------------------------------------

const KEYFRAME = Protocol.SECTION_KEYFRAME
const DELTA = Protocol.SECTION_DELTA
const REMOVAL = Protocol.SECTION_REMOVAL

-- The two causes a section can be read as, which is every cause there is.
const REMOVED: Types.Cause = "removed"
const CLEARED: Types.Cause = "cleared"

-- What a frame came to for one record, which is everything a caller can be told about one.
const NOTHING = 0
const ARRIVED = NOTHING + 1
const CHANGED = ARRIVED + 1
const GONE = CHANGED + 1
const REPLACED = GONE + 1

-- Types ---------------------------------------------------------------

--[[
    What a frame did to one set, held per set rather than per partition because an id is unique
    across the set and a slot is not. `net` is the whole of what a caller is told, and `added`,
    `changed` and `gone` are that same answer taken apart for the fan.
]]
export type Heard = {
    watching: boolean,
    net: { [number]: number },
    left: { [number]: Store.Store },
    added: { number },
    changed: { number },
    gone: { number },
    causes: { [number]: Types.Cause },
    olds: { [number]: Store.Record },
    shadow: { [Store.Store]: { [number]: boolean } },
    owed: number,
    holds: { { [number]: number } },
    where: { number },
    marks: { number },
}

-- Private -------------------------------------------------------------

-- What a partition's keyframes have spoken for this frame, made where the first one is applied.
local function shadowed (of: Heard, store: Store.Store): { [number]: boolean }
    local held = of.shadow[store]
    if held ~= nil then return held end

    local made: { [number]: boolean } = {}
    of.shadow[store] = made
    return made
end

-- Whether the record as it stood before this frame is worth keeping at all.
local function kept (of: Heard, id: number): boolean return of.watching and of.olds[id] == nil end

-- The record as it stood, kept where it lies, because this one is on its way out.
local function shed (of: Heard, store: Store.Store, id: number)
    if not kept (of, id) then return end

    local row = store.rows[id]
    if row == nil then return end

    of.olds[id] = row
end

-- The record as it stood before this frame, taken once and only where something wants it.
local function snapped (of: Heard, store: Store.Store, id: number)
    if not kept (of, id) then return end

    local row = store.rows[id]
    if row == nil then return end

    of.olds[id] = table.clone (row)
end

-- Reached from outside for the lane that does not come through a section.
function Apply.snapped (of: Heard, store: Store.Store, id: number) snapped (of, store, id) end

-- A record established, which is an arrival unless this frame has already taken it away.
local function born (of: Heard, store: Store.Store, id: number)
    local was = of.net[id]

    if was == GONE then
        of.net[id] = if of.left[id] == store then REPLACED else CHANGED
        return
    end
    if was == CHANGED or was == REPLACED then return end

    of.net[id] = ARRIVED
end

--[[
    A record this frame changed, marked once however many of its fields moved. An arrival stands,
    because a record that came and then moved is one a receiver is told about once and told it
    arrived, and a change into existence is not a thing a viewer can be handed.
]]
local function moved (net: { [number]: number }, id: number)
    local was = net[id]
    if was == CHANGED or was == ARRIVED or was == REPLACED then return end

    net[id] = CHANGED
end

-- A record taken away, which cancels an arrival rather than following it.
local function lost (of: Heard, store: Store.Store, id: number, why: Types.Cause)
    local net = of.net
    if net[id] == ARRIVED then
        net[id] = NOTHING
        return
    end

    net[id] = GONE
    of.left[id] = store
    of.causes[id] = why
end

--[[
    A partition emptied, and every record it held reported gone.

    Read before the store is emptied rather than after, which is the only order there is: what a
    clear says is every record this receiver held, and afterwards it holds none.
]]
local function emptied (store: Store.Store, of: Heard)
    for id in store.rows do
        shed (of, store, id)
        lost (of, store, id, CLEARED)
    end

    Store.clear (store)
end

--[[
    The listed records gone. A slot this receiver does not hold is a specified no-op rather than a
    fault, since a removal is broadcast and an audience is what decides who was holding one.
]]
local function dropped (store: Store.Store, frame: Sections.Frame, of: Heard)
    local ids = store.ids
    local slots = frame.slots

    for index = 1, frame.count do
        local id = ids[slots[index]]
        if id == nil then continue end

        shed (of, store, id)
        Store.unbind (store, id)
        lost (of, store, id, REMOVED)
    end
end

--[[
    The listed records established: bound to the slots the other machine chose, at the generations
    it stated, with every field of every one of them written whole.
]]
local function established (store: Store.Store, layout: Sections.Layout, of: Heard)
    local frame = layout.frame
    local shadow = shadowed (of, store)
    local gens = store.gens

    --[[
        What the walk below asks of the frame and the store rather than of the record, reached
        once. Every one of them is the same table for every record the keyframe carries, and
        whether anything wants a record as it stood is a question about the frame besides.
    ]]
    local slots = frame.slots
    local ids = frame.ids
    local slotOf = store.slotOf
    local stamps = frame.gens
    local wanted = of.watching

    local net = of.net

    for index = 1, frame.count do
        local slot = slots[index]
        local id = ids[index]

        if wanted then snapped (of, store, id) end
        if gens ~= nil then gens[slot] = stamps[index] end

        shadow[slot] = true
        if slotOf[id] == nil then
            born (of, store, id)
        else
            moved (net, id)
        end
    end

    --[[
        The records put where the keyframe says only once every one of them has been read against
        the store as it stood. What the walk above asks of a record is whether this receiver held
        it, and holding any of them is what stops that question answering the same way twice.
    ]]
    Store.holds (store, ids, slots, frame.count)

    --[[
        A baseline a keyframe states is put off until every section of the frame has been read,
        since a later one may speak for the same slot. One list takes them all however many fields
        the keyframe names, which is what makes the three arrays the same for every record.
    ]]
    local owed = of.owed
    local holds = of.holds
    local where = of.where
    local told = of.marks

    for field = 1, layout.def.fieldCount do
        local held = store.prev[field]

        --[[
            Every slot this field names put down in one crossing. A keyframe speaks for all of them
            and skips none, so what the store is handed is the section and not a slot out of it,
            and what a field owes its baseline is a walk of its own or no walk at all.
        ]]
        store.spreads[field] (slots, ids, frame.values[field], frame.count)
        if held == nil then continue end

        local marks = frame.at[field]

        for index = 1, frame.count do
            owed += 1
            holds[owed] = held
            where[owed] = slots[index]
            told[owed] = marks[index]
        end
    end

    of.owed = owed
end

--[[
    The listed differences applied, for the slots this receiver holds and this frame has not already
    spoken for.
]]
local function advanced (store: Store.Store, layout: Sections.Layout, of: Heard)
    local frame = layout.frame
    local chosen = frame.chosen
    local shadow = shadowed (of, store)
    local ids = store.ids

    --[[
        Whether anything wants the record as it stood, which is a question about the frame and not
        about the slot. Every slot below would be told the same, and what one is told settles only
        whether to take a copy, so the answer is worth having before the walk rather than inside it.
    ]]
    local wanted = of.watching
    local net = of.net

    --[[
        Whether this frame spoke for any slot at all. A delta arriving without a keyframe beside it
        has spoken for none, and the table itself answers that once where every slot of every field
        would otherwise ask it over.
    ]]
    local spoken = next (shadow) ~= nil

    for place = 1, chosen.count do
        local field = chosen.fields[place]
        local under = frame.under[place]
        local values = frame.values[field]
        local marks = frame.at[field]
        local held = store.prev[field]

        -- The column this section speaks for, reached once rather than once a slot it names.
        local column = store.columns[field]
        local put = store.writers[field]

        for index = 1, frame.covered[place] do
            local slot = under[index]
            local id = ids[slot]
            if id == nil or (spoken and shadow[slot]) then continue end

            local before = column[slot]
            local value = values[index]

            --[[
                A value that arrived as what the field already held is no change to report, and
                none to write: the column stands at it, and so does the row the writer keeps
                beside it. What was sent is still recorded, since that is what a delta is read
                against and it is owed whether the value moved or not.
            ]]
            if before ~= value then
                if wanted then snapped (of, store, id) end

                put (slot, id, value)
                moved (net, id)
            end

            if held ~= nil then held[slot] = marks[index] end
        end
    end
end

-- Public --------------------------------------------------------------

-- One record changed, said once however many times a frame says it.
function Apply.moved (of: Heard, id: number) moved (of.net, id) end

-- What the frame came to, as the three lists the fan reads, each in id order.
function Apply.parted (of: Heard): ({ number }, { number }, { number })
    local gone, added, changed = of.gone, of.added, of.changed

    table.clear (gone)
    table.clear (added)
    table.clear (changed)

    for id, net in of.net do
        if net == GONE or net == REPLACED then table.insert (gone, id) end
        if net == ARRIVED or net == REPLACED then table.insert (added, id) end
        if net == CHANGED then table.insert (changed, id) end
    end

    table.sort (gone)
    table.sort (added)
    table.sort (changed)

    return gone, added, changed
end

-- One of these, empty, which a set holds for as long as it exists.
function Apply.heard (): Heard
    return {
        watching = false,
        net = {},
        left = {},
        added = {},
        changed = {},
        gone = {},
        causes = {},
        olds = {},
        shadow = {},
        owed = 0,
        holds = {},
        where = {},
        marks = {},
    }
end

-- One section, into the partition it is about.
function Apply.section (store: Store.Store, layout: Sections.Layout, kind: number, of: Heard)
    if kind == KEYFRAME then
        established (store, layout, of)
        return
    end

    if kind == DELTA then
        advanced (store, layout, of)
        return
    end

    if kind == REMOVAL then
        dropped (store, layout.frame, of)
        return
    end

    emptied (store, of)
end

-- The frame over: what its keyframes owe, paid, and what they spoke for, forgotten.
function Apply.settle (of: Heard)
    local holds = of.holds
    local where = of.where
    local told = of.marks

    for index = 1, of.owed do
        holds[index][where[index]] = told[index]
    end
    of.owed = 0

    for _, held in of.shadow do
        table.clear (held)
    end
end

--[[
    What the frame did, forgotten, which is what a caller does once it has said so.

    Apart from the settling because the two answer to different things: the baselines are owed to
    the next frame and cannot wait on anybody, and this waits on every listener having run.
]]
function Apply.forget (of: Heard)
    table.clear (of.net)
    table.clear (of.left)
    table.clear (of.added)
    table.clear (of.changed)
    table.clear (of.gone)
    table.clear (of.causes)
    table.clear (of.olds)
end

return table.freeze (Apply)
