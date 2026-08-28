--!strict
--!optimize 2
-- Bytes and back: what a codec writes, what it reads, and how wide it ever gets.

local Lync = require ("@src")
local Protocol = require ("@src/wire/Protocol")

local Expect = require ("@test/harness/Expect")
local Generate = require ("@test/harness/Generate")
local Harness = require ("@test/harness")
local Rng = require ("@test/harness/Rng")
local Turns = require ("@test/harness/Turns")

-- Constants -----------------------------------------------------------

--[[
    A pair of keys whose bytes add to the same total and read in a definite order, and the domain
    wide enough to hold both in two bytes. What separates ordering by a key from summing one.
]]
const TIED = table.freeze ({ low = 258, high = 513, top = 65535 })

--[[
    The widest value each of the two single-call widths holds, and one narrower than either. A
    record built from the first two sits on byte boundaries and the third never does.
]]
const BYTE_TOP = 255
const PAIR_TOP = 65535
const NARROW_TOP = 7

--[[
    How far either side of nothing a grid reaches when its bottom is not nothing, at one byte wide.
    Split unevenly so the grid fills the byte, since one stopping short of it would be held back by
    the bounds it is read against rather than by needing its reading taken off the grid at all.
]]
const UNDER_ZERO = 128
const OVER_ZERO = 127

--[[
    A reading between two points of a whole-step grid, and the point it rounds onto. Nearer the
    upper point, so a reading taken as it stands rather than rounded lands on the lower one.
]]
const BETWEEN = 20.8
const ONTO = 21

-- A top holding `ONTO` in five bits, which two of in a row put the second one across a byte.
const BAND_TOP = 21

-- A top holding four bits, which two of fill a byte and none of straddles one.
const NIBBLE_TOP = 15

-- The same pair of readings inside four bits, since `BETWEEN` is above what those can carry.
const NIBBLE_BETWEEN = 10.8
const NIBBLE_ONTO = 11

-- A top wide enough for a byte to carry it and short of filling one, so a reading is held to it.
const SHORT_TOP = 200

--[[
    Tops whose widths do not divide a byte between them, and enough of them together to run past
    the four bytes a window plans at once, so one field is left cut across two of them.
]]
const CROWDED = table.freeze ({ 4, 100, 8, 200, 2, 60, 17, 120, 4, 250, 11, 40 })

-- How many two-bit fields it takes to run a word past one window, which is more than sixteen bits.
const TURNED = 12

-- A span wider than the sixteen bits a run can be topped up by in one go, and under the ceiling.
const BROAD = 3000000

--[[
    A span wide enough that the slack a reading is let through by is a whole half step, which is
    what makes a grid hold its readings to the top rather than trust them to land there.
]]
const SLACK = 600000

-- The signed nibble, which fills the four bits it is read at the way the unsigned one fills them.
const SUNK = -(NIBBLE_TOP + 1) // 2
const RISEN = (NIBBLE_TOP - 1) // 2

-- The same either side of nothing at two bytes wide, which is a grid no single byte reaches.
const FAR_SIDE = 30000

--[[
    The widest value a byte holds, and its neighbours either side. A run of the middle one carries
    nothing between elements and the other two do, which is what tells a boundary from a length.
]]
const TOPS = table.freeze ({ under = 254, whole = 255, over = 256 })

--[[
    The widest value at every width the run emitter groups elements by, and at two it does not,
    which the plain walk takes whole. Each top is one under a power of two, so a run of them is
    exactly that width, and the length below leaves every grouping a remainder for that walk too.
]]
const GROUPED = table.freeze ({
    1,
    3,
    7,
    15,
    31,
    63,
    127,
    255,
    511,
    1023,
    2047,
    4095,
    8191,
    16383,
    32767,
    65535,
    131071,
    262143,
    524287,
    1048575,
    2097151,
    4194303,
    8388607,
    16777215,
})
const GROUPS = 19

--[[
    The three shifts of the second filling. Counting down from the top sets every high bit of every
    element, so a bit laid where a one already sits cannot be seen. A stride alone does not fix it
    either: any value linear in the index holds the same low bits at every eighth place, and a group
    is eight elements, so these fold the high bits down and let that place vary.
]]
const SPILL = 2 + 1
const DRAIN = 4 + 2 + 1

--[[
    A word that no one rule covers. Its first field is its own index and leaves patterns its bits
    spell that it has no point for, its second starts under nothing, its third fills its bits
    exactly and its fourth is a flag, so the reading walk is the general one and nothing else.
]]
const MIXED = table.freeze ({ face = 359, lean = 90, zoom = 15 })

--[[
    The two widths the tagged pair in `wire.max-bytes-together` is built from.

    Different on purpose, so neither field can stand in for the other: a value taking one wide
    variant and one thin falls short by exactly what the other would have added.
]]
const WIDE = 40
const NARROW = 12

