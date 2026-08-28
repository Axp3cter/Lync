--!strict
--!optimize 2
--[[
    Which of the four regions a record's fields land in, and what dissolves on the way.
]]

local Base = require ("@src/codec/Base")
local Lync = require ("@src")
local Protocol = require ("@src/wire/Protocol")
local Regions = require ("@src/shape/Regions")

local Expect = require ("@test/harness/Expect")
local Harness = require ("@test/harness")

-- Constants -----------------------------------------------------------

-- The widest a leaf may be and still flow with its neighbours, read from the module that owns it.
const CEILING = Protocol.BIT_CEILING

--[[
    Two bounds and what each is for. `NARROW` is an integer that packs into a bit run at four bits,
    and `WIDE` is one that cannot: a leaf past the ceiling takes whole bytes, so a field of one is
    written in the byte region however the rest of the record is laid out.
]]
const NARROW = 15
const WIDE = 2 ^ (CEILING + 6)

-- A precision far past anything a person would ask for, which is where a fold's leaves straddle.
const ABSURD = 1e-5

-- A precision an ordinary schema asks for, in degrees.
const COARSE = 5

const NAMES = table.freeze ({ "one", "two" })

-- Types ---------------------------------------------------------------

type Split = Regions.Split

-- Private -------------------------------------------------------------

-- A record of declarations as the cells the partition reads, which is one call per field.
local function record (of: { [string]: any }): Split
    local cells: { [string]: Base.Cell } = {}
    for name, codec in of do
        cells[name] = Base.cell (codec)
    end
    return Regions.of (cells)
end

-- One region as the paths in it, joined, so a case names the whole of a list rather than counting.
local function paths (held: { Regions.Entry }): string
    local out = {}
    for _, entry in held do
        table.insert (out, table.concat (entry.at, "."))
    end
    return table.concat (out, " ")
end

-- Public --------------------------------------------------------------

