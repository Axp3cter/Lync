--!strict
--!optimize 2
-- One partition's flush planned: the sections it owes in order, cut to a section and a budget,
-- and the dirt each one retires.

local Coalesce = require("@src/state/Coalesce")
local Codecs = require("@src/codec")
local Compile = require("@src/shape/Compile")
local Plan = require("@src/state/Plan")
local Protocol = require("@src/wire/Protocol")
local Sections = require("@src/state/Sections")
local Store = require("@src/state/Store")
local Types = require("@src/Types")
local Wide = require("@src/kernel/Wide")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")

local ROOM = 4096
local PLENTY = 1e9
local CTX: Types.ValidateContext = table.freeze({ player = nil, now = 0, last = nil })
local WHERE = table.freeze({ file = "Game.Net", line = 1 })

type Rig = {
    def: any,
    store: Store.Store,
    plan: Plan.Plan,
    part: Plan.Partition,
    reader: Sections.Layout,
    b: buffer,
}

local function rigged(): Rig
    local fields = { hp = Codecs.int(0, 100), name = Codecs.str(0, 8) }
    local set = { kind = "set", of = Codecs.struct(fields), at = WHERE }
    local def: any = Compile.build("plan", { roster = set :: any }).byName.roster
    local store = Store.new(def)
    return {
        def = def,
        store = store,
        plan = Plan.of(Sections.of(def)),
        part = { key = nil, store = store, dirt = Plan.dirt() },
        reader = Sections.of(def),
        b = buffer.create(ROOM),
    }
end

-- A record added to the store and to the dirt, with its fields written.
local function added(of: Rig, id: number, hp: number, name: string)
    local slot = Store.bind(of.store, id)
    of.store.writers[of.def.fieldIndex.hp](slot, id, hp)
    of.store.writers[of.def.fieldIndex.name](slot, id, name)
    of.part.dirt.ops[id] = Coalesce.merge(of.part.dirt.ops[id], "add")
end

local function updated(of: Rig, id: number, field: string, value: any)
    local dirt = of.part.dirt
    of.store.writers[of.def.fieldIndex[field]](of.store.slotOf[id], id, value)
    dirt.ops[id] = Coalesce.merge(dirt.ops[id], "update")
    dirt.masks[id] = Coalesce.touched(dirt.masks[id] or Wide.NONE, of.def.fieldIndex[field])
end

local function removed(of: Rig, id: number)
    local dirt = of.part.dirt
    local slot = Store.unbind(of.store, id) :: number
    local was = dirt.ops[id]
    dirt.ops[id] = Coalesce.merge(was, "remove")
    if was ~= "add" then dirt.freed[slot] = id end
end

-- Every section the plan writes for one flush, as its kind and the frame read back.
local function flushed(
    of: Rig,
    target: number?
): { { kind: number, count: number, slots: { number } } }
    local budget = Plan.budget(target or PLENTY)
    local out = {}
    local pos = 0
    local function drain()
        while true do
            local kind, ends = Plan.next(of.plan, budget, of.part, of.b, pos)
            if kind == nil then return end
            local got = Sections.taken(of.reader, of.b, pos, of.store.prev, CTX)
            Expect.equal(got, kind)
            local frame = of.reader.frame
            local slots = table.move(
                frame.slots,
                1,
                if kind == Protocol.SECTION_CLEAR then 0 else frame.count,
                1,
                {}
            )
            table.insert(out, { kind = kind, count = frame.count, slots = slots })
            pos = ends
        end
    end
    if Plan.dropping(of.plan, budget, of.part) then drain() end
    if Plan.making(of.plan, budget, of.part) then drain() end
    return out
end