--[[
    The bounded grid `wire.bounded-shortest` reaches into, and a length it cannot hold.

    A stride of one means everything under half of one comes to no length at all, so a seventh of a
    unit is comfortably inside the class and nowhere near the boundary the rounding sits on.
]]
const REACH = 13
const STRIDE = 1
const SHORT = 0.14

-- The grid `wire.quat-one-spelling` uses, and how far a rotation may land from where it was asked.
const GRIDS = table.freeze ({ 1, 4, 10 })

--[[
    Two families of quaternion, each walked across the surface where its two largest components
    change places.
]]
const CROSSINGS = table.freeze ({
    table.freeze ({ 0.2, 0.3, 0.6, 0.9 }),
    table.freeze ({ -0.27, 0.18, 0.62, 0.66 }),
})

--[[
    How a crossing is swept: how many points either side of it, and how far the sweep reaches.

    Wide enough that the last point is well clear of the crossing and fine enough that no two
    neighbours skip over it, which is what makes a tag that flips somewhere in between visible.
]]
const WALKED = 60
const SWING = 0.4

--[[
    The rotation the fuzzer found, which rounds to one two tags spell exactly. Which of them is
    nearest is not a question that rotation can answer, so the two spellings took turns until the
    choice was pinned. Kept as it was asked about, since that is where the answers part.
]]
const SPELT = table.freeze ({
    0.5646991197162609,
    0.3605041335340491,
    0.2667711667861969,
    0.6928093666139885,
})

-- The widest whole number a varint carries, and the first one it refuses.
const CEILING = Protocol.EXACT

const DEPTH = Generate.DEEP

--[[
    The codecs whose width does not depend on the value, and one value each. Every encode of one of
    these is the same size, so the bound and the encoding are the same number and a suite can say so
    without drawing anything.
]]
const FIXED = table.freeze ({
    table.freeze ({ of = "bool", codec = Lync.bool (), value = true }),
    table.freeze ({ of = "int", codec = Lync.int (-5, 1000), value = 7 }),
    table.freeze ({ of = "quant", codec = Lync.quant (0, 10, 0.5), value = 2.5 }),
    table.freeze ({ of = "angle", codec = Lync.angle (1), value = 90 }),
    table.freeze ({ of = "f32", codec = Lync.f32 (), value = 0.5 }),
    table.freeze ({ of = "f64", codec = Lync.f64 (), value = 0.5 }),
    table.freeze ({ of = "enum", codec = Lync.enum ({ "a", "b", "c" }), value = "b" }),
    table.freeze ({
        of = "bitfield",
        codec = Lync.bitfield ({ "a", "b" }),
        value = { a = true, b = false },
    }),
    table.freeze ({ of = "color3.rgb565", codec = Lync.color3.rgb565 (), value = Color3.new () }),
})

-- Bounds that put a count in two, three and four bytes, and how full a list at each one is filled.
const COUNTS = table.freeze ({
    table.freeze ({ max = 256, bytes = 2, carried = 256 }),
    table.freeze ({ max = 65536, bytes = 3, carried = 65536 }),
    table.freeze ({ max = 16777216, bytes = 4, carried = 0 }),
})

-- Where the letters a one-character element is drawn from start, which is a byte that is never nil.
const LETTER = 65

-- The element shapes a wide count sits in front of, which are written by two different hands.
const ELEMENTS: { Element } = table.freeze ({
    table.freeze ({
        what = "bool",
        of = Lync.bool (),
        bits = 1,
        rows = 3,
        value = function (at: number): any return at % 2 == 1 end,
    }),
    table.freeze ({
        what = "f32",
        of = Lync.f32 (),
        bits = 32,
        rows = 2,
        value = function (at: number): any return at % 2 end,
    }),
    table.freeze ({
        what = "str",
        of = Lync.str (1, 1),
        bits = 8,
        rows = 2,
        value = function (at: number): any return string.char (LETTER + at % 26) end,
    }),
})

-- Types ---------------------------------------------------------------

--[[
    One element a wide-count list is filled with, as the codec, what a value of it is, and how far
    up the bounds it is asked. Untyped in the codec, because the three answer three value types and
    a list over the union of them has no element type to infer.
]]
type Element = {
    read what: string,
    read of: any,
    read bits: number,
    read rows: number,
    read value: (at: number) -> any,
}

-- Private -------------------------------------------------------------

--[[
    A decoded value against the one encoded, at the distance the kind itself declares. A kind that
    keeps less than it was handed declares no distance at all, and what stands in for one is a
    re-encode landing on the bytes that came in.
]]
local function carried (shape: Generate.Shape, want: any, got: any)
    local slack = Generate.slack (shape)
    if slack == nil then return end
    if slack == 0 then
        Expect.equal (got, want)
        return
    end
    Expect.near (got, want, slack)
end

