--!strict
--!optimize 2
--[[
    What a built codec carries besides the pair that lays it down. Everything above the shape layer
    reads these rather than the declaration, so a build answering the wrong one of them is a set or
    a section deciding what to do off a fact about some other codec.
]]

local Lync = require ("@src")
local Serial = require ("@src/shape/Serial")
local Shape = require ("@src/shape")

local Expect = require ("@test/harness/Expect")
local Harness = require ("@test/harness")

-- Constants -----------------------------------------------------------

-- Where a build says it is, which is what its refusals read back.
const AT = "Origin"

-- A span too wide to flow into a word, which is the one that surfaces its grid as whole bytes.
const WIDE = 2 ^ 40

-- Public --------------------------------------------------------------

return {
    --[[
        A build handed back frozen. What it carries is read from every layer above it and written
        by none of them, so a build left open is one anybody could quietly answer differently.
    ]]
    Harness.case ("built.is-frozen", function ()
        local of: any = Shape.build (Lync.int (0, 5), AT)
        Expect.equal (table.isfrozen (of), true)
    end),

    --[[
        Whether a build is one width or many, which is what decides if a column of them may be a
        run. A string of many lengths is the plainest thing that is not, and answering fixed for
        one is a column stepping over values that are not where it expected them.
    ]]
    Harness.case ("built.says-what-is-fixed", function ()
        Expect.equal (Shape.build (Lync.int (0, 5), AT).fixed, true)
        Expect.equal (Shape.build (Lync.str (1, 4), AT).fixed, false)
    end),

    --[[
        The mark a declaration carried, which is what puts a field on the lane that reorders. A
        build losing it is a field a set would send reliably no matter what the caller asked for.
    ]]
    Harness.case ("built.carries-the-mark", function ()
        Expect.equal (Shape.build (Lync.int (0, 5), AT).marker, "none")
        Expect.equal (Shape.build (Lync.int (0, 5):newest (), AT).marker, "newest")
    end),

    --[[
        The grid a build surfaces, which is what a delta takes its difference against. A field too
        wide to flow into a word is still one grid, so a build answering nothing for it is a set
        that would send the whole value where it could have sent the step.
    ]]
    Harness.case ("built.surfaces-a-wide-grid", function ()
        local near = Shape.build (Lync.int (0, 5), AT)
        Expect.holds (near.grid ~= nil, "a narrow int surfaced no grid")
        Expect.holds (
            Shape.build (Lync.int (0, WIDE), AT).grid ~= nil,
            "a wide int surfaced no grid"
        )
    end),

    --[[
        What a place wanted, kept where a refusal can read it back. A build carrying an interner
        nobody wrote to answers a refusal that names the value it got and nothing it expected.
    ]]
    Harness.case ("built.carries-what-was-wanted", function ()
        local of = Shape.build (Lync.int (0, 5), AT)

        Expect.holds (of.expected.texts[of.tag.expectId] ~= nil, "a build wanted nothing")
        Expect.holds (of.paths.texts[of.tag.pathId] ~= nil, "a build was nowhere")
    end),

    --[[
        Two builds and the site each is written against. A site is where the paths, the wanted
        text and the references a frame carries are interned, so two codecs sharing one would
        answer each other's paths, and one handed a site of its own would not.
    ]]
    Harness.case ("built.holds-its-own-site", function ()
        local one = Shape.build (Lync.int (0, 5), AT)
        local two = Shape.build (Lync.int (0, 5), AT)

        Expect.holds (one.paths ~= two.paths, "two builds were written against one site")

        local site = {
            paths = Serial.interner (),
            expected = Serial.interner (),
            sidecar = { refs = {}, slotOf = {}, bears = false },
        }
        local held = Shape.build (Lync.int (0, 5), AT, site)

        Expect.holds (held.paths == site.paths, "a build handed a site wrote against another")
    end),
}
