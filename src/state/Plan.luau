--!strict
--!optimize 2
-- One partition's flush: what it owes the wire, in order, cut to what a section holds.

local Coalesce = require ("@src/state/Coalesce")
local Protocol = require ("@src/wire/Protocol")
local Sections = require ("@src/state/Sections")
local Store = require ("@src/state/Store")
local Wide = require ("@src/kernel/Wide")

local Plan = {}

-- Constants -----------------------------------------------------------

const KEYFRAME = Protocol.SECTION_KEYFRAME
const DELTA = Protocol.SECTION_DELTA
const REMOVAL = Protocol.SECTION_REMOVAL
const CLEAR = Protocol.SECTION_CLEAR

-- What one section may carry.
const BOUND = Protocol.SECTION_BYTES

--[[
    What the widest varint spends, which is what a slot is bounded by and so what an entry of a
    removal costs and what the slot half of every other entry costs.
]]
const WIDEST = Protocol.VARINT_GROUPS

const BYTE = Protocol.BYTE_BITS

const NONE = Wide.NONE

-- The stages a partition goes through, which is the order they are applied in.
const CLEARING = 1
const DROPPING = CLEARING + 1
const MAKING = DROPPING + 1
const MOVING = MAKING + 1
const SETTLED = MOVING + 1

-- What a field's coverage says: it changed on every slot the section lists, or it did not.
const COVERS = 1
const SOME = 0

-- What a record's field says about itself in a presence run, which is one bit either way.
const CARRIES = 1
const EMPTY = 0

-- Types ---------------------------------------------------------------

-- What one partition owes the wire, as a flush's mutations folded to their net effect.
export type Dirt = {
    ops: { [number]: Coalesce.Kind },
    masks: { [number]: Wide.Word },
    freed: { [number]: number },
    cleared: boolean,
}

-- One partition: which key it is, what it holds, and what it owes.
export type Partition = {
    read key: any,
    read store: Store.Store,
    read dirt: Dirt,
}

-- What a flush may spend on state, and what it has spent.
export type Budget = {
    read target: number,
    spent: number,
    took: boolean,
}

-- One set's planner: what a section of it costs, and the scratch one partition's flush fills.
export type Plan = {
    read layout: Sections.Layout,
    read bit: { integer },
    read room: number,
    read kinds: { number },
    read cuts: { number },
    read counts: { number },
    read dropped: { number },
    read made: { number },
    read moved: { number },
    read masks: { integer },
    stage: number,
    stop: number,
    at: number,
}

-- Private -------------------------------------------------------------

-- A scratch list holding exactly what was put in it, which is what a sort reads its length from.
local function trimmed (of: { number }, count: number, was: number)
    for index = count + 1, was do
        of[index] = nil
    end
end

-- How many entries of a delta fit one section, worked out per partition from the fields it moved.
local function fitted (of: Plan, whole: Wide.Word): number
    local gained = of.layout.gained

    local spent = 0
    local selected = 0

    local mask = whole
    while Wide.any (mask) do
        spent += gained[Wide.lowest (mask)]
        selected += 1
        mask = Wide.without (mask)
    end

    return of.room // (BYTE * (WIDEST + spent) + selected)
end

-- A removal's slots, which is the whole of what one carries.
local function removing (of: Plan, from: number, count: number)
    local frame = of.layout.frame

    frame.count = count
    table.move (of.dropped, from, from + count - 1, 1, frame.slots)
end

-- A keyframe's slots, the records bound to them, and the generations those bindings stand at.
local function making (of: Plan, store: Store.Store, from: number, count: number)
    local frame = of.layout.frame
    local gens = store.gens
    local ids = store.ids

    frame.count = count
    for index = 1, count do
        local slot = of.made[from + index - 1]

        frame.slots[index] = slot
        frame.ids[index] = ids[slot]
        if gens ~= nil then frame.gens[index] = gens[slot] end
    end
end