--[[
    One value through a codec and back. Both properties below ask this and differ only in how they
    choose what to ask it of, so the claim is written once and the difference between them stays
    visible as the draw it is.
]]
local function carries (shape: Generate.Shape, value: any, what: string)
    local of = Turns.built (Generate.codec (shape))

    local bytes, size = Turns.wrote (of, value)
    local got = Turns.read (of, bytes, size)
    carried (shape, value, got)

    local again, twice = Turns.wrote (of, got)
    if buffer.readstring (again, 0, twice) == buffer.readstring (bytes, 0, size) then return end

    if twice ~= size then
        Expect.holds (false, `{what} re-encoded to {twice} bytes and not the {size} it read`)
        return
    end
    Expect.holds (false, `{what} re-encoded {size} different bytes`)
end

-- One rotation encoded, read back, and encoded again, held to writing the same bytes both times.
local function stable (of: any, turn: CFrame, slack: number)
    local bytes, size = Turns.wrote (of, turn)
    local got = Turns.read (of, bytes, size)

    local again, twice = Turns.wrote (of, got)
    Expect.equal (twice, size)
    Expect.equal (buffer.readstring (again, 0, twice), buffer.readstring (bytes, 0, size))

    Expect.near (got, turn, slack)
end

-- Public --------------------------------------------------------------

