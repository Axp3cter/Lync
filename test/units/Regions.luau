--!strict
--!optimize 2
-- Which of the four regions a record's fields land in, and what dissolves on the way.

local Base = require("@src/codec/Base")
local Codecs = require("@src/codec")
local Protocol = require("@src/wire/Protocol")
local Regions = require("@src/shape/Regions")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")

local CEILING = Protocol.BIT_CEILING

-- An integer that packs at four bits, and one past the ceiling that takes whole bytes.
local NARROW = 15
local WIDE = 2 ^ (CEILING + 6)

-- A precision far past anything a person would ask for, where a fold's leaves straddle.
local ABSURD = 1e-5
local COARSE = 5

local NAMES = table.freeze({ "one", "two" })

type Split = Regions.Split

local function record(of: { [string]: any }): Split
    local cells: { [string]: Base.Cell } = {}
    for name, codec in of do
        cells[name] = Base.cell(codec)
    end
    return Regions.of(cells)
end

-- One region as the paths in it, joined.
local function paths(held: { Regions.Entry }): string
    local out = {}
    for _, entry in held do
        table.insert(out, table.concat(entry.at, "."))
    end
    return table.concat(out, " ")
end

return {
    -- Every leaf narrow enough to flow rather than align.
    Harness.case("regions.packs-narrow", function()
        for _, of in
            {
                Codecs.bool(),
                Codecs.int(0, NARROW),
                Codecs.enum(NAMES),
                Codecs.bitfield(NAMES),
                Codecs.quant(0, 1, 0.25),
                Codecs.angle(COARSE),
            }
        do
            Expect.equal(Regions.packs(Base.cell(of)), true)
        end
    end),

    -- A leaf past the ceiling has nothing to share, so the bit arithmetic would buy nothing.
    Harness.case("regions.packs-wide", function()
        Expect.equal(Regions.packs(Base.cell(Codecs.int(0, WIDE))), false)
        Expect.equal(Regions.packs(Base.cell(Codecs.int(0, 2 ^ CEILING - 1))), true)
        Expect.equal(Regions.packs(Base.cell(Codecs.int(0, 2 ^ CEILING))), false)
    end),

    -- A datatype that comes apart is asked about its leaves rather than itself.
    Harness.case("regions.packs-folds", function()
        Expect.equal(Regions.packs(Base.cell(Codecs.vec3(Codecs.int(0, NARROW)))), true)
        Expect.equal(Regions.packs(Base.cell(Codecs.color3.rgb565())), true)
        Expect.equal(Regions.packs(Base.cell(Codecs.rotation.quat(COARSE))), true)
        Expect.equal(Regions.packs(Base.cell(Codecs.vec3())), false)
        Expect.equal(Regions.packs(Base.cell(Codecs.vec3(Codecs.int(0, WIDE)))), false)
    end),

    -- Leaves either side of the ceiling go whole with the widest: the tag is two bits and the
    -- components are past the ceiling at this precision.
    Harness.case("regions.packs-straddles", function()
        Expect.equal(Regions.packs(Base.cell(Codecs.rotation.quat(ABSURD))), false)
    end),

    Harness.case("regions.packs-nothing", function()
        for _, of in
            {
                Codecs.struct({ a = Codecs.bool() }),
                Codecs.array(Codecs.bool(), 2, 2),
                Codecs.map(Codecs.enum(NAMES), Codecs.bool(), 1, 1),
                Codecs.str(0, NARROW),
                Codecs.f32(),
            }
        do
            Expect.equal(Regions.packs(Base.cell(of)), false)
        end
    end),

    -- One field of each region in one record: the partition is a sort rather than a filter.
    Harness.case("regions.four-regions", function()
        local held = record({
            flag = Codecs.bool(),
            wide = Codecs.int(0, WIDE),
            text = Codecs.str(0, NARROW),
            maybe = Codecs.optional(Codecs.bool()),
        })
        Expect.equal(paths(held.bits), "flag")
        Expect.equal(paths(held.bytes), "wide")
        Expect.equal(paths(held.presence), "maybe")
        Expect.equal(paths(held.vars), "maybe text")
        Expect.equal(paths(held.nests), "")
    end),

    -- Name sorted inside every region, since a table of fields has no order of its own.
    Harness.case("regions.name-sorted", function()
        local held = record({
            zulu = Codecs.bool(),
            alpha = Codecs.bool(),
            mike = Codecs.bool(),
            zebra = Codecs.str(0, NARROW),
            able = Codecs.str(0, NARROW),
        })
        Expect.equal(paths(held.bits), "alpha mike zulu")
        Expect.equal(paths(held.vars), "able zebra")
    end),

    -- A fixed record dissolves into the one holding it, so nesting introduces no padding.
    Harness.case("regions.dissolves", function()
        local held = record({
            after = Codecs.bool(),
            inner = Codecs.struct({ two = Codecs.bool(), one = Codecs.bool() }),
            before = Codecs.bool(),
        })
        Expect.equal(paths(held.bits), "after before inner.one inner.two")
        Expect.equal(paths(held.nests), "inner")
        Expect.equal(paths(held.bytes), "")
    end),

    -- Depth first, so a reader making the records back never reaches one whose parent is unmade.
    Harness.case("regions.dissolves-depth-first", function()
        local held = record({
            outer = Codecs.struct({
                deep = Codecs.struct({ leaf = Codecs.bool() }),
                near = Codecs.bool(),
            }),
            other = Codecs.struct({ far = Codecs.bool() }),
        })
        Expect.equal(paths(held.nests), "other outer outer.deep")
        Expect.equal(paths(held.bits), "other.far outer.deep.leaf outer.near")

        local made: { [string]: boolean } = {}
        for _, entry in held.nests do
            local at = entry.at
            if #at > 1 then
                local parent = table.concat(at, ".", 1, #at - 1)
                Expect.holds(made[parent] == true, `{parent} was not made before its own child`)
            end
            made[table.concat(at, ".")] = true
        end
    end),

    -- A record carrying a length or an absence has bytes of its own, so it stays whole.
    Harness.case("regions.varying-stays-whole", function()
        local held = record({
            loose = Codecs.struct({ text = Codecs.str(0, NARROW), flag = Codecs.bool() }),
            firm = Codecs.struct({ flag = Codecs.bool() }),
        })
        Expect.equal(paths(held.vars), "loose")
        Expect.equal(paths(held.nests), "firm")
        Expect.equal(paths(held.bits), "firm.flag")
    end),

    -- An optional is the one field written in two regions, and nothing else appears twice.
    Harness.case("regions.optional-twice", function()
        local held = record({
            maybe = Codecs.optional(Codecs.bool()),
            flag = Codecs.bool(),
            text = Codecs.str(0, NARROW),
        })
        Expect.equal(paths(held.presence), "maybe")
        Expect.equal(paths(held.vars), "maybe text")

        local seen: { [string]: number } = {}
        for _, region in { held.presence, held.bits, held.bytes, held.vars } do
            for _, entry in region do
                local at = table.concat(entry.at, ".")
                seen[at] = (seen[at] or 0) + 1
            end
        end
        Expect.equal(seen.maybe, 2)
        Expect.equal(seen.flag, 1)
        Expect.equal(seen.text, 1)
    end),

    -- A frame is a value the engine carries with no table, so it never dissolves.
    Harness.case("regions.frame-whole", function()
        local held = record({
            at = Codecs.cframe(Codecs.vec3(Codecs.int(0, NARROW)), Codecs.rotation.quat(COARSE)),
            flag = Codecs.bool(),
        })
        Expect.equal(paths(held.bytes), "at")
        Expect.equal(paths(held.bits), "flag")
        Expect.equal(paths(held.nests), "")
    end),

    Harness.case("regions.empty", function()
        local held = Regions.of({})
        Expect.equal(#held.presence, 0)
        Expect.equal(#held.bits, 0)
        Expect.equal(#held.bytes, 0)
        Expect.equal(#held.vars, 0)
        Expect.equal(#held.nests, 0)
    end),

    -- A layout is settled once at compile and read on every frame after.
    Harness.case("regions.frozen", function()
        local held = record({ flag = Codecs.bool(), text = Codecs.str(0, NARROW) })
        Expect.equal(table.isfrozen(held :: any), true)
        for _, region in { held.presence, held.bits, held.bytes, held.vars, held.nests } do
            Expect.equal(table.isfrozen(region :: any), true)
        end
        Expect.equal(table.isfrozen(held.bits[1] :: any), true)
        Expect.equal(table.isfrozen(held.bits[1].at :: any), true)
    end),
}
