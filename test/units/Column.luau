--!strict
--!optimize 2
--[[
    One field of a set across many records, as the bytes a column becomes and what a reader of one
    turns away. A column is what every section carries its values in, so a frame naming a value the
    grid has no point for reaches a caller through here or through nothing.
]]

local Catalog = require ("@src/kernel/Catalog")
local Column = require ("@src/shape/emit/Column")
local Grid = require ("@src/shape/Grid")
local Ir = require ("@src/shape/Ir")
local Serial = require ("@src/shape/Serial")
local Types = require ("@src/Types")

local Expect = require ("@test/harness/Expect")
local Harness = require ("@test/harness")

-- Constants -----------------------------------------------------------

const ROOM = 256
const BROKEN = Catalog.SECTION

-- The path a column names its refusals at, and what a run of bare bits says it was.
const WHERE = "Origin.field"
const SAID = "a run of bits"

-- A grid narrower than the bits carrying it, so two of its patterns are ones it has no point for.
const REACH = 5

-- A step that is not one, which is what makes a grid's points other than the numbers handed to it.
const STEPPED = 0.5

--[[
    A pattern the bits of a stepped grid can spell and the grid has no point for. Ten points want
    four bits and four bits spell fifteen, so the five over the top are readings nobody wrote.
]]
const PAST = 0x0F
const HELD = table.freeze ({ 1, 3, 5 })

-- What a reader is handed about the moment, which a column reads nothing of.
const CTX: Types.ValidateContext = table.freeze ({ player = nil, now = 0, last = nil })

-- Private -------------------------------------------------------------

-- The two interners and the tag a column names its refusals through.
local function tagged (): (Ir.Tag, Serial.Interner, Serial.Interner)
    local paths = Serial.interner ()
    local expected = Serial.interner ()

    return {
        pathId = Serial.intern (paths, WHERE),
        expectId = Serial.intern (expected, `int(0,{REACH})`),
    },
        paths,
        expected
end

