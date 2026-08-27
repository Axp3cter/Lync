--!strict
--!optimize 2
--[[
    A run of ascending slots, as the bytes it becomes and the three things a reader turns away.
]]

local Catalog = require ("@src/kernel/Catalog")
local Slots = require ("@src/state/Slots")

local Expect = require ("@test/harness/Expect")
local Harness = require ("@test/harness")

-- Constants -----------------------------------------------------------

const BROKEN = Catalog.SECTION
const ROOM = 256

-- What a run of this lane refuses under, worded so a failure names which of the three it was.
const SAID: Slots.Said = table.freeze ({
    many = "more records than its bytes could hold",
    order = "its slots out of order",
    pad = "its slot run padded",
})

-- What a caller carries beside each slot, which for every kind but a keyframe is nothing.
const LONE = 0

-- Private -------------------------------------------------------------

-- A run written from the slots given, which a forgery names in an order no writer would.
local function wrote (slots: { number }): buffer
    local b = buffer.create (ROOM)
    Slots.wrote (b, 0, slots, {}, #slots)

    return b
end

-- What a read of those bytes refused under, and the phrase it named, or nothing where it took them.
local function refused (b: buffer): (string?, string?)
    local ok, why = pcall (Slots.read, b, 0, {}, {}, LONE, SAID)
    if ok or type (why) ~= "table" then return nil, nil end

    local held = why :: { code: string, facts: { said: string } }
    return held.code, held.facts.said
end

-- Public --------------------------------------------------------------

return {
    --[[
        The slots a run was written from, read back as themselves. Every refusal below is about a
        run no writer produces, so the one a writer does produce is what says the refusals are
        about forgeries rather than about the form itself.
    ]]
    Harness.case ("slots.round-trip", function ()
        for _, slots in { { 1 }, { 1, 2 }, { 1, 2, 3, 4 }, { 3, 40, 41, 900 } } do
            local back: { number } = {}
            local count = Slots.read (wrote (slots), 0, back, {}, LONE, SAID)

            Expect.equal (count, #slots)
            for index = 1, count do
                Expect.equal (back[index], slots[index])
            end
        end
    end),

    --[[
        A run whose every step is forged to nothing. A step goes down one under itself, so nothing
        at all is a step of one and no bytes name a slot twice, which is why the order below is
        asked about the first slot alone and never about the run behind it.
    ]]
    Harness.case ("slots.a-repeat-cannot-be-spelled", function ()
        local b = wrote ({ 1, 2, 4 })
        buffer.writeu8 (b, 2, 0)

        local back: { number } = {}
        local count = Slots.read (b, 0, back, {}, LONE, SAID)

        Expect.equal (count, 3)
        for index = 1, count do
            Expect.equal (back[index], index)
        end
    end),

    -- A run opening on no slot at all, which is the same refusal read at the first entry.
    Harness.case ("slots.refuses-a-first-of-nothing", function ()
        local code, said = refused (wrote ({ 0, 2 }))

        Expect.equal (code, BROKEN)
        Expect.equal (said, SAID.order)
    end),

    --[[
        A count larger than the bytes behind it could hold. The count arrives before anything it
        drives, so a reader believing one is a reader walking off the end of what it was handed,
        and the bound is taken in bits because a packed step spends fewer than a byte.
    ]]
    Harness.case ("slots.refuses-a-count-past-its-bytes", function ()
        local b = wrote ({ 1, 2, 3 })

        local tight = buffer.create (3)
        buffer.copy (tight, 0, b, 0, 3)
        buffer.writeu8 (tight, 0, 0xFE)

        local code, said = refused (tight)
        Expect.equal (code, BROKEN)
        Expect.equal (said, SAID.many)
    end),

    --[[
        A run whose padding is not zero. The bits over the last step go down as nothing, so a run
        carrying anything else in them spells one list two ways, and a reader taking either would
        make two frames of one flush.
    ]]
    Harness.case ("slots.refuses-a-pad", function ()
        local b = wrote ({ 1, 2, 4 })

        -- The count, then the first slot, then the two steps packed a bit each with six left over.
        buffer.writeu8 (b, 2, bit32.bor (buffer.readu8 (b, 2), 0x80))

        local code, said = refused (b)
        Expect.equal (code, BROKEN)
        Expect.equal (said, SAID.pad)
    end),
}
