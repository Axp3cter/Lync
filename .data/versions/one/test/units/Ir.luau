--!strict
--!optimize 2
-- What a shape hands back once it is built: every node shut, and what each says about its width.

local Grid = require("@src/shape/Grid")
local Ir = require("@src/shape/Ir")
local Protocol = require("@src/wire/Protocol")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")

local TAG: Ir.Tag = table.freeze({ pathId = 1, expectId = 1 })
local SPAN: Ir.Span = table.freeze({ min = 0, max = 2 })

local function held(): Ir.Shape
    return Ir.varint(TAG, false)
end

local function landing(): Grid.Grid
    return Grid.of(0, 3, 1)
end

-- One region of one leaf, the smallest word there is.
local function worded(): Ir.Word
    local plan = { { bytes = 1, at = 0, parts = {} } }
    local joins = { { at = 1, count = 1, key = nil, nest = nil, tag = TAG } }
    return Ir.word(TAG, plan :: any, { landing() }, joins :: any)
end

local function nothing(): any
    return nil
end

return {
    Harness.case("ir.map-bounds-are-shut", function()
        local of = Ir.pairs(TAG, { min = SPAN.min, max = SPAN.max }, held(), held())
        Expect.equal(table.isfrozen(of.count :: any), true)
    end),

    Harness.case("ir.the-parts-of-a-value-are-shut", function()
        local of = Ir.apart(TAG, "vector", { "x" }, { held() }, nothing)
        Expect.equal(table.isfrozen(of.keys :: any), true)
        Expect.equal(table.isfrozen(of.parts :: any), true)

        local grouped = Ir.group(TAG, nil, { { key = "a", nest = nil, of = held() } })
        Expect.equal(table.isfrozen(grouped.parts :: any), true)
    end),

    Harness.case("ir.the-nests-of-a-group-are-shut", function()
        local nest: Ir.Nest = { key = "inner", under = nil, allow = {}, tag = TAG }
        local of = Ir.group(TAG, nil, {}, { nest })
        Expect.equal(table.isfrozen(of.nests :: any), true)
        Expect.equal(table.isfrozen(Ir.group(TAG, nil, {}).nests :: any), true)
    end),

    Harness.case("ir.a-region-is-shut", function()
        local of = worded()
        Expect.equal(table.isfrozen(of :: any), true)
        Expect.equal(table.isfrozen(of.plan :: any), true)
        Expect.equal(table.isfrozen(of.leaves :: any), true)
        Expect.equal(table.isfrozen(of.joins :: any), true)
        Expect.equal(of.bits, 2)
        Expect.equal(of.maxBytes, 1)
    end),

    Harness.case("ir.a-text-count-is-shut", function()
        local of = Ir.bytes(TAG, { min = SPAN.min, max = SPAN.max }, "string")
        Expect.equal(table.isfrozen(of.count :: any), true)
    end),

    -- A node saying it is fixed when it is not is a column stepping over values that moved.
    Harness.case("ir.says-what-is-fixed", function()
        Expect.equal(Ir.wide(TAG, landing()).fixed, true)
        Expect.equal(Ir.varint(TAG, false).fixed, false)
        Expect.equal(Ir.slot(TAG, nil).fixed, false)
        Expect.equal(Ir.none(TAG).fixed, true)
        Expect.equal(Ir.float(TAG, false).fixed, true)
        Expect.equal(Ir.bytes(TAG, { min = 2, max = 2 }, "string").fixed, true)
        Expect.equal(Ir.bytes(TAG, { min = 1, max = 2 }, "string").fixed, false)
        Expect.equal(Ir.run(TAG, { min = 2, max = 2 }, landing()).fixed, true)
        Expect.equal(Ir.run(TAG, { min = 1, max = 2 }, landing()).fixed, false)
    end),

    -- The worst case each node states, which is what a scratch buffer is sized from.
    Harness.case("ir.worst-cases", function()
        Expect.equal(Ir.slot(TAG, nil).maxBytes, Protocol.VARINT_GROUPS)
        Expect.equal(Ir.varint(TAG, true).maxBytes, Protocol.VARINT_GROUPS)
        Expect.equal(Ir.float(TAG, false).maxBytes, 4)
        Expect.equal(Ir.float(TAG, true).maxBytes, 8)
        Expect.equal(Ir.none(TAG).maxBytes, 0)
        Expect.equal(Ir.wide(TAG, Grid.of(0, 2 ^ 20, 1)).maxBytes, 3)

        -- A count of no bits where the bounds meet, one byte of count otherwise.
        Expect.equal(Ir.bytes(TAG, { min = 4, max = 4 }, "buffer").maxBytes, 4)
        Expect.equal(Ir.bytes(TAG, { min = 0, max = 4 }, "buffer").maxBytes, 5)
        Expect.equal(Ir.bytes(TAG, { min = 0, max = 4 }, "string", "abcd").maxBytes, 2)
        Expect.equal(Ir.run(TAG, { min = 0, max = 4 }, landing()).maxBytes, 2)
        Expect.equal(Ir.list(TAG, { min = 0, max = 4 }, Ir.varint(TAG, false)).maxBytes, 33)
    end),

    -- A list is fixed only when both its count and its element are.
    Harness.case("ir.a-list-reads-both-halves", function()
        local one = Ir.varint(TAG, false)
        local same = Ir.wide(TAG, landing())
        Expect.equal(Ir.list(TAG, { min = 2, max = 2 }, same).fixed, true)
        Expect.equal(Ir.list(TAG, { min = 2, max = 2 }, one).fixed, false)
        Expect.equal(Ir.list(TAG, { min = 1, max = 2 }, same).fixed, false)
    end),

    -- A group is as fixed as every part, an optional and a branch never are.
    Harness.case("ir.what-holding-something-loose-costs", function()
        local one = Ir.varint(TAG, false)
        local same = Ir.wide(TAG, landing())
        Expect.equal(Ir.group(TAG, nil, { { key = "a", nest = nil, of = same } }).fixed, true)
        Expect.equal(Ir.group(TAG, nil, { { key = "a", nest = nil, of = one } }).fixed, false)
        Expect.equal(Ir.opt(TAG, 1, same).fixed, false)
        Expect.equal(Ir.branch(TAG, "kind", { "a", "b" }, { same, same }).fixed, false)
        Expect.equal(Ir.apart(TAG, "vector", { "x" }, { same }, nothing).fixed, true)
        Expect.equal(Ir.apart(TAG, "vector", { "x" }, { one }, nothing).fixed, false)
        Expect.equal(Ir.xform(TAG, same, nothing, nothing).fixed, true)
        Expect.equal(Ir.xform(TAG, one, nothing, nothing).fixed, false)
    end),

    -- Two arms is one bit, since the tag is an index over the arms rather than a count of them.
    Harness.case("ir.a-branch-names-its-arm", function()
        local same = Ir.wide(TAG, landing())
        local of = Ir.branch(TAG, "kind", { "a", "b" }, { same, same })
        Expect.equal(of.tagWidth, 1)
        Expect.equal(of.maxBytes, 1 + same.maxBytes)
        Expect.equal(table.isfrozen(of.names :: any), true)
        Expect.equal(Ir.branch(TAG, "kind", { "a" }, { same }).tagWidth, 0)
    end),

    -- A map is fixed only with its count and both halves of every pair fixed, and a half that is
    -- one grid reading packs as a run.
    Harness.case("ir.a-map-reads-every-half", function()
        local one = Ir.varint(TAG, false)
        local same = Ir.wide(TAG, landing())
        Expect.equal(Ir.pairs(TAG, { min = 2, max = 2 }, same, same).fixed, true)
        Expect.equal(Ir.pairs(TAG, { min = 2, max = 2 }, one, same).fixed, false)
        Expect.equal(Ir.pairs(TAG, { min = 2, max = 2 }, same, one).fixed, false)
        Expect.equal(Ir.pairs(TAG, { min = 1, max = 2 }, same, same).fixed, false)

        local packed = Ir.pairs(TAG, { min = 0, max = 8 }, worded(), same)
        Expect.holds(packed.keyed ~= nil, "a one-leaf word key did not pack as a run")
        Expect.equal(packed.runs, nil)
        Expect.equal(packed.maxBytes, 1 + 2 + 8 * same.maxBytes)
    end),

    Harness.case("ir.groups-with-no-nests-share-one", function()
        local one = Ir.group(TAG, nil, {})
        local two = Ir.group(TAG, nil, {})
        Expect.holds(one.nests == two.nests, "two groups with no nests held two tables")
    end),
}