-- A column of the values held, and the buffer it went down in.
local function laid (): (buffer, Column.Read)
    local tag, paths, expected = tagged ()
    local write, read = Column.grid (tag, paths, expected, Grid.of (0, REACH, 1))

    local b = buffer.create (ROOM)
    write (b, 0, HELD :: any, {}, #HELD)

    return b, read
end

-- What a read of those bytes refused under, or nothing where it took them.
local function refused (read: Column.Read, b: buffer): string?
    local ok, why = pcall (read, b, 0, {}, {}, #HELD, CTX)
    if ok or type (why) ~= "table" then return nil end

    return (why :: { code: string }).code
end

-- Public --------------------------------------------------------------

return {
    -- The values a column was laid from, read back as themselves, which the refusals below are not.
    Harness.case ("column.round-trip", function ()
        local b, read = laid ()

        local into: { any } = {}
        read (b, 0, into, {}, #HELD, CTX)

        for index = 1, #HELD do
            Expect.equal (into[index], HELD[index])
        end
    end),

    --[[
        A column padded with something other than zero. Three values of three bits leave seven bits
        over, and they go down as nothing, so a frame carrying anything else in them spells one
        column two ways.
    ]]
    Harness.case ("column.refuses-a-pad", function ()
        local b, read = laid ()
        buffer.writeu8 (b, 1, bit32.bor (buffer.readu8 (b, 1), 0x80))

        Expect.equal (refused (read, b), Catalog.PAD)
    end),

    --[[
        A column naming a point its grid does not have. Three bits carry eight patterns and the
        grid holds six, so the two above it are ones a frame can spell and a reader cannot answer.
    ]]
    Harness.case ("column.refuses-a-value-off-its-grid", function ()
        local b, read = laid ()
        buffer.writeu8 (b, 0, 0x3F)

        Expect.equal (refused (read, b), Catalog.TAG)
    end),

    --[[
        The same for a grid whose points are other than the numbers it hands back. A reading off a
        grid like that is turned back through it a step at a time, and the walk that does the
        turning is a different one from the walk above, so it has to be held to the grid itself.
    ]]
    Harness.case ("column.refuses-a-reading-off-a-stepped-grid", function ()
        local tag, paths, expected = tagged ()
        local write, read = Column.grid (tag, paths, expected, Grid.of (0, REACH, STEPPED))

        local b = buffer.create (ROOM)
        write (b, 0, { 0, 1, 2 } :: any, {}, #HELD)
        buffer.writeu8 (b, 0, PAST)

        Expect.equal (refused (read, b), Catalog.TAG)
    end),

    --[[
        A value the grid cannot take, refused where it is written. A column asks its grid once an
        element, so a value it cannot answer is one the column has nowhere to put.
    ]]
    Harness.case ("column.refuses-writing-off-its-grid", function ()
        local tag, paths, expected = tagged ()
        local write = Column.grid (tag, paths, expected, Grid.of (0, REACH, 1))

        local ok, why = pcall (write, buffer.create (ROOM), 0, { 1, REACH + 4, 2 } :: any, {}, 3)
        Expect.holds (not ok, "a value off its grid was written rather than refused")

        -- Named, since a column putting a nothing down raises where the nothing is read instead.
        local said = tostring (why)
        Expect.holds (string.find (said, WHERE, 1, true) ~= nil, `it said {said}`)

        --[[
            And the reading itself, which is the half a whole column handed over at once could get
            wrong: the grid answers where the first bad one sat and the column has to look it up
            again rather than say whichever one it happens to be holding.
        ]]
        local named = `got {REACH + 4}`
        Expect.holds (string.find (said, named, 1, true) ~= nil, `it said {said}`)
    end),

    --[[
        The same for a grid with no run form to offer, its points being other than the numbers it is
        handed. What takes a column onto a grid like that is a walk asking one reading at a time,
        and the reading it stopped on has to be named the way a whole run names its own.
    ]]
    Harness.case ("column.refuses-writing-off-a-stepped-grid", function ()
        local tag, paths, expected = tagged ()
        local write = Column.grid (tag, paths, expected, Grid.of (0, REACH, STEPPED))

        local ok, why = pcall (write, buffer.create (ROOM), 0, { 1, REACH + 4, 2 } :: any, {}, 3)
        Expect.holds (not ok, "a value off a stepped grid was written rather than refused")

        local said = tostring (why)
        local named = `got {REACH + 4}`
        Expect.holds (string.find (said, named, 1, true) ~= nil, `it said {said}`)
    end),

    --[[
        A run of bare bits padded with something other than zero. A column of indices nobody has a
        grid for is still a run, and the bits over its last element are still nothing, so what a
        reader holds it to is the same and what it says it was about is the run itself.
    ]]
    Harness.case ("column.bits-refuses-a-pad", function ()
        local write, read = Column.bits (3, SAID)

        local b = buffer.create (ROOM)
        write (b, 0, HELD :: any, {}, #HELD)
        buffer.writeu8 (b, 1, bit32.bor (buffer.readu8 (b, 1), 0x80))

        local ok, why = pcall (read, b, 0, {}, {}, #HELD, CTX)
        Expect.holds (not ok, "a run of bits padded with ones was taken rather than refused")
        Expect.equal ((why :: any).code, BROKEN)
        Expect.equal ((why :: any).facts.said, SAID)
    end),

    --[[
        A difference that lands off the grid it is taken against. A gain carries the step from what
        a record last held rather than the value, so a step no encoder wrote is one that walks the
        field past the end of its own domain.
    ]]
    Harness.case ("column.refuses-a-gain-off-its-grid", function ()
        local tag, paths, expected = tagged ()
        local gain, regain = Column.gain (tag, paths, expected, Grid.of (0, REACH, 1), true)

        local slots = { 1, 2, 3 }
        local was = { [1] = 1, [2] = 1, [3] = 1 }

        local b = buffer.create (ROOM)

        -- The gain has a grid of its own to ask, and a value it cannot answer stops there.
        local put, why = pcall (gain, b, 0, { 1, REACH + 4, 2 } :: any, slots, was, {}, 3)
        Expect.holds (not put, "a gain of a value off its grid was written rather than refused")
        Expect.holds (
            string.find (tostring (why), WHERE, 1, true) ~= nil,
            `it said {tostring (why)}`
        )

        gain (b, 0, { 2, 3, 4 } :: any, slots, was, {}, 3)

        local took, caught = pcall (
            regain,
            b,
            0,
            {},
            slots,
            { [1] = REACH, [2] = REACH, [3] = REACH },
            {},
            3
        )
        Expect.holds (not took, "a gain landing past its grid was taken rather than refused")
        Expect.equal ((caught :: any).code, Catalog.TAG)
    end),

    --[[
        A delta naming a slot this receiver does not hold. There is nothing to step from, so that
        place has no reading and the walk must leave it alone: a step is written for every slot the
        sender named, and only the ones this side has a baseline for come back as values.
    ]]
    Harness.case ("column.gain-leaves-a-slot-it-does-not-hold", function ()
        local tag, paths, expected = tagged ()
        local gain, regain = Column.gain (tag, paths, expected, Grid.of (0, REACH, STEPPED), true)

        local slots = { 1, 2, 3 }
        local b = buffer.create (ROOM)

        -- Written against a baseline holding all three, so every step goes down as the sender's.
        local whole = { [1] = 1, [2] = 1, [3] = 1 }
        gain (b, 0, { 0.5, 1, 1.5 } :: any, slots, whole, {}, #slots)

        --[[
            Read back against one holding only the ends. The middle slot is the sender's and not
            this receiver's, so what stands at that place afterwards is nothing at all.
        ]]
        local part = { [1] = 1, [3] = 1 }
        local into: { any } = {}
        regain (b, 0, into, slots, part, {}, #slots)

        Expect.equal (into[2], nil)
        Expect.equal (into[1], 0.5)
        Expect.equal (into[3], 1.5)
    end),
}
