--!strict
--!optimize 2
-- A run of ascending slots, as the bytes it becomes and the three things a reader turns away.

local Catalog = require("@src/kernel/Catalog")
local Slots = require("@src/state/Slots")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")
local Rng = require("@test/harness/Rng")

local ROOM = 256

-- What a run of this lane refuses under, worded so a failure names which of the three it was.
local SAID: Slots.Said = table.freeze({
    many = "more records than its bytes could hold",
    order = "its slots out of order",
    pad = "its slot run padded",
})

-- What a caller carries beside each slot, which for every kind but a keyframe is nothing.
local LONE = 0

local function wrote(slots: { number }): (buffer, number)
    local b = buffer.create(ROOM)
    return b, Slots.wrote(b, 0, slots, {}, #slots)
end

local function refused(b: buffer): (string?, string?)
    local ok, why = pcall(Slots.read, b, 0, {}, {}, LONE, SAID)
    if ok or type(why) ~= "table" then return nil, nil end
    return (why :: any).code, (why :: any).facts.said
end

return {
    -- The slots a run was written from read back as themselves, both ends stopping together, and
    -- a run of nothing costing one byte.
    Harness.case("slots.round-trip", function()
        for _, slots in { {}, { 1 }, { 1, 2 }, { 1, 2, 3, 4 }, { 3, 40, 41, 900 } } do
            local b, after = wrote(slots)
            local back: { number } = {}
            local count, ends = Slots.read(b, 0, back, {}, LONE, SAID)
            Expect.equal(count, #slots)
            Expect.equal(ends, after)
            for index = 1, count do
                Expect.equal(back[index], slots[index])
            end
        end
        local _, after = wrote({})
        Expect.equal(after, 1)
    end),

    -- A partition moving together spells every step as nothing and spends no bits on them, and a
    -- run too spread out to pack falls back to varints.
    Harness.case("slots.widths", function()
        local steps = { 0, 0, 0 }
        Expect.equal(Slots.width(steps, 3), 1)
        Expect.equal(Slots.width({ 1, 3, 2 }, 3), 3)
        Expect.equal(Slots.width({ 200 }, 1), 0)
        Expect.equal(Slots.width({ 1 }, 1), 0)

        -- Seven bits is the widest step worth packing: sixteen of them take fourteen bytes where
        -- varints take sixteen, and one bit wider takes the same sixteen and is left to them.
        Expect.equal(Slots.width(table.create(16, 127), 16), 8)
        Expect.equal(Slots.width(table.create(16, 255), 16), 0)

        local _, packed = wrote({ 5, 6, 7, 8, 9 })
        Expect.equal(packed, 2)
        local _, spread = wrote({ 5, 300, 1000 })
        Expect.equal(spread, 1 + 1 + 2 + 2)
    end),

    -- A step goes down one under itself, so no bytes can name a slot twice: every step forged to
    -- nothing reads back as consecutive slots.
    Harness.case("slots.a-repeat-cannot-be-spelled", function()
        local b = wrote({ 1, 2, 4 })
        buffer.writeu8(b, 2, 0)
        local back: { number } = {}
        local count = Slots.read(b, 0, back, {}, LONE, SAID)
        Expect.equal(count, 3)
        Expect.equal({ back[1], back[2], back[3] }, { 1, 2, 3 })
    end),

    -- A run opening on no slot, a count larger than the bytes behind it could hold, and a pad
    -- that is not zero, each refused under its own phrase.
    Harness.case("slots.refuses", function()
        local code, said = refused((wrote({ 0, 2 })))
        Expect.equal(code, Catalog.SECTION)
        Expect.equal(said, SAID.order)

        local b = wrote({ 1, 2, 3 })
        local tight = buffer.create(3)
        buffer.copy(tight, 0, b, 0, 3)
        buffer.writeu8(tight, 0, 0xFE)
        code, said = refused(tight)
        Expect.equal(code, Catalog.SECTION)
        Expect.equal(said, SAID.many)

        local padded = wrote({ 1, 2, 4 })
        buffer.writeu8(padded, 2, bit32.bor(buffer.readu8(padded, 2), 0x80))
        code, said = refused(padded)
        Expect.equal(code, Catalog.SECTION)
        Expect.equal(said, SAID.pad)
    end),

    -- Any ascending run, out and back, and the bytes it spends never past a varint a slot.
    Harness.property("slots.round-trips", "leaves", function(rng: Rng.Rng)
        local count = rng:int(0, 40)
        local slots = {}
        local last = 0
        for index = 1, count do
            last += rng:int(1, if rng:bool() then 2 else 300)
            slots[index] = last
        end
        local b, after = wrote(slots)
        local back: { number } = {}
        local got, ends = Slots.read(b, 0, back, {}, LONE, SAID)
        Expect.equal(got, count)
        Expect.equal(ends, after)
        for index = 1, count do
            Expect.equal(back[index], slots[index])
        end
    end),
}
