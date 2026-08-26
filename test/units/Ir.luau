--!strict
--!optimize 2
--[[
    What a shape hands back once it is built. Every node is read from the emit layer and written by
    nobody, so what a node carries has to be shut: a table left open is one anything downstream can
    answer differently later, and the node it belongs to would go on describing the old shape.
]]

local Ir = require ("@src/shape/Ir")

local Expect = require ("@test/harness/Expect")
local Harness = require ("@test/harness")

-- Constants -----------------------------------------------------------

-- Where a node says it is, which its refusals read back.
const TAG: Ir.Tag = table.freeze ({ pathId = 1, expectId = 1 })

-- A count a collection is bounded by, and one shape simple enough to stand in for any other.
const SPAN: Ir.Span = table.freeze ({ min = 0, max = 2 })

-- Private -------------------------------------------------------------

-- One shape, which every node below holds rather than looks into.
local function held (): Ir.Shape return Ir.varint (TAG, false) end

-- Public --------------------------------------------------------------

return {
    --[[
        A map's bounds, which is what a reader holds a count it was handed against. A caller who
        reached in and moved one would move what every frame after it is measured by.
    ]]
    Harness.case ("ir.map-bounds-are-shut", function ()
        local of = Ir.pairs (TAG, { min = SPAN.min, max = SPAN.max }, held (), held ())
        Expect.equal (table.isfrozen (of.count :: any), true)
    end),

    --[[
        The names a value in parts is read off, and the parts themselves. The two are walked side
        by side, so one of them moving is a value read off the name of another.
    ]]
    Harness.case ("ir.the-parts-of-a-value-are-shut", function ()
        local of = Ir.apart (TAG, "vector", { "x" }, { held () }, function (): any return nil end)

        Expect.equal (table.isfrozen (of.keys :: any), true)
        Expect.equal (table.isfrozen (of.parts :: any), true)
    end),

    --[[
        A group's nests, and the one every group with none of its own shares. A shared table left
        open is the worse of the two: anything moving it moves it for every group there is.
    ]]
    Harness.case ("ir.the-nests-of-a-group-are-shut", function ()
        local nest: Ir.Nest = { key = "inner", under = nil, allow = {}, tag = TAG }
        local of = Ir.group (TAG, nil, {}, { nest })
        Expect.equal (table.isfrozen (of.nests :: any), true)

        local bare = Ir.group (TAG, nil, {})
        Expect.equal (table.isfrozen (bare.nests :: any), true)
    end),
}
