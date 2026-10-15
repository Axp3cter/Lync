--!strict
--!optimize 2
-- Sections into a store: what a receiver holds after each kind, what it is told, and what its
-- keyframes owe the next frame.

local Apply = require("@src/state/Apply")
local Codecs = require("@src/codec")
local Compile = require("@src/shape/Compile")
local Sections = require("@src/state/Sections")
local Store = require("@src/state/Store")
local Types = require("@src/Types")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")

local ROOM = 512
local CTX: Types.ValidateContext = table.freeze({ player = nil, now = 0, last = nil })
local AT = table.freeze({ file = "Game.Net", line = 1 })

type Rig = {
    def: any,
    sender: Store.Store,
    receiver: Store.Store,
    out: Sections.Layout,
    back: Sections.Layout,
    heard: Apply.Heard,
    b: buffer,
}

local function rigged(): Rig
    local fields = { score = Codecs.int(0, 100000), name = Codecs.str(0, 8) }
    local set = { kind = "set", of = Codecs.struct(fields), at = AT }
    local def: any = Compile.build("apply", { roster = set :: any }).byName.roster
    return {
        def = def,
        sender = Store.new(def),
        receiver = Store.new(def),
        out = Sections.of(def),
        back = Sections.of(def),
        heard = Apply.heard(),
        b = buffer.create(ROOM),
    }
end

-- A record on the sender, scoring ten times its id under its own name.
local function added(rig: Rig, id: number): number
    local slot = Store.bind(rig.sender, id)
    rig.sender.writers[rig.def.fieldIndex.score](slot, id, id * 10)
    rig.sender.writers[rig.def.fieldIndex.name](slot, id, `r{id}`)
    return slot
end

-- A keyframe of the listed slots, written by the sender and applied at the receiver.
local function keyframed(rig: Rig, slots: { number })
    local frame = rig.out.frame
    frame.count = #slots
    for index, slot in slots do
        frame.slots[index] = slot
        frame.ids[index] = rig.sender.ids[slot]
    end
    Sections.keyframe(rig.out, rig.b, 0, rig.sender.columns)
    local kind = Sections.taken(rig.back, rig.b, 0, rig.receiver.prev, CTX)
    Apply.section(rig.receiver, rig.back, kind, rig.heard)
end

-- A removal of the listed slots, applied at the receiver.
local function removed(rig: Rig, slots: { number })
    local frame = rig.out.frame
    frame.count = #slots
    for index, slot in slots do
        frame.slots[index] = slot
    end
    Sections.removal(rig.out, rig.b, 0)
    local kind = Sections.taken(rig.back, rig.b, 0, rig.receiver.prev, CTX)
    Apply.section(rig.receiver, rig.back, kind, rig.heard)
end

-- A delta of the score field on the listed slots, applied at the receiver.
local function scored(rig: Rig, slots: { number })
    local score = rig.def.fieldIndex.score
    local frame = rig.out.frame
    frame.count = #slots
    for index, slot in slots do
        frame.slots[index] = slot
    end
    local chosen = frame.chosen
    chosen.count = 1
    chosen.fields[1] = score
    chosen.full[1] = 1
    Sections.delta(rig.out, rig.b, 0, rig.sender.columns, rig.sender.prev)
    local kind = Sections.taken(rig.back, rig.b, 0, rig.receiver.prev, CTX)
    Apply.section(rig.receiver, rig.back, kind, rig.heard)
end

