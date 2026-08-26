--!strict
--!optimize 2
--[[
    What a shape hands back once it is built. Every node is read from the emit layer and written by
    nobody, so what a node carries has to be shut: a table left open is one anything downstream can
    answer differently later, and the node it belongs to would go on describing the old shape.
]]

local Grid = require ("@src/shape/Grid")
local Ir = require ("@src/shape/Ir")
local Protocol = require ("@src/wire/Protocol")

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

-- One grid, which is what a field lands on when it is a single leaf.
local function landing (): Grid.Grid return Grid.of (0, 3, 1) end

-- One region of one leaf, which is the smallest word there is.
local function worded (): Ir.Word
    local plan = { { bytes = 1, at = 0, parts = {} } }
    local joins = { { at = 1, count = 1, key = nil, nest = nil, tag = TAG } }

    return Ir.word (TAG, plan :: any, { landing () }, joins :: any)
end

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

        -- A group carries its parts the same way, and is walked the same way to reach them.
        local grouped = Ir.group (TAG, nil, { { key = "a", nest = nil, of = held () } })
        Expect.equal (table.isfrozen (grouped.parts :: any), true)
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

    --[[
        A region and the two arrays it is laid out by. The plan says which bits each window holds
        and the leaves say what each lands on, so the pair is what every read and write of the
        region walks, and either moving underneath is a field read off the wrong bits.
    ]]
    Harness.case ("ir.a-region-is-shut", function ()
        local of = worded ()

        Expect.equal (table.isfrozen (of :: any), true)
        Expect.equal (table.isfrozen (of.plan :: any), true)
        Expect.equal (table.isfrozen (of.leaves :: any), true)
    end),

    -- The count text is bounded by, which is what a reader holds an arriving one against.
    Harness.case ("ir.a-text-count-is-shut", function ()
        local of = Ir.bytes (TAG, { min = SPAN.min, max = SPAN.max }, "string")
        Expect.equal (table.isfrozen (of.count :: any), true)
    end),

    --[[
        Which nodes are one width and which are not, which decides whether a column of them may be
        a packed run. A node saying it is fixed when it is not is a column stepping over values
        that are not where it left them, and saying it is not when it is costs the packing.
    ]]
    Harness.case ("ir.says-what-is-fixed", function ()
        Expect.equal (Ir.wide (TAG, landing ()).fixed, true)
        Expect.equal (Ir.varint (TAG, false).fixed, false)
        Expect.equal (Ir.slot (TAG, nil).fixed, false)

        Expect.equal (Ir.bytes (TAG, { min = 2, max = 2 }, "string").fixed, true)
        Expect.equal (Ir.bytes (TAG, { min = 1, max = 2 }, "string").fixed, false)

        Expect.equal (Ir.run (TAG, { min = 2, max = 2 }, landing ()).fixed, true)
        Expect.equal (Ir.run (TAG, { min = 1, max = 2 }, landing ()).fixed, false)
    end),

    --[[
        What a reference costs, which is the widest a varint runs to. A slot is an index into what
        rides beside the frame and nothing bounds it below the cap, so a node claiming less is one
        a frame could outgrow with references its own schema allows.
    ]]
    Harness.case (
        "ir.a-slot-costs-the-cap",
        function () Expect.equal (Ir.slot (TAG, nil).maxBytes, Protocol.VARINT_GROUPS) end
    ),

    --[[
        Whether a collection is one width, which is both its count and what it holds. A list of one
        length over an element that varies is not fixed and neither is a list of many lengths over
        one that does not, so a node reading only half the question answers fixed for both.
    ]]
    Harness.case ("ir.a-list-reads-both-halves", function ()
        local one = Ir.varint (TAG, false)
        local same = Ir.wide (TAG, landing ())

        Expect.equal (Ir.list (TAG, { min = 2, max = 2 }, same).fixed, true)
        Expect.equal (Ir.list (TAG, { min = 2, max = 2 }, one).fixed, false)
        Expect.equal (Ir.list (TAG, { min = 1, max = 2 }, same).fixed, false)
    end),

    --[[
        The nodes that hold something else, and whether holding a loose one makes them loose. A
        group is as fixed as every part it carries, and an optional and a branch never are: one
        may not be there at all and the other is whichever arm arrived.
    ]]
    Harness.case ("ir.what-holding-something-loose-costs", function ()
        local one = Ir.varint (TAG, false)
        local same = Ir.wide (TAG, landing ())

        local tight = Ir.group (TAG, nil, { { key = "a", nest = nil, of = same } })
        local loose = Ir.group (TAG, nil, { { key = "a", nest = nil, of = one } })

        Expect.equal (tight.fixed, true)
        Expect.equal (loose.fixed, false)

        Expect.equal (Ir.opt (TAG, 1, same).fixed, false)
        Expect.equal (Ir.branch (TAG, "kind", { "a", "b" }, { same, same }).fixed, false)

        -- A value that comes apart is as fixed as the parts it comes apart into, the same way.
        local function apart (of: Ir.Shape): boolean
            return Ir.apart (TAG, "vector", { "x" }, { of }, function (): any return nil end).fixed
        end

        Expect.equal (apart (same), true)
        Expect.equal (apart (one), false)
    end),

    --[[
        What a branch spends naming its arm, and the names it keeps. Two arms is one bit, since the
        tag is an index over the arms rather than a count of them, and a bit too many is a frame
        every reader of the same schema walks off by one.
    ]]
    Harness.case ("ir.a-branch-names-its-arm", function ()
        local same = Ir.wide (TAG, landing ())
        local of = Ir.branch (TAG, "kind", { "a", "b" }, { same, same })

        Expect.equal (of.tagWidth, 1)
        Expect.equal (table.isfrozen (of.names :: any), true)
    end),

    -- The joins a region is read through, which say which leaves each field of it reaches.
    Harness.case (
        "ir.the-joins-of-a-region-are-shut",
        function () Expect.equal (table.isfrozen (worded ().joins :: any), true) end
    ),

    --[[
        Whether a map is one width, which is its count and both halves of every pair. A map reading
        only its keys answers fixed for one whose values vary, and one reading only its count
        answers fixed for a map of one length holding something that does not.
    ]]
    Harness.case ("ir.a-map-reads-every-half", function ()
        local one = Ir.varint (TAG, false)
        local same = Ir.wide (TAG, landing ())

        Expect.equal (Ir.pairs (TAG, { min = 2, max = 2 }, same, same).fixed, true)
        Expect.equal (Ir.pairs (TAG, { min = 2, max = 2 }, one, same).fixed, false)
        Expect.equal (Ir.pairs (TAG, { min = 2, max = 2 }, same, one).fixed, false)
        Expect.equal (Ir.pairs (TAG, { min = 1, max = 2 }, same, same).fixed, false)
    end),

    --[[
        The nests every group with none of its own carries, which is one table rather than one
        each. There is nothing to say in any of them that is not said in every other, so a table
        apiece is a table apiece to keep for no reading anybody makes.
    ]]
    Harness.case ("ir.groups-with-no-nests-share-one", function ()
        local one = Ir.group (TAG, nil, {})
        local two = Ir.group (TAG, nil, {})

        Expect.holds (one.nests == two.nests, "two groups with no nests held two tables")
    end),
}