return {
    --[[
        The fields a bit run takes, which is every leaf narrow enough to flow rather than align. A
        truth is one bit, a bounded integer is as many as its range needs, a name out of a list is
        as many as the list needs, a record of truths is one leaf a name, and a number or an angle
        on a grid is as many as the grid holds.
    ]]
    Harness.case ("regions.packs-narrow", function ()
        local narrow = {
            Lync.bool (),
            Lync.int (0, NARROW),
            Lync.enum (NAMES),
            Lync.bitfield (NAMES),
            Lync.quant (0, 1, 0.25),
            Lync.angle (COARSE),
        }

        for _, of in narrow do
            Expect.equal (Regions.packs (Base.cell (of)), true)
        end
    end),

    --[[
        A leaf past the ceiling takes whole bytes instead. What the run buys is fields sharing the
        bytes they sit in, and a field wide enough to span several of them on its own has nothing to
        share, so the bit arithmetic would be paid for nothing.
    ]]
    Harness.case ("regions.packs-wide", function ()
        Expect.equal (Regions.packs (Base.cell (Lync.int (0, WIDE))), false)

        -- The two sides of the ceiling itself, which is where the rule is decided rather than near.
        Expect.equal (Regions.packs (Base.cell (Lync.int (0, 2 ^ CEILING - 1))), true)
        Expect.equal (Regions.packs (Base.cell (Lync.int (0, 2 ^ CEILING))), false)
    end),

    --[[
        A datatype that comes apart by a computation is asked about its leaves rather than itself. A
        vector of narrow components is a bit run and one of floats is byte fields, which is the same
        rule reaching a different answer rather than a second rule about vectors.
    ]]
    Harness.case ("regions.packs-folds", function ()
        Expect.equal (Regions.packs (Base.cell (Lync.vec3 (Lync.int (0, NARROW)))), true)
        Expect.equal (Regions.packs (Base.cell (Lync.color3.rgb565 ())), true)
        Expect.equal (Regions.packs (Base.cell (Lync.rotation.quat (COARSE))), true)

        Expect.equal (Regions.packs (Base.cell (Lync.vec3 ())), false)
        Expect.equal (Regions.packs (Base.cell (Lync.vec3 (Lync.int (0, WIDE)))), false)
    end),

    --[[
        A field whose leaves fall either side of the ceiling goes whole, with its widest. They come
        out of one computation and would otherwise sit in two regions nowhere near each other, and
        nothing that spans two regions can run a computation across them.
    ]]
    Harness.case ("regions.packs-straddles", function ()
        local held = Base.cell (Lync.rotation.quat (ABSURD))

        -- The tag is two bits and the three components are far past the ceiling at this precision.
        Expect.equal (Regions.packs (held), false)
    end),

    --[[
        Everything that is no region field at all. A record, a list, a map and a string have no
        leaves of their own to be narrow or wide, so the question is answered before the ceiling is
        reached and the field is written wherever its own kind belongs.
    ]]
    Harness.case ("regions.packs-nothing", function ()
        local held = {
            Lync.struct ({ a = Lync.bool () }),
            Lync.array (Lync.bool (), 2, 2),
            Lync.map (Lync.enum (NAMES), Lync.bool (), 1, 1),
            Lync.str (0, NARROW),
            Lync.f32 (),
        }

        for _, of in held do
            Expect.equal (Regions.packs (Base.cell (of)), false)
        end
    end),

    --[[
        One field of each region in one record, and the four lists it comes out as. A record with
        one of each is what says the partition is a sort rather than a filter, since a field landing
        in the wrong list is a field missing from one place and present in another.
    ]]
    Harness.case ("regions.four-regions", function ()
        local held = record ({
            flag = Lync.bool (),
            wide = Lync.int (0, WIDE),
            text = Lync.str (0, NARROW),
            maybe = Lync.optional (Lync.bool ()),
        })

        Expect.equal (paths (held.bits), "flag")
        Expect.equal (paths (held.bytes), "wide")
        Expect.equal (paths (held.presence), "maybe")
        Expect.equal (paths (held.vars), "maybe text")
        Expect.equal (paths (held.nests), "")
    end),

    --[[
        Name sorted inside every region, which is the canonical ordering doing the same work here
        that it does over a namespace. A partition that walked the table's own order would lay one
        record two ways, since a table of fields has no order of its own to begin with.
    ]]
    Harness.case ("regions.name-sorted", function ()
        local held = record ({
            zulu = Lync.bool (),
            alpha = Lync.bool (),
            mike = Lync.bool (),
            zebra = Lync.str (0, NARROW),
            able = Lync.str (0, NARROW),
        })

        Expect.equal (paths (held.bits), "alpha mike zulu")
        Expect.equal (paths (held.vars), "able zebra")
    end),

    --[[
        A fixed record dissolves into the one holding it. Its fields sit together at the name it was
        declared under inside each region they reach, so the bytes are the ones the fields written
        out flat would have laid down and nesting introduces no padding at any depth.
    ]]
    Harness.case ("regions.dissolves", function ()
        local held = record ({
            after = Lync.bool (),
            inner = Lync.struct ({ two = Lync.bool (), one = Lync.bool () }),
            before = Lync.bool (),
        })

        Expect.equal (paths (held.bits), "after before inner.one inner.two")
        Expect.equal (paths (held.nests), "inner")
        Expect.equal (paths (held.bytes), "")
    end),

    --[[
        Depth first, so a reader making the records back never reaches one whose parent it has not
        made. The nests are what the walk met rather than what a second pass could find, because
        finding them again from the paths would mean walking the declarations twice.
    ]]
    Harness.case ("regions.dissolves-depth-first", function ()
        local held = record ({
            outer = Lync.struct ({
                deep = Lync.struct ({ leaf = Lync.bool () }),
                near = Lync.bool (),
            }),
            other = Lync.struct ({ far = Lync.bool () }),
        })

        -- Name sorted at every level, so `other` leads and a deeper record follows its parent.
        Expect.equal (paths (held.nests), "other outer outer.deep")
        Expect.equal (paths (held.bits), "other.far outer.deep.leaf outer.near")

        -- And the property the order is for, which no single list spells out on its own.
        local made: { [string]: boolean } = {}
        for _, entry in held.nests do
            local at = entry.at
            if #at > 1 then
                local parent = table.concat (at, ".", 1, #at - 1)
                Expect.holds (made[parent] == true, `{parent} was not made before its own child`)
            end
            made[table.concat (at, ".")] = true
        end
    end),

    --[[
        A record that varies does not dissolve. Only a fixed one can, because a dissolved record's
        fields have to sit where the fields around them do, and a record carrying a length or an
        absence has bytes of its own that would land between them.
    ]]
    Harness.case ("regions.varying-stays-whole", function ()
        local held = record ({
            loose = Lync.struct ({ text = Lync.str (0, NARROW), flag = Lync.bool () }),
            firm = Lync.struct ({ flag = Lync.bool () }),
        })

        Expect.equal (paths (held.vars), "loose")
        Expect.equal (paths (held.nests), "firm")
        Expect.equal (paths (held.bits), "firm.flag")
    end),

    --[[
        An optional is the one field written in two regions. The bit saying whether it is there and
        the payload that follows are a region apart, and there is one declaration behind them, so it
        appears twice and nothing else does.
    ]]
    Harness.case ("regions.optional-twice", function ()
        local held = record ({
            maybe = Lync.optional (Lync.bool ()),
            flag = Lync.bool (),
            text = Lync.str (0, NARROW),
        })

        Expect.equal (paths (held.presence), "maybe")
        Expect.equal (paths (held.vars), "maybe text")

        local seen: { [string]: number } = {}
        for _, region in { held.presence, held.bits, held.bytes, held.vars } do
            for _, entry in region do
                local at = table.concat (entry.at, ".")
                seen[at] = (seen[at] or 0) + 1
            end
        end

        Expect.equal (seen.maybe, 2)
        Expect.equal (seen.flag, 1)
        Expect.equal (seen.text, 1)
    end),

    --[[
        A frame is a field like any other. It is written as a position codec and then a rotation
        codec and those two could reach two different regions, but what dissolved fields share is
        the table a caller wrote them in and a frame is a value the engine carries with no table.
    ]]
    Harness.case ("regions.frame-whole", function ()
        local held = record ({
            at = Lync.cframe (Lync.vec3 (Lync.int (0, NARROW)), Lync.rotation.quat (COARSE)),
            flag = Lync.bool (),
        })

        Expect.equal (paths (held.bytes), "at")
        Expect.equal (paths (held.bits), "flag")
        Expect.equal (paths (held.nests), "")
    end),

    --[[
        A record with no fields at all. Four empty lists rather than a raise, because a struct
        declaring nothing is a legal declaration and what it writes is nothing, which every region
        agrees about.
    ]]
    Harness.case ("regions.empty", function ()
        local held = Regions.of ({})

        Expect.equal (#held.presence, 0)
        Expect.equal (#held.bits, 0)
        Expect.equal (#held.bytes, 0)
        Expect.equal (#held.vars, 0)
        Expect.equal (#held.nests, 0)
    end),

    --[[
        The partition and everything in it is frozen. A layout is settled once at compile and read
        on every frame after, so a caller that could write to a region list would be a caller that
        could move a field between two machines that had already agreed where it was.
    ]]
    Harness.case ("regions.frozen", function ()
        local held = record ({ flag = Lync.bool (), text = Lync.str (0, NARROW) })

        Expect.equal (table.isfrozen (held :: any), true)
        for _, region in { held.presence, held.bits, held.bytes, held.vars, held.nests } do
            Expect.equal (table.isfrozen (region :: any), true)
        end

        Expect.equal (table.isfrozen (held.bits[1] :: any), true)
        Expect.equal (table.isfrozen (held.bits[1].at :: any), true)
    end),
}