return {
    -- Adds go as one keyframe naming every new slot, updates as one delta with the fields each
    -- moved, and each retires its dirt so the next flush owes nothing.
    Harness.case("plan.adds-then-updates", function()
        local of = rigged()
        added(of, 10, 5, "a")
        added(of, 11, 6, "b")
        added(of, 12, 7, "c")
        local first = flushed(of)
        Expect.equal(#first, 1)
        Expect.equal(first[1].kind, Protocol.SECTION_KEYFRAME)
        Expect.equal(first[1].slots, { 1, 2, 3 })
        Expect.equal(of.reader.frame.values[of.def.fieldIndex.name][2], "b")
        Expect.equal(next(of.part.dirt.ops), nil)
        Expect.equal(#flushed(of), 0)

        updated(of, 10, "hp", 50)
        updated(of, 12, "hp", 70)
        updated(of, 12, "name", "cc")
        local second = flushed(of)
        Expect.equal(#second, 1)
        Expect.equal(second[1].kind, Protocol.SECTION_DELTA)
        Expect.equal(second[1].slots, { 1, 3 })
        local chosen = of.reader.frame.chosen
        Expect.equal(chosen.count, 2)
        Expect.equal(
            { chosen.fields[1], chosen.fields[2] },
            { of.def.fieldIndex.hp, of.def.fieldIndex.name }
        )
        Expect.equal({ chosen.full[1], chosen.full[2] }, { 1, 0 })
        Expect.equal(next(of.part.dirt.masks), nil)
    end),

    -- Removals go first as one section of their slots, a clear before them, and a record added
    -- and removed in one flush owes nothing at all.
    Harness.case("plan.removes-and-clears", function()
        local of = rigged()
        added(of, 1, 1, "a")
        added(of, 2, 2, "b")
        added(of, 3, 3, "c")
        flushed(of)
        removed(of, 1)
        removed(of, 3)
        updated(of, 2, "hp", 9)
        local out = flushed(of)
        Expect.equal(out[1].kind, Protocol.SECTION_REMOVAL)
        Expect.equal(out[1].slots, { 1, 3 })
        Expect.equal(out[2].kind, Protocol.SECTION_DELTA)
        Expect.equal(next(of.part.dirt.freed), nil)

        added(of, 4, 4, "d")
        removed(of, 4)
        Expect.equal(#flushed(of), 0)
        Expect.equal(next(of.part.dirt.ops), nil)

        of.part.dirt.cleared = true
        local cleared = flushed(of)
        Expect.equal(cleared[1].kind, Protocol.SECTION_CLEAR)
        Expect.equal(of.part.dirt.cleared, false)
    end),

    -- A record removed and added again in one flush is a removal and then a keyframe at a fresh
    -- slot, since the receiver has to drop the old one before it is handed the new.
    Harness.case("plan.replaces", function()
        local of = rigged()
        added(of, 1, 1, "a")
        flushed(of)
        removed(of, 1)
        added(of, 1, 2, "aa")
        Expect.equal(of.part.dirt.ops[1], "replace")
        local out = flushed(of)
        Expect.equal(
            { out[1].kind, out[2].kind },
            { Protocol.SECTION_REMOVAL, Protocol.SECTION_KEYFRAME }
        )
        Expect.equal(out[2].slots, { 2 })
        Expect.equal(next(of.part.dirt.ops), nil)
    end),

    -- A budget stops the plan after the section that would overrun it, leaving that section's
    -- dirt owed, and a spent budget opens nothing.
    Harness.case("plan.budget", function()
        local of = rigged()
        for id = 1, 6 do
            added(of, id, id, "x")
        end
        flushed(of)
        for id = 1, 6 do
            updated(of, id, "hp", id * 10)
        end
        local budget = Plan.budget(1)
        Expect.equal(Plan.making(of.plan, budget, of.part), true)
        of.plan.cuts[4] = 2
        local kind, ends = Plan.next(of.plan, budget, of.part, of.b, 0)
        Expect.equal(kind, Protocol.SECTION_DELTA)
        Expect.holds(ends > 1, "the first section did not go out whole")
        Expect.equal(budget.took, true)
        kind = Plan.next(of.plan, budget, of.part, of.b, ends)
        Expect.equal(kind, nil)
        local left = 0
        for _ in of.part.dirt.ops do
            left += 1
        end
        Expect.equal(left, 4)
        Expect.equal(Plan.making(of.plan, budget, of.part), false)

        Plan.reset(budget, PLENTY)
        Expect.equal(budget.spent, 0)
        Expect.equal(#flushed(of), 1)
    end),

    -- What a keyframe of the set fits, and the plan's own cuts.
    Harness.case("plan.cuts", function()
        local of = rigged()
        local layout = of.plan.layout
        local bound = Protocol.SECTION_BYTES
        Expect.equal(Plan.keyframes(layout, bound), (bound - layout.opening) // layout.entry)
        Expect.equal(Plan.keyframes(layout, layout.opening + layout.entry * 2), 2)
        Expect.equal(of.plan.cuts[2], (bound - layout.opening) // Protocol.VARINT_GROUPS)
        Expect.equal(of.plan.cuts[3], Plan.keyframes(layout, bound))
    end),
}
