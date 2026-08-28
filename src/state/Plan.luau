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

--[[
    The word operations under their own names. `Wide` picks its carrier once when it loads, so
    every one of these is the same function for the life of the place, and naming it here is a
    lookup a walk over the fields of every slot would otherwise make for each of them.
]]
const ANY = Wide.any
const LOWEST = Wide.lowest
const MEETS = Wide.meets
const GATHERED = Wide.gathered
const SHARED = Wide.shared
const WITHOUT = Wide.without

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
    while ANY (mask) do
        spent += gained[LOWEST (mask)]
        selected += 1
        mask = WITHOUT (mask)
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

    --[[
        What any record moved and what every one of them did. The second answers, for a field, the
        question the walk below would otherwise put to each record in turn, and it is the same
        question however many fields the union comes to.
    ]]
    local union = GATHERED (NONE, masks, from, count)
    local every = if count == 0 then NONE else SHARED (masks[from], masks, from, count)

    for index = 1, count do
        frame.slots[index] = of.moved[from + index - 1]
    end

    local reached = 0
    local mask = union
    while ANY (mask) do
        local field = LOWEST (mask)
        mask = WITHOUT (mask)

        reached += 1
        chosen.fields[reached] = field

        local one = of.bit[field]

        --[[
            A field every record moved is spoken for by the count alone, so the walk that would
            say which of them carry it is not run and what it would have written is not read.
        ]]
        if MEETS (every, one) then
            chosen.full[reached] = COVERS
            continue
        end

        local present = frame.present[reached]
        for index = 1, count do
            present[index] = if MEETS (masks[from + index - 1], one) then CARRIES else EMPTY
        end

        chosen.full[reached] = SOME
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
    local dropped = of.dropped
    local freed = dirt.freed
    local ops = dirt.ops
    local masks = dirt.masks

    for index = from, from + count - 1 do
        local slot = dropped[index]
        local id = freed[slot]
        local op = ops[id]

        freed[slot] = nil
        if op == "replace" then
            ops[id] = "add"
            continue
        end
        if op == "add" then continue end

        ops[id] = nil
        masks[id] = nil
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
    local ids = store.ids
    local ops = dirt.ops
    local masks = dirt.masks

    for index = from, from + count - 1 do
        local id = ids[slots[index]]

        ops[id] = nil
        masks[id] = nil
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

-- An empty one, which a partition keeps for as long as it exists.
function Plan.dirt (): Dirt return { ops = {}, masks = {}, freed = {}, cleared = false } end

function Plan.budget (bytes: number): Budget return { target = bytes, spent = 0, took = false } end

-- A budget ready for another flush, for a caller that keeps one rather than making one.
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

-- What one partition puts down and moves, gathered and put in order, and whether it has any.
function Plan.making (of: Plan, budget: Budget, part: Partition): boolean
    if spent (budget) then return false end

    local store = part.store
    local dirt = part.dirt
    local counts = of.counts

    --[[
        The tables the walks below fill and read, taken once. A partition is one store and one dirt
        list however many records it holds, so reaching either through it at every record asks
        after something that was settled before the walk began.
    ]]
    local made = of.made
    local moved = of.moved
    local dirty = dirt.masks
    local slotOf = store.slotOf

    local builds, shifts = 0, 0

    for id, op in dirt.ops do
        if op == "remove" then continue end

        if op == "update" then
            shifts += 1
            moved[shifts] = slotOf[id]
            continue
        end

        builds += 1
        made[builds] = slotOf[id]
    end

    trimmed (made, builds, counts[MAKING])
    trimmed (moved, shifts, counts[MOVING])

    table.sort (made)
    table.sort (moved)

    local masks = of.masks
    local ids = store.ids

    for index = 1, shifts do
        masks[index] = dirty[ids[moved[index]]]
    end

    --[[
        What every moved record between them owes, folded off the list the walk above just laid
        out. The same words go by twice otherwise, once to be counted into the whole and once to
        be put in order, and only the second of those has to happen a record at a time.
    ]]
    local whole = GATHERED (NONE, masks, 1, shifts)

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