-- A delta's slots, the fields they moved between them, and which of them each field reached.
local function moving (of: Plan, from: number, count: number)
    local frame = of.layout.frame
    local chosen = frame.chosen
    local masks = of.masks

    frame.count = count

    local union = NONE
    for index = 1, count do
        local place = from + index - 1

        frame.slots[index] = of.moved[place]
        union = Wide.union (union, masks[place])
    end

    local reached = 0
    local mask = union
    while Wide.any (mask) do
        local field = Wide.lowest (mask)
        mask = Wide.without (mask)

        reached += 1
        chosen.fields[reached] = field

        local one = of.bit[field]
        local present = frame.present[reached]
        local covered = 0

        for index = 1, count do
            local on = if Wide.meets (masks[from + index - 1], one) then CARRIES else EMPTY
            present[index] = on
            covered += on
        end

        chosen.full[reached] = if covered == count then COVERS else SOME
    end

    chosen.count = reached
end

-- The frame filled for whichever kind is next, which a clear does not have and the rest do.
local function filled (of: Plan, store: Store.Store, kind: number, from: number, count: number)
    if kind == KEYFRAME then
        making (of, store, from, count)
    elseif kind == DELTA then
        moving (of, from, count)
    elseif kind == REMOVAL then
        removing (of, from, count)
    end
end

-- Whichever section the frame is filled for, laid down at the cursor it was handed.
local function laid (of: Plan, store: Store.Store, b: buffer, pos: number, kind: number): number
    local layout = of.layout

    if kind == KEYFRAME then return Sections.keyframe (layout, b, pos, store.columns) end
    if kind == DELTA then return Sections.delta (layout, b, pos, store.columns, store.prev) end
    if kind == REMOVAL then return Sections.removal (layout, b, pos) end

    return Sections.clear (layout, b, pos)
end

-- The records a removal carried, taken off what the flush still owes.
local function released (of: Plan, dirt: Dirt, from: number, count: number)
    for index = from, from + count - 1 do
        local slot = of.dropped[index]
        local id = dirt.freed[slot]
        local op = dirt.ops[id]

        dirt.freed[slot] = nil
        if op == "replace" then
            dirt.ops[id] = "add"
            continue
        end
        if op == "add" then continue end

        dirt.ops[id] = nil
        dirt.masks[id] = nil
    end
end

-- The records a keyframe or a delta carried, taken off what the flush still owes.
local function forgotten (
    store: Store.Store,
    dirt: Dirt,
    slots: { number },
    from: number,
    count: number
)
    for index = from, from + count - 1 do
        local id = store.ids[slots[index]]

        dirt.ops[id] = nil
        dirt.masks[id] = nil
    end
end

local function retired (of: Plan, part: Partition, kind: number, from: number, count: number)
    local dirt = part.dirt

    if kind == CLEAR then
        dirt.cleared = false
        return
    end

    if kind == REMOVAL then
        released (of, dirt, from, count)
        return
    end

    forgotten (part.store, dirt, if kind == KEYFRAME then of.made else of.moved, from, count)
end

-- Which section is next and which of the gathered entries it takes, and the cursor moved past it.
local function staged (of: Plan, dirt: Dirt): (number, number, number)
    if of.stage == CLEARING then
        of.stage = DROPPING
        of.at = 1

        if dirt.cleared then return CLEAR, 0, 0 end
    end

    while of.stage <= of.stop do
        local stage = of.stage
        local left = of.counts[stage] - of.at + 1

        if left > 0 then
            local count = math.min (left, math.max (1, of.cuts[stage]))
            local from = of.at

            of.at += count
            return of.kinds[stage], from, count
        end

        of.stage = stage + 1
        of.at = 1
    end

    return SETTLED, 0, 0
end

-- Public --------------------------------------------------------------

-- How many whole records a keyframe of this set fits in the bytes it is handed.
function Plan.keyframes (of: Sections.Layout, bytes: number): number
    return (math.min (bytes, BOUND) - of.opening) // of.entry
end