return {
    -- A count wider than one byte, which nothing else in the tree reaches.
    Harness.case ("wire.wide-counts", function ()
        for _, elem in ELEMENTS do
            for index = 1, elem.rows do
                local bound = COUNTS[index]
                local of = Turns.built (Lync.array (elem.of, 0, bound.max))

                local empty, none = Turns.wrote (of, {})
                Expect.holds (none == bound.bytes, `{elem.what} spent {none} on an empty count`)
                Expect.equal (#Turns.read (of, empty, none), 0)

                local reach = bound.carried
                if reach == 0 then continue end

                local held = table.create (reach) :: { any }
                for at = 1, reach do
                    held[at] = elem.value (at)
                end

                local bytes, size = Turns.wrote (of, held)
                Expect.equal (size, bound.bytes + reach * elem.bits // 8)

                local got = Turns.read (of, bytes, size)
                Expect.equal (#got, reach)
                for _, at in { 1, reach // 2, reach } do
                    Expect.holds (got[at] == held[at], `{elem.what} lost the element at {at}`)
                end
            end
        end
    end),

    --[[
        Every kind, at every size it can be asked for. The draw is stratified, so the kinds with the
        most to get wrong get a thirtieth of the budget each rather than the share a flat draw would
        give them.
    ]]
    Harness.property ("wire.matrix", "kinds", function (rng: Rng.Rng)
        local at = Rng.pick (rng, Generate.KINDS)
        local size = Rng.pick (rng, Generate.SIZED)

        local shape = Generate.among (rng, { at }, DEPTH)
        carries (shape, Generate.sized (shape, size, rng), `{at} {size}`)
    end),

    --[[
        Any codec at all, over a value drawn from the parameters that built it, at the iteration a
        fuzzer runs. The matrix above says every kind holds at every size a person would name. This
        says the ones nobody named hold too: a map of tagged variants of optionals, four deep, with
        the counts and lengths wherever the tape put them.
    ]]
    Harness.property ("wire.identity", "encode", function (rng: Rng.Rng)
        local shape = Generate.shape (rng, DEPTH)
        carries (shape, Generate.value (shape, rng), shape.at)
    end),

    --[[
        The bound is exact, both ways round. No value the codec accepts encodes past it, and some
        value it accepts reaches it, which is the half a suite forgets: a bound that is merely large
        passes every encode and tells a frame assembler to reserve room nobody needs.
    ]]
    Harness.property ("wire.max-bytes", "kinds", function (rng: Rng.Rng)
        local shape = Generate.shape (rng, DEPTH)
        local of = Turns.built (Generate.codec (shape))

        local _, drawn = Turns.wrote (of, Generate.value (shape, rng))
        Expect.holds (drawn <= of.maxBytes, `{shape.at} wrote {drawn} of {of.maxBytes} bytes`)

        local reached = 0
        for _, candidate in Generate.widest (shape) do
            local _, size = Turns.wrote (of, candidate)
            if size > reached then reached = size end
        end

        if reached == of.maxBytes then return end
        Expect.holds (false, `{shape.at} promises {of.maxBytes} bytes and reaches {reached}`)
    end),

    --[[
        Rotations whose largest component is not settled by rounding, encoded twice. The scheme
        drops one and names it and the three that travel are rounded, so the bytes can say one place
        while the rebuilt value says another and the two spellings take turns forever.
    ]]
    Harness.case ("wire.quat-one-spelling", function ()
        for _, apart in GRIDS do
            local of = Turns.built (Lync.rotation.quat (apart))
            local slack = 2 * math.sin (math.rad (apart) / 2)

            for _, held in CROSSINGS do
                for step = 0, WALKED do
                    local moved = SWING * (step / WALKED - 0.5)

                    stable (
                        of,
                        CFrame.new (0, 0, 0, held[1], held[2], held[3] + moved, held[4] - moved),
                        slack
                    )
                end
            end

            stable (of, CFrame.new (0, 0, 0, SPELT[1], SPELT[2], SPELT[3], SPELT[4]), slack)
        end
    end),

    --[[
        Vectors too short for the grid to give a length, which are all one value and so all one set
        of bytes. Below half a step the distance comes to none, and anything reading back the same
        has to write the same or the bytes carry what no reader can see.
    ]]
    Harness.case ("wire.bounded-shortest", function ()
        local of = Turns.built (Lync.vec3.bounded (REACH, STRIDE))

        local first = nil
        for _, one in
            {
                Vector3.zero,
                Vector3.new (SHORT, 0, 0),
                Vector3.new (-SHORT, -SHORT, SHORT),
                Vector3.new (0, 0, -SHORT),
            }
        do
            local bytes, size = Turns.wrote (of, one)
            local held = buffer.readstring (bytes, 0, size)

            Expect.equal (Turns.read (of, bytes, size), Vector3.zero)
            if first == nil then first = held end

            Expect.equal (held, first)
        end
    end),

    -- A record whose width two of its fields decide together.
    Harness.case ("wire.max-bytes-together", function ()
        local of = Turns.built (Lync.struct ({
            left = Lync.tagged ("tag", {
                thin = Lync.struct ({ v = Lync.bool () }),
                wide = Lync.struct ({ v = Lync.str (0, WIDE) }),
            }),
            right = Lync.tagged ("tag", {
                thin = Lync.struct ({ v = Lync.bool () }),
                wide = Lync.struct ({ v = Lync.str (0, NARROW) }),
            }),
        }))

        local widest = {
            left = { tag = "wide", v = string.rep ("x", WIDE) },
            right = { tag = "wide", v = string.rep ("x", NARROW) },
        }

        local _, reached = Turns.wrote (of, widest)
        Expect.equal (reached, of.maxBytes)

        -- Either field left thin falls short, which is what makes the bound theirs together.
        for _, name in { "left", "right" } do
            local held = { left = widest.left, right = widest.right }
            held[name] = { tag = "thin", v = true }

            local _, short = Turns.wrote (of, held)
            Expect.holds (short < of.maxBytes, `{name} alone reached the bound`)
        end
    end),

    --[[
        A record whose fields each start on a byte and are as wide as one call the engine has,
        laid down where each field sits rather than gathered through a window first. Both widths
        are here because a word writing every field as one byte would still carry the narrow one.
    ]]
    Harness.case ("wire.a-record-on-byte-boundaries", function ()
        local of = Turns.built (Lync.struct ({
            small = Lync.int (0, BYTE_TOP),
            wide = Lync.int (0, PAIR_TOP),
            after = Lync.int (0, BYTE_TOP),
        }))

        local value = { small = BYTE_TOP, wide = PAIR_TOP - 1, after = 1 }
        local bytes, size = Turns.wrote (of, value)

        Expect.equal (Turns.read (of, bytes, size), value)
    end),

    --[[
        A record on byte boundaries whose fields do not start their grids at nothing, so the index
        a byte carries is not the value and has to be read back off the grid. The field beside it
        does start at nothing, which is what keeps the two apart rather than one standing for both.
    ]]
    Harness.case ("wire.a-record-on-boundaries-off-its-own-zero", function ()
        local of = Turns.built (Lync.struct ({
            shift = Lync.int (-UNDER_ZERO, OVER_ZERO),
            flat = Lync.int (0, BYTE_TOP),
        }))

        for _, one in { -UNDER_ZERO, 0, OVER_ZERO } do
            local value = { shift = one, flat = BYTE_TOP }
            local bytes, size = Turns.wrote (of, value)

            Expect.equal (Turns.read (of, bytes, size), value)
        end
    end),

    --[[
        A record on byte boundaries handed a value between two of its points. Where a field is put
        down as it stands rather than computed, a value that is already a whole number on the grid
        is the one this can be done for, and one that is not still has to be rounded onto it.
    ]]
    Harness.case ("wire.a-record-on-boundaries-rounds-onto-its-grid", function ()
        local of = Turns.built (Lync.struct ({
            near = Lync.int (0, BYTE_TOP),
            after = Lync.int (0, BYTE_TOP),
        }))

        local bytes, size = Turns.wrote (of, { near = BETWEEN, after = 0 })
        Expect.equal (Turns.read (of, bytes, size), { near = ONTO, after = 0 })
    end),

    --[[
        The same where the byte is not filled by what it carries, so the reading is held to the top
        of its grid on the way back. A record put down as it stands is recognised field by field,
        and a reading between two points is no field to recognise.
    ]]
    Harness.case ("wire.a-held-record-rounds-onto-its-grid", function ()
        local of = Turns.built (Lync.struct ({
            near = Lync.int (0, SHORT_TOP),
            after = Lync.int (0, SHORT_TOP),
        }))

        local bytes, size = Turns.wrote (of, { near = BETWEEN, after = 0 })
        Expect.equal (Turns.read (of, bytes, size), { near = ONTO, after = 0 })
    end),

    --[[
        The same where the fields share their bytes two to one and none of them is cut, which is
        the record gathered a window at a time rather than a byte at a time.
    ]]
    Harness.case ("wire.a-shared-record-rounds-onto-its-grid", function ()
        local of = Turns.built (Lync.struct ({
            one = Lync.int (0, NIBBLE_TOP),
            two = Lync.int (0, NIBBLE_TOP),
            three = Lync.int (0, NIBBLE_TOP),
            four = Lync.int (0, NIBBLE_TOP),
        }))

        local was = { one = NIBBLE_BETWEEN, two = 0, three = 0, four = 0 }
        local bytes, size = Turns.wrote (of, was)

        Expect.equal (
            Turns.read (of, bytes, size),
            { one = NIBBLE_ONTO, two = 0, three = 0, four = 0 }
        )
    end),

    --[[
        The same across widths that do not divide a byte between them, so no field sits where the
        one before it left off and the rounding has to hold wherever a field was put.
    ]]
    Harness.case ("wire.a-mixed-record-rounds-onto-its-grid", function ()
        local of = Turns.built (Lync.struct ({
            a = Lync.int (0, NIBBLE_TOP),
            b = Lync.int (0, PAIR_TOP),
            c = Lync.int (0, BYTE_TOP),
            d = Lync.int (0, SHORT_TOP),
            e = Lync.int (0, BAND_TOP),
        }))

        local was = { a = 0, b = 0, c = 0, d = BETWEEN, e = BETWEEN }
        local bytes, size = Turns.wrote (of, was)

        Expect.equal (Turns.read (of, bytes, size), { a = 0, b = 0, c = 0, d = ONTO, e = ONTO })
    end),

    --[[
        A record wider than one window where no field's grid runs from nothing, which is the pair
        neither of the two above reaches. What is held here is the way back: a reading over the top
        of a piece, which no encode of this word produces and only forged bytes can say.
    ]]
    Harness.case ("wire.a-wide-turned-record-refuses-a-forged-piece", function ()
        local fields = {}
        local was = {}

        for at = 1, TURNED do
            local name = string.char (string.byte ("a") + at - 1)
            fields[name] = Lync.int (-1, 1)
            was[name] = at % 3 - 1
        end

        local of = Turns.built (Lync.struct (fields))
        local bytes, size = Turns.wrote (of, was)
        Expect.equal (Turns.read (of, bytes, size), was)

        -- Every bit of the first window set, which spells each piece in it over its own top.
        buffer.writeu8 (bytes, 0, 0xFF)
        Expect.throws (function () Turns.read (of, bytes, size) end)
    end),

    --[[
        A run whose elements are wider than a pair of bytes. What the walk carries between the bytes
        and the values holds thirty two bits, so a run this wide is taken a byte at a time where a
        narrower one is taken two, and only a round trip says which it took.
    ]]
    Harness.case ("wire.a-run-wider-than-a-pair-carries-both-ways", function ()
        local of = Turns.built (Lync.array (Lync.int (0, BROAD), 0, TURNED))

        local was = {}
        for at = 1, TURNED do
            was[at] = (at - 1) * (BROAD // TURNED)
        end

        local bytes, size = Turns.wrote (of, was)

        Expect.equal (Turns.read (of, bytes, size), was)
    end),

    --[[
        A run holding something that is no number at all. A grid takes a whole list at once where
        it offers that, so the one thing on the list that is no place on it has to come back out of
        a walk that is no longer asking about them one at a time.
    ]]
    Harness.case ("wire.a-run-turns-away-what-is-no-number", function ()
        local of = Turns.built (Lync.array (Lync.int (0, NIBBLE_TOP), 0, TURNED))

        Expect.throws (function () Turns.wrote (of, { 1, 2, "three" :: any, 4 }) end, "got three")
    end),

    --[[
        A run holding readings between the points of its grid, which the grid puts on the nearest
        one. A midpoint goes up, and that is the half of the rule a list has to keep as much as a
        single reading does.
    ]]
    Harness.case ("wire.a-run-puts-its-readings-on-the-nearest-point", function ()
        local of = Turns.built (Lync.array (Lync.int (0, NIBBLE_TOP), 0, TURNED))

        local bytes, size = Turns.wrote (of, { 3.4, 3.5, 3.6 })

        Expect.equal (Turns.read (of, bytes, size), { 3, 4, 4 })
    end),

    --[[
        A run over a span so wide the slack is a whole half step, holding a reading that the slack
        let through and the rounding then took past the last point. The grid holds it there, and a
        list of them is held the same way one of them is.
    ]]
    Harness.case ("wire.a-run-holds-a-reading-at-the-top-of-its-grid", function ()
        local of = Turns.built (Lync.array (Lync.int (0, SLACK), 0, TURNED))

        local bytes, size = Turns.wrote (of, { SLACK + 0.5, 0 })

        Expect.equal (Turns.read (of, bytes, size), { SLACK, 0 })
    end),

    --[[
        A run of a grid filling the bits it is read at without running from nothing. No reading of
        such a run is off the grid, and every one of them still has to be put back on it, which is
        neither of the two things a run of a plain grid does.
    ]]
    Harness.case ("wire.a-run-of-a-turned-grid-carries-both-ways", function ()
        local of = Turns.built (Lync.array (Lync.int (SUNK, RISEN), 0, TURNED))

        local was = {}
        for at = 1, TURNED do
            was[at] = SUNK + (at - 1) % (RISEN - SUNK + 1)
        end

        local bytes, size = Turns.wrote (of, was)

        Expect.equal (Turns.read (of, bytes, size), was)
    end),

    --[[
        A record wider than one window where some grids run from nothing and some do not, and every
        one of them fills the bits it is read at. Nothing off such a word is over the top of its own
        grid, so the walk back holds none of them to one and only a round trip says it walked.
    ]]
    Harness.case ("wire.a-wide-mixed-record-carries-both-ways", function ()
        local of = Turns.built (Lync.struct ({
            a = Lync.int (0, NIBBLE_TOP),
            b = Lync.int (SUNK, RISEN),
            c = Lync.int (0, NIBBLE_TOP),
            d = Lync.int (SUNK, RISEN),
            e = Lync.int (0, NIBBLE_TOP),
            f = Lync.int (SUNK, RISEN),
        }))

        local was = { a = 0, b = SUNK, c = NIBBLE_TOP, d = RISEN, e = 4, f = -1 }
        local bytes, size = Turns.wrote (of, was)

        Expect.equal (Turns.read (of, bytes, size), was)
    end),

    --[[
        The same where the fields together run past the four bytes a window plans at once, so one
        of them is cut and the record goes down through a run of indices held aside.
    ]]
    Harness.case ("wire.a-cut-record-rounds-onto-its-grid", function ()
        local fields = {}
        local was = {}
        local want = {}

        for at, top in CROWDED do
            local name = string.char (string.byte ("a") + at - 1)
            fields[name] = Lync.int (0, top)

            -- Only a grid reaching `ONTO` can be handed a reading between two of its points.
            was[name] = if top >= ONTO then BETWEEN else 0
            want[name] = if top >= ONTO then ONTO else 0
        end

        local of = Turns.built (Lync.struct (fields))
        local bytes, size = Turns.wrote (of, was)

        Expect.equal (Turns.read (of, bytes, size), want)
    end),

    --[[
        The same off its own zero where one field is wider than a byte, so the reading back happens
        in a record laid down by two different calls rather than one repeated. The third field
        fills the four bytes a word plans at once, which is what keeps the wide one from being cut.
    ]]
    Harness.case ("wire.a-wider-record-on-boundaries-off-its-own-zero", function ()
        local of = Turns.built (Lync.struct ({
            shift = Lync.int (-UNDER_ZERO, OVER_ZERO),
            wider = Lync.int (-FAR_SIDE, FAR_SIDE),
            flat = Lync.int (0, BYTE_TOP),
        }))

        for _, one in { -FAR_SIDE, 0, FAR_SIDE } do
            local value = { shift = OVER_ZERO, wider = one, flat = BYTE_TOP }
            local bytes, size = Turns.wrote (of, value)

            Expect.equal (Turns.read (of, bytes, size), value)
        end
    end),

    --[[
        The same widths where a bit ahead of them puts every field off its boundary, which has to
        keep going through the windows: a field written to the byte it nearly starts on would
        stand on the one before it.
    ]]
    Harness.case ("wire.a-record-a-bit-off-its-boundaries", function ()
        local of = Turns.built (Lync.struct ({
            flag = Lync.bool (),
            small = Lync.int (0, BYTE_TOP),
            wide = Lync.int (0, PAIR_TOP),
        }))

        local value = { flag = true, small = BYTE_TOP, wide = PAIR_TOP - 1 }
        local bytes, size = Turns.wrote (of, value)

        Expect.equal (Turns.read (of, bytes, size), value)
    end),

    --[[
        A field on a boundary at a width no single call reaches, beside one that is. Writing the
        narrow field as though it were a whole word would carry off the bytes behind it.
    ]]
    Harness.case ("wire.a-record-on-boundaries-at-an-odd-width", function ()
        local of = Turns.built (Lync.struct ({
            small = Lync.int (0, BYTE_TOP),
            narrow = Lync.int (0, NARROW_TOP),
            after = Lync.int (0, BYTE_TOP),
        }))

        local value = { small = BYTE_TOP, narrow = NARROW_TOP, after = BYTE_TOP }
        local bytes, size = Turns.wrote (of, value)

        Expect.equal (Turns.read (of, bytes, size), value)
    end),

    --[[
        A codec the compiler calls fixed writes one width for every value it takes. That is what
        lets a word plan resolve at compile time and a frame reserve its room without looking, so a
        kind marked fixed that is not would be a wrong number everywhere downstream rather than a
        wrong value anywhere here.
    ]]
    Harness.case ("wire.fixed-width", function ()
        for _, entry in FIXED do
            local of = Turns.built (entry.codec)
            if not of.fixed then
                Expect.holds (false, `{entry.of} is not marked fixed`)
                continue
            end

            local _, size = Turns.wrote (of, entry.value)
            if size == of.maxBytes then continue end
            Expect.holds (false, `{entry.of} wrote {size} of a fixed {of.maxBytes}`)
        end
    end),

    --[[
        The degenerate sizes, which are where an off-by-one lives. An empty collection is a count
        and nothing else, and a range holding one value is a count of no bits at all, so both come
        to nothing on the wire and both still have to come back.
    ]]
    Harness.case ("wire.degenerate", function ()
        local empty = {
            { of = "str", codec = Lync.str (0, 0), value = "" },
            { of = "buffer", codec = Lync.buffer (0, 0), value = buffer.create (0) },
            { of = "array", codec = Lync.array (Lync.bool (), 0, 0), value = {} },
            { of = "map", codec = Lync.map (Lync.int (0, 3), Lync.bool (), 0, 0), value = {} },
        }
        for _, entry in empty do
            local of = Turns.built (entry.codec)
            local bytes, size = Turns.wrote (of, entry.value)

            Expect.equal (size, 0)
            Expect.equal (of.maxBytes, 0)
            Expect.equal (Turns.read (of, bytes, size), entry.value)
        end

        local one = Turns.built (Lync.int (5, 5))
        Expect.equal (one.maxBytes, 0)

        local bytes, size = Turns.wrote (one, 5)
        Expect.equal (size, 0)
        Expect.equal (Turns.read (one, bytes, size), 5)
    end),

    --[[
        A varint carries every whole number a double counts exactly, and refuses the first one it
        does not. The ceiling is where the zigzag of a signed value needs a fifty-fourth bit, which
        is why the design computes the mapping in the integer domain and the group cap enforces the
        same ceiling on the way back in.
    ]]
    Harness.case ("codec.vlq", function ()
        local of = Turns.built (Lync.vlq ())

        for _, value in { 0, 1, 127, 128, 2 ^ 32, CEILING - 1 } do
            local bytes, size = Turns.wrote (of, value)
            Expect.equal (Turns.read (of, bytes, size), value)
        end

        Expect.throws (function () Turns.wrote (of, CEILING) end)
        Expect.throws (function () Turns.wrote (of, -1) end)
        Expect.throws (function () Turns.wrote (of, 1.5) end)
    end),

    --[[
        The signed form, at both ends and at the sign itself. Minus one is the value a zigzag maps
        to one, so an encoder that shifted without folding would spend nine groups on it and still
        read it back, which is a size fault that no round trip notices and every golden does.
    ]]
    Harness.case ("codec.vli", function ()
        local of = Turns.built (Lync.vli ())

        for _, value in { 0, -1, 1, -127, 128, -(CEILING - 1), CEILING - 1 } do
            local bytes, size = Turns.wrote (of, value)
            Expect.equal (Turns.read (of, bytes, size), value)
        end

        Expect.throws (function () Turns.wrote (of, CEILING) end)
        Expect.throws (function () Turns.wrote (of, -CEILING) end)
        Expect.throws (function () Turns.wrote (of, 1.5) end)
    end),

    --[[
        A name the frame left out is one the record does not carry, rather than one carrying a
        stand-in. Whether the field is there is a question about the key, so a record holding it at
        any value at all answers the opposite of what the wire said.
    ]]
    Harness.case ("wire.absent-optional", function ()
        local of = Turns.built (Lync.struct ({
            kept = Lync.bool (),
            gone = Lync.optional (Lync.str (1, 8)),
        }))

        local bytes, size = Turns.wrote (of, { kept = true })
        local back = Turns.read (of, bytes, size)

        Expect.equal (back.kept, true)
        Expect.holds (back.gone == nil, `an absent name came back as {tostring (back.gone)}`)

        local names = 0
        for _ in back do
            names += 1
        end

        Expect.equal (names, 1)
    end),

    --[[
        A run whose elements are exactly a byte, which is the width where nothing is carried from
        one element to the next. The run either side of it is what says the boundary is where the
        difference is, rather than anywhere a run of that length happens to land.
    ]]
    Harness.case ("wire.byte-wide-run", function ()
        for _, top in { TOPS.under, TOPS.whole, TOPS.over } do
            local of = Turns.built (Lync.array (Lync.int (0, top), 0, 32))

            local held = {}
            for index = 1, 32 do
                held[index] = (index * 7) % (top + 1)
            end

            local bytes, size = Turns.wrote (of, held)
            local back = Turns.read (of, bytes, size)

            Expect.equal (#back, 32)
            for index = 1, 32 do
                Expect.equal (back[index], held[index])
            end
        end
    end),

    --[[
        A run at every width the emitter takes elements in groups at, each one long enough to
        leave a remainder. A group laid whole and a remainder laid the plain way have to agree on
        where the run ends as well as on what it holds, so the length is read back beside it.
    ]]
    Harness.case ("wire.grouped-widths", function ()
        for _, top in GROUPED do
            local of = Turns.built (Lync.array (Lync.int (0, top), 0, GROUPS))

            for _, counted in { true, false } do
                local held = {}
                for index = 1, GROUPS do
                    if counted then
                        held[index] = (index * top) % (top + 1)
                    else
                        local one = (index * top) % (top + 1)
                        one = bit32.bxor (one, bit32.rshift (one, SPILL))
                        one = bit32.bxor (one, bit32.rshift (one, DRAIN))
                        held[index] = one % (top + 1)
                    end
                end

                local bytes, size = Turns.wrote (of, held)
                local back = Turns.read (of, bytes, size)

                Expect.equal (#back, GROUPS)
                for index = 1, GROUPS do
                    Expect.equal (back[index], held[index])
                end
            end
        end
    end),

    --[[
        One value standing alone rather than as a field of a record, at each width a word takes it
        in. What it came back as is compared rather than only that it came back at all: a byte read
        where a pair was written answers every value under two hundred and fifty six correctly.
    ]]
    Harness.case ("wire.lone-word", function ()
        for _, top in { 255, 65535 } do
            local of = Turns.built (Lync.int (0, top))

            for _, one in { 0, 1, top // 2, top } do
                local bytes, size = Turns.wrote (of, one)
                Expect.equal (Turns.read (of, bytes, size), one)
            end
        end
    end),

    --[[
        Every field of that word back as it went. A word taking the general walk is read a piece at
        a time against the grid each one belongs to, where the three walks beside it hold every
        piece to one rule, so what this says is that the pieces are told apart at all.
    ]]
    Harness.case ("wire.mixed-word", function ()
        local of = Turns.built (Lync.struct ({
            face = Lync.int (0, MIXED.face),
            pitch = Lync.int (-MIXED.lean, MIXED.lean),
            zoom = Lync.int (0, MIXED.zoom),
            firing = Lync.bool (),
        }))

        for _, face in { 0, 1, MIXED.face } do
            for _, pitch in { -MIXED.lean, 0, MIXED.lean } do
                local held = { face = face, pitch = pitch, zoom = MIXED.zoom, firing = true }

                local bytes, size = Turns.wrote (of, held)
                local back = Turns.read (of, bytes, size)

                Expect.equal (back.face, face)
                Expect.equal (back.pitch, pitch)
                Expect.equal (back.zoom, MIXED.zoom)
                Expect.equal (back.firing, true)
            end
        end
    end),

    --[[
        Keys that tie when their bytes are added and do not when they are read in order. A map is
        ordered by what its keys spell rather than by what they add up to, and the two agree often
        enough that a pair which parts them is the only thing that says which one is being used.
    ]]
    Harness.case ("wire.map-key-order", function ()
        local of = Turns.built (Lync.map (Lync.int (0, TIED.top), Lync.int (0, 9), 0, 8))

        local held = { [TIED.low] = 1, [TIED.high] = 2 }
        local bytes, size = Turns.wrote (of, held)
        local back = Turns.read (of, bytes, size)

        Expect.equal (back[TIED.low], 1)
        Expect.equal (back[TIED.high], 2)
    end),

    --[[
        Keys where one is the whole beginning of another, which is the pair that says a shorter key
        comes first, and two of one length wide enough to fill a leading number, which part at
        their fourth byte and cross back at their fifth, so every byte of one is read from where it
        belongs and read once.
    ]]
    Harness.case ("wire.map-key-prefixes", function ()
        local of = Turns.built (Lync.map (Lync.str (0, 8), Lync.int (0, 9), 0, 8))

        local held: { [string]: number } =
            { a = 1, ab = 2, abc = 3, b = 4, ba = 5, abcza = 6, abdaz = 7 }
        local bytes, size = Turns.wrote (of, held)
        local back = Turns.read (of, bytes, size)

        for key, value in held do
            Expect.equal (back[key], value)
        end

        local names = 0
        for _ in back do
            names += 1
        end

        Expect.equal (names, 7)
    end),
}
