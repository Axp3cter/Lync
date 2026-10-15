--!strict
--!optimize 2
-- What a built codec carries besides the pair that lays it down, which every layer above reads
-- rather than the declaration.

local Codecs = require("@src/codec")
local Shape = require("@src/shape")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")

local AT = "Origin"

-- A span too wide to flow into a word, which is the one that surfaces its grid as whole bytes.
local WIDE = 2 ^ 40

return {
    Harness.case("built.is-frozen", function()
        local of: any = Shape.build(Codecs.int(0, 5), AT)
        Expect.equal(table.isfrozen(of), true)
    end),

    -- One width or many: a string of many lengths is the plainest thing that is not fixed.
    Harness.case("built.says-what-is-fixed", function()
        Expect.equal(Shape.build(Codecs.int(0, 5), AT).fixed, true)
        Expect.equal(Shape.build(Codecs.str(1, 4), AT).fixed, false)
        Expect.equal(Shape.build(Codecs.struct({ a = Codecs.str(1, 4) }), AT).fixed, false)
    end),

    -- The mark a declaration carried, which is what puts a field on the lane that reorders.
    Harness.case("built.carries-the-mark", function()
        Expect.equal(Shape.build(Codecs.int(0, 5), AT).marker, "none")
        Expect.equal(Shape.build(Codecs.int(0, 5):newest(), AT).marker, "newest")
    end),

    -- The grid a build surfaces is what a delta takes its difference against. A field too wide to
    -- flow into a word is still one grid, a spread value is none, and a transform looks through.
    Harness.case("built.surfaces-a-grid", function()
        Expect.holds(Shape.build(Codecs.int(0, 5), AT).grid ~= nil, "a narrow int surfaced no grid")
        Expect.holds(
            Shape.build(Codecs.int(0, WIDE), AT).grid ~= nil,
            "a wide int surfaced no grid"
        )
        Expect.equal(Shape.build(Codecs.bitfield({ "a", "b" }), AT).grid, nil)
        Expect.equal(Shape.build(Codecs.str(0, 4), AT).grid, nil)
        local seen = Shape.build(
            Codecs.int(0, 5):as(function(wire: number)
                return wire
            end, function(domain: number)
                return domain
            end),
            AT
        )
        Expect.holds(seen.grid ~= nil, "a transform hid its grid")
    end),

    -- What a place wanted, kept where a refusal can read it back.
    Harness.case("built.carries-what-was-wanted", function()
        local of = Shape.build(Codecs.int(0, 5), AT)
        Expect.equal(of.expected.texts[of.tag.expectId], "int(0,5)")
        Expect.equal(of.paths.texts[of.tag.pathId], AT)
        Expect.equal(of.maxBytes, 1)
    end),

    -- Two builds get two sites unless handed one, since a site numbers paths and references.
    Harness.case("built.holds-its-own-site", function()
        local one = Shape.build(Codecs.int(0, 5), AT)
        local two = Shape.build(Codecs.int(0, 5), AT)
        Expect.holds(one.paths ~= two.paths, "two builds were written against one site")

        local site = Shape.site()
        local held = Shape.build(Codecs.int(0, 5), AT, site)
        Expect.holds(held.paths == site.paths, "a build handed a site wrote against another")
        Expect.holds(held.sidecar == site.sidecar, "a build handed a site took another sidecar")
    end),
}