-- A set's planner, as the costs a section of it comes to and the scratch a partition fills.
function Plan.of (layout: Sections.Layout): Plan
    local reach = layout.def.fieldCount
    local bit = table.create (reach) :: { integer }

    for field = 1, reach do
        bit[field] = Coalesce.touched (NONE, field)
    end

    local spare = BOUND - layout.opening

    return {
        layout = layout,
        bit = table.freeze (bit),
        room = (spare - layout.set.widest) * BYTE,
        kinds = table.freeze ({ [DROPPING] = REMOVAL, [MAKING] = KEYFRAME, [MOVING] = DELTA }),
        cuts = {
            [DROPPING] = spare // WIDEST,
            [MAKING] = Plan.keyframes (layout, BOUND),
            [MOVING] = 1,
        },
        counts = { [DROPPING] = 0, [MAKING] = 0, [MOVING] = 0 },
        dropped = {},
        made = {},
        moved = {},
        masks = {},
        stage = SETTLED,
        stop = SETTLED,
        at = 1,
    }
end

-- What a partition owes, empty, which a partition holds one of for as long as it exists.
function Plan.dirt (): Dirt return { ops = {}, masks = {}, freed = {}, cleared = false } end

-- What one flush of one namespace may spend on state, and what it has spent.
function Plan.budget (bytes: number): Budget return { target = bytes, spent = 0, took = false } end

-- The same one again, ready for another flush, for a caller that keeps one rather than making one.
function Plan.reset (of: Budget, bytes: number): Budget
    local held = of :: { target: number, spent: number, took: boolean }
    held.target, held.spent, held.took = bytes, 0, false

    return of
end

--[[
    Whether a flush has already spent what it was given, which both openers ask first.

    What it keeps a full flush from doing is writing sections it is about to throw away, and it is
    exact: the target is spent, so nothing further can fit whatever it costs.
]]
local function spent (of: Budget): boolean return of.took and of.spent >= of.target end

-- A plan opened on one partition and one half of the order, which is what both halves share.
local function opening (of: Plan, part: Partition, from: number, to: number)
    of.layout.frame.key = part.key
    of.stage = from
    of.stop = to
    of.at = 1
end

-- What one partition takes away, gathered and put in order, and whether it takes anything.
function Plan.dropping (of: Plan, budget: Budget, part: Partition): boolean
    if spent (budget) then return false end

    local dirt = part.dirt

    local fell = 0
    for slot in dirt.freed do
        fell += 1
        of.dropped[fell] = slot
    end

    trimmed (of.dropped, fell, of.counts[DROPPING])
    table.sort (of.dropped)

    of.counts[DROPPING] = fell
    opening (of, part, CLEARING, DROPPING)

    return dirt.cleared or fell > 0
end

-- What one partition puts down, gathered and put in order, and whether it puts anything.
function Plan.making (of: Plan, budget: Budget, part: Partition): boolean
    if spent (budget) then return false end

    local store = part.store
    local dirt = part.dirt
    local counts = of.counts

    local builds, shifts = 0, 0
    local whole = NONE

    for id, op in dirt.ops do
        if op == "remove" then continue end

        if op == "update" then
            shifts += 1
            of.moved[shifts] = store.slotOf[id]
            whole = Wide.union (whole, dirt.masks[id])
            continue
        end

        builds += 1
        of.made[builds] = store.slotOf[id]
    end

    trimmed (of.made, builds, counts[MAKING])
    trimmed (of.moved, shifts, counts[MOVING])

    table.sort (of.made)
    table.sort (of.moved)

    for index = 1, shifts do
        of.masks[index] = dirt.masks[store.ids[of.moved[index]]]
    end

    counts[MAKING], counts[MOVING] = builds, shifts
    of.cuts[MOVING] = fitted (of, whole)
    opening (of, part, MAKING, MOVING)

    return builds + shifts > 0
end

-- The next section of the partition this was opened on, written at the cursor it was handed.
function Plan.next (
    of: Plan,
    budget: Budget,
    part: Partition,
    b: buffer,
    pos: number
): (number?, number)
    local store = part.store
    local kind, from, count = staged (of, part.dirt)
    if kind == SETTLED then return nil, pos end

    filled (of, store, kind, from, count)
    local ends = laid (of, store, b, pos, kind)

    local spent = ends - pos
    if budget.took and budget.spent + spent > budget.target then
        of.stage = SETTLED
        return nil, pos
    end

    budget.spent += spent
    budget.took = true

    retired (of, part, kind, from, count)
    return kind, ends
end

return table.freeze (Plan)