return {
    -- A keyframe binds the records at the sender's slots with every field whole, reports them as
    -- arrivals, and pays their baselines once settled.
    Harness.case("apply.keyframe", function()
        local rig = rigged()
        local score = rig.def.fieldIndex.score
        local one, two = added(rig, 1), added(rig, 2)
        keyframed(rig, { one, two })
        Expect.equal(rig.receiver.count, 2)
        Expect.equal(rig.receiver.rows[1], { score = 10, name = "r1" })
        Expect.equal(rig.receiver.rows[2], { score = 20, name = "r2" })
        Expect.equal(rig.receiver.slotOf[2], two)
        local gone, arrived, changed = Apply.parted(rig.heard)
        Expect.equal({ gone, arrived, changed }, { {}, { 1, 2 }, {} })

        local baseline = rig.receiver.prev[score] :: { [number]: number }
        Expect.equal(baseline[one], nil)
        Apply.settle(rig.heard)
        Expect.equal(baseline[one], 10)
        Expect.equal(baseline[two], 20)
        Expect.equal(rig.heard.owed, 0)
        Apply.forget(rig.heard)
        Expect.equal(next(rig.heard.net), nil)

        -- The same keyframe again is a change, not a second arrival.
        keyframed(rig, { one, two })
        gone, arrived, changed = Apply.parted(rig.heard)
        Expect.equal({ gone, arrived, changed }, { {}, {}, { 1, 2 } })
    end),

    -- A delta writes only what moved, records what was sent either way, keeps the record as it
    -- stood while somebody is watching, and is skipped on a slot a keyframe in the same frame
    -- already spoke for.
    Harness.case("apply.delta", function()
        local rig = rigged()
        local score = rig.def.fieldIndex.score
        local one, two = added(rig, 1), added(rig, 2)
        keyframed(rig, { one, two })
        Apply.settle(rig.heard)
        Apply.forget(rig.heard)
        local sent = rig.sender.prev[score] :: { [number]: number }
        sent[one], sent[two] = 10, 20

        rig.heard.watching = true
        rig.sender.writers[score](one, 1, 15)
        scored(rig, { one, two })
        Expect.equal(rig.receiver.rows[1].score, 15)
        Expect.equal(rig.receiver.rows[2].score, 20)
        local gone, arrived, changed = Apply.parted(rig.heard)
        Expect.equal({ gone, arrived, changed }, { {}, {}, { 1 } })
        Expect.equal(rig.heard.olds[1], { score = 10, name = "r1" })
        Expect.equal(rig.heard.olds[2], nil)
        local baseline = rig.receiver.prev[score] :: { [number]: number }
        Expect.equal({ baseline[one], baseline[two] }, { 15, 20 })
        Apply.settle(rig.heard)
        Apply.forget(rig.heard)

        sent[one] = 15
        rig.sender.writers[score](one, 1, 99)
        keyframed(rig, { one })
        scored(rig, { one })
        Expect.equal(rig.receiver.rows[1].score, 99)
        gone, arrived, changed = Apply.parted(rig.heard)
        Expect.equal({ gone, arrived, changed }, { {}, {}, { 1 } })
    end),

    -- A removal forgets the records it names and no others, reports them gone with their cause
    -- and the record as it stood, cancels an arrival from the same frame, and a slot this
    -- receiver does not hold is nothing.
    Harness.case("apply.removal", function()
        local rig = rigged()
        local one, two, three = added(rig, 1), added(rig, 2), added(rig, 3)
        keyframed(rig, { one, two })
        Apply.settle(rig.heard)
        Apply.forget(rig.heard)

        rig.heard.watching = true
        removed(rig, { one, three })
        Expect.equal(rig.receiver.count, 1)
        Expect.equal(rig.receiver.rows[1], nil)
        Expect.equal(rig.receiver.rows[2].name, "r2")
        local gone, arrived, changed = Apply.parted(rig.heard)
        Expect.equal({ gone, arrived, changed }, { { 1 }, {}, {} })
        Expect.equal(rig.heard.causes[1], "removed")
        Expect.equal(rig.heard.olds[1], { score = 10, name = "r1" })
        Apply.settle(rig.heard)
        Apply.forget(rig.heard)

        keyframed(rig, { three })
        removed(rig, { three })
        gone, arrived, changed = Apply.parted(rig.heard)
        Expect.equal({ gone, arrived, changed }, { {}, {}, {} })
    end),

    -- A clear reports every record gone as cleared and empties the partition, and a record
    -- established again after being taken away in the same frame is replaced.
    Harness.case("apply.clear-and-replace", function()
        local rig = rigged()
        local one, two = added(rig, 1), added(rig, 2)
        keyframed(rig, { one, two })
        Apply.settle(rig.heard)
        Apply.forget(rig.heard)

        removed(rig, { one })
        keyframed(rig, { one })
        local gone, arrived, changed = Apply.parted(rig.heard)
        Expect.equal({ gone, arrived, changed }, { { 1 }, { 1 }, {} })
        Apply.settle(rig.heard)
        Apply.forget(rig.heard)

        Sections.clear(rig.out, rig.b, 0)
        local kind = Sections.taken(rig.back, rig.b, 0, rig.receiver.prev, CTX)
        Apply.section(rig.receiver, rig.back, kind, rig.heard)
        gone, arrived, changed = Apply.parted(rig.heard)
        Expect.equal({ gone, arrived, changed }, { { 1, 2 }, {}, {} })
        Expect.equal(rig.heard.causes[2], "cleared")
        Expect.equal(rig.receiver.count, 0)
        Expect.equal(next(rig.receiver.rows), nil)
    end),
}
