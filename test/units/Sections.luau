--!strict
--!optimize 2
--[[
    One partition's flush, as the bytes a section becomes. Every other check about a set drives one
    through two machines, where this drives the layout itself, which is where a frame nobody could
    have written is turned away.
]]

local Catalog = require ("@src/kernel/Catalog")
local Compile = require ("@src/shape/Compile")
local Lync = require ("@src")
local Protocol = require ("@src/wire/Protocol")
local Sections = require ("@src/state/Sections")
local Types = require ("@src/Types")

local Expect = require ("@test/harness/Expect")
local Harness = require ("@test/harness")

-- Constants -----------------------------------------------------------

const SPACE = "sections"
const SET = "roster"
const FIELD = "score"

const ROOM = 512
const AT = 0

--[[
    Slots that climb by two and ids that climb by one, which is what puts the pad in one run and
    not the other: four steps of two bits fill a byte exactly, and four of one bit leave four over.
    A pad anywhere else in this section would be a second way to reach the refusal below.
]]
const SLOTS = table.freeze ({ 1, 3, 5, 7, 9 })
const IDS = table.freeze ({ 1, 2, 3, 4, 5 })

--[[
    Where the ids' steps go down: the header, the count with the slots' width, the first slot, the
    slots' steps, the width the ids take, and the first id. Held to below, since a layout that
    moved would put this check on some other run's bytes and read as a check that still passes.
]]
const STEPS = 6

-- What a reader is handed about the moment, which a section reads nothing of.
const CTX: Types.ValidateContext = table.freeze ({ player = nil, now = 0, last = nil })

-- Private -------------------------------------------------------------

-- The one set this file drives, compiled the way a namespace compiles one.
local function compiled (): any
    local held = Compile.build (
        SPACE,
        { [SET] = Lync.replicate (Lync.struct ({ [FIELD] = Lync.int (0, 100) })) } :: any
    )
    return held.byName[SET]
end

-- One partition's columns and baselines, which is what a store hands a section.
local function partition (of: any): (any, any)
    local columns, prev = {}, {}
    for index = 1, of.fieldCount do
        columns[index] = {}
        prev[index] = {}
    end
    return columns, prev
end

-- Public --------------------------------------------------------------

return {
    --[[
        A keyframe written and read back, which says the layout below is the layout this file is
        about. Every id and every slot comes back as itself, so the refusal that follows is about
        the bytes a forgery changed rather than about the section being read wrong to begin with.
    ]]
    Harness.case ("sections.keyframe-round-trip", function ()
        local def = compiled ()
        local of = Sections.of (def)
        local columns, prev = partition (def)

        local frame = of.frame
        frame.count = #SLOTS
        for index, slot in SLOTS do
            frame.slots[index] = slot
            frame.ids[index] = IDS[index]
            columns[1][slot] = index
        end

        local b = buffer.create (ROOM)
        Sections.keyframe (of, b, AT, columns)

        local kind = Sections.taken (of, b, AT, prev, CTX)
        Expect.equal (kind, Protocol.SECTION_KEYFRAME)
        Expect.equal (of.frame.count, #SLOTS)

        for index = 1, #SLOTS do
            Expect.equal (of.frame.slots[index], SLOTS[index])
            Expect.equal (of.frame.ids[index], IDS[index])
        end
    end),

    --[[
        The ids' steps padded with something other than zero. A keyframe spells its ids as the
        steps between them and packs them at the width the widest needs, so the bits over the last
        step are nothing, and a frame carrying anything else there spells one list of ids two ways.
    ]]
    Harness.case ("sections.keyframe-ids-refuse-a-pad", function ()
        local def = compiled ()
        local of = Sections.of (def)
        local columns, prev = partition (def)

        local frame = of.frame
        frame.count = #SLOTS
        for index, slot in SLOTS do
            frame.slots[index] = slot
            frame.ids[index] = IDS[index]
            columns[1][slot] = index
        end

        local b = buffer.create (ROOM)
        Sections.keyframe (of, b, AT, columns)
        buffer.writeu8 (b, AT + STEPS, bit32.bor (buffer.readu8 (b, AT + STEPS), 0x80))

        local ok, caught = pcall (Sections.taken, of, b, AT, prev, CTX)
        Expect.holds (not ok, "a keyframe padding its ids with ones was taken rather than refused")
        Expect.equal ((caught :: any).code, Catalog.SECTION)
        Expect.holds (
            string.find (tostring ((caught :: any).facts.said), "padding", 1, true) ~= nil,
            `it said {tostring ((caught :: any).facts.said)}`
        )
    end),
}
