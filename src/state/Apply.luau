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
    across the set and a slot is not. `net` is what the frame came to for each record and the whole
    of what a caller is told, `added`, `changed` and `gone` are that taken apart for the fan, `olds`
    is the record as it stood, and `shadow` is the slots a keyframe spoke for.
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

-- A baseline a keyframe stated, kept until every section of the frame has been read.
local function owes (of: Heard, held: { [number]: number }, slot: number, mark: number)
    local at = of.owed + 1

    of.owed = at
    of.holds[at] = held
    of.where[at] = slot
    of.marks[at] = mark
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

-- The same, for the lane that does not come through a section.
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
local function moved (of: Heard, id: number)
    local was = of.net[id]
    if was == ARRIVED or was == REPLACED then return end

    of.net[id] = CHANGED
end

-- A record taken away, which cancels an arrival rather than following it.
local function lost (of: Heard, store: Store.Store, id: number, why: Types.Cause)
    if of.net[id] == ARRIVED then
        of.net[id] = NOTHING
        return
    end

    of.net[id] = GONE
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
    for index = 1, frame.count do
        local id = store.ids[frame.slots[index]]
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

    for index = 1, frame.count do
        local slot = frame.slots[index]
        local id = frame.ids[index]
        local was = store.slotOf[id]

        snapped (of, store, id)
        Store.hold (store, id, slot)
        if gens ~= nil then gens[slot] = frame.gens[index] end

        shadow[slot] = true
        if was == nil then
            born (of, store, id)
        else
            moved (of, id)
        end
    end

    for field = 1, layout.def.fieldCount do
        local values = frame.values[field]
        local marks = frame.at[field]
        local held = store.prev[field]

        for index = 1, frame.count do
            local slot = frame.slots[index]

            Store.write (store, slot, field, values[index])
            if held ~= nil then owes (of, held, slot, marks[index]) end
        end
    end
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

    for place = 1, chosen.count do
        local field = chosen.fields[place]
        local under = frame.under[place]
        local values = frame.values[field]
        local marks = frame.at[field]
        local held = store.prev[field]

        for index = 1, frame.covered[place] do
            local slot = under[index]
            local id = ids[slot]
            if id == nil or shadow[slot] then continue end

            local before = store.columns[field][slot]

            snapped (of, store, id)
            Store.write (store, slot, field, values[index])
            if held ~= nil then held[slot] = marks[index] end

            -- A value that arrived as what the field already held is no change to report.
            if before ~= values[index] then moved (of, id) end
        end
    end
end

-- Public --------------------------------------------------------------

-- One record changed, said once however many times a frame says it.
function Apply.moved (of: Heard, id: number) moved (of, id) end

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

-- What a frame did to one set, empty, which a set holds one of for as long as it exists.
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
    for index = 1, of.owed do
        of.holds[index][of.where[index]] = of.marks[index]
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
