--!strict
--!optimize 2
-- The edge of a domain from the writing side: what a codec refuses, and what it says.

local Lync = require ("@src")
local Shape = require ("@src/shape")

local Expect = require ("@test/harness/Expect")
local Generate = require ("@test/harness/Generate")
local Harness = require ("@test/harness")
local Rng = require ("@test/harness/Rng")

-- Constants -----------------------------------------------------------

--[[
    Where every codec here is built, and why it is not the `at` its neighbours use. This suite
    reads the line a throw carries and can only hold it to naming the path. Two lowercase letters
    hide inside ordinary English, so a message naming no path would pass on any sentence spelling
    `that`, where a capitalised word shaped like a definition name cannot be spelled by accident.
]]
const ROOT = "Origin"

-- Where every encode here is written, once for the run.
const ROOM = 2 ^ 18
const SLAB = buffer.create (ROOM)

const DEPTH = Generate.DEEP

--[[
    The kinds whose value one step outside is a value of the same Luau type, merely out of the
    domain. Only those reach a schema's own rejection: a number where a Vector3 belongs raises out
    of whichever operation touched it, which is a refusal and is all `wire.refuses` asks of it, and
    it carries no path for a line to name.
]]
const RANGED = table.freeze ({
    "int",
    "quant",
    "vlq",
    "vli",
    "str",
    "str.alphabet",
    "buffer",
    "enum",
    "vec3.bounded",
    "color3.palette",
})

--[[
    The kinds that round a number onto a grid, and one built form of each. Every one of them has to
    answer a value that is not a number before it computes an index, because rounding answers
    something for every double it is handed and the guard in front of it is the whole of the
    refusal.
]]
const GRIDDED = table.freeze ({
    table.freeze ({ of = "int", codec = Lync.int (-10, 10) }),
    table.freeze ({ of = "quant", codec = Lync.quant (-10, 10, 0.5) }),
    table.freeze ({ of = "angle", codec = Lync.angle (1) }),
    table.freeze ({ of = "vlq", codec = Lync.vlq () }),
    table.freeze ({ of = "vli", codec = Lync.vli () }),
})

--[[
    The two kinds that carry a value off every grid rather than refusing it. An IEEE span has a
    place for every bit pattern a double takes, so a codec refusing one here would be refusing a
    value its own wire form holds.
]]
const CARRIES = table.freeze ({
    table.freeze ({ of = "f32", codec = Lync.f32 () }),
    table.freeze ({ of = "f64", codec = Lync.f64 () }),
})

-- The three numbers no grid holds, whatever the grid.
const UNREAL = table.freeze ({ 0 / 0, math.huge, -math.huge })

--[[
    A key codec coarser than the keys a caller can hand it, and the two maps over it that separate a
    repeat from a pair.
]]
const COARSE = Lync.quant (0, 1, 0.5)
const KEYS = 4

--[[
    What a bounded map may hold, and the two counts either side of it. A map counts its entries as
    it walks them, so the bound is held once a key rather than once a call, and a walk that never
    reaches the count is a walk that never reaches the bound either.
]]
const FEWEST = 2
const MOST = 3
const TOGETHER = table.freeze ({ [0.1] = true, [0.2] = false })
const APART = table.freeze ({ [0] = true, [1] = false })

-- Private -------------------------------------------------------------

local function built (codec: any): any
    local of = Shape.build (codec, ROOT)
    Expect.holds (of.maxBytes * 2 <= ROOM, `a codec of {of.maxBytes} bytes outgrows the slab`)
    return of
end

--[[
    The line a refused encode raised. Every caller wants the line rather than the fact, because the
    fact alone is satisfied by a codec that overran the buffer it was handed, and the slab is wide
    enough that nothing but the codec is left to raise.
]]
local function refused (of: any, value: any, what: string): string
    local ok, caught = pcall (of.write, SLAB, 0, value)
    if not ok then return tostring (caught) end

    Expect.holds (false, `{what} encoded to {caught} bytes`)
    return ""
end

--[[
    Whether the value one step outside this shape reaches a codec that writes nothing at all. An
    optional hands its own outside value straight to the kind inside it, so an optional of the total
    kind is total too, and every other composite refuses before its child is reached.
]]
local function totalled (shape: Generate.Shape): boolean
    if shape.at == "optional" then return totalled (shape.of[1]) end
    return shape.at == Generate.TOTAL
end

-- Whether a line spelled something out, which is all this file reads of a line.
local function names (line: string, part: string, what: string)
    if string.find (line, part, 1, true) ~= nil then return end
    Expect.holds (false, `{what} threw {line}, which does not name {part}`)
end

--[[
    A codec wrapped in one named field of a struct, and the value that reaches it. Siblings either
    side, because a struct of one field cannot tell a line that names the field which failed from
    one that names the only field there is, and canonical name order puts one sibling before it and
    one after.
]]
local function inside (codec: any, value: any, level: number): (any, any)
    local before, at, after = `a{level}`, `f{level}`, `z{level}`

    local fields = { [before] = Lync.bool (), [at] = codec, [after] = Lync.bool () }
    local record = { [before] = true, [at] = value, [after] = false }
    return Lync.struct (fields), record
end

-- Public --------------------------------------------------------------

return {
    --[[
        Every kind, and the one value a step outside it. Both halves ride one draw, because the
        claim is that the domain has an edge rather than that the codec refuses things: a value
        inside encodes and the same codec's value outside does not.
    ]]
    Harness.property ("wire.refuses", "encode", function (rng: Rng.Rng)
        local shape = Generate.shape (rng, DEPTH)
        local of = built (Generate.codec (shape))

        local ok, at = pcall (of.write, SLAB, 0, Generate.value (shape, rng))
        Expect.holds (ok, `{shape.at} refused a value of its own domain: {tostring (at)}`)

        if totalled (shape) then return end
        refused (of, Generate.outside (shape, rng), shape.at)
    end),

    --[[
        A value out of range at a named node, at every depth a draw reaches. The path is the half of
        the line a caller navigates by, and a root is not a path: a codec carrying the string it was
        built at and nothing else answers every fault in a schema with the same line, and the whole
        of what the interned path tables buy is that it does not.
    ]]
    Harness.property ("wire.names-path", "encode", function (rng: Rng.Rng)
        local shape = Generate.among (rng, RANGED, 0)
        local codec = Generate.codec (shape)
        local value = Generate.outside (shape, rng)

        local levels = Rng.int (rng, 0, DEPTH)
        for level = levels, 1, -1 do
            codec, value = inside (codec, value, level)
        end

        local line = refused (built (codec), value, shape.at)
        names (line, ROOT, shape.at)

        for level = 1, levels do
            names (line, `f{level}`, shape.at)
        end
    end),

    --[[
        The three parts of a line, held apart. What a caller needs back from a refused encode is
        where it happened, what was expected there and what arrived instead, and the wording
        carrying those is an implementation freedom the goldens pin rather than this file.
    ]]
    Harness.case ("wire.names-fault", function ()
        local function faulted (span: number, at: string, value: number): string
            local codec = Lync.struct ({ [at] = Lync.int (0, span), keep = Lync.bool () })
            return refused (built (codec), { [at] = value, keep = true }, `int at {at}`)
        end

        local base = faulted (10, "spot", 11)
        Expect.holds (faulted (10, "spot", 12) ~= base, `two values read alike: {base}`)
        Expect.holds (faulted (10, "mark", 11) ~= base, `two paths read alike: {base}`)
        Expect.holds (faulted (5, "spot", 11) ~= base, `two expectations read alike: {base}`)
    end),

    --[[
        The numbers that are on no grid. NaN is the one that gets through a guard written the
        obvious way round, because it compares false against the lower bound and false against the
        upper one, and rounding it answers a NaN index that lands in the buffer as whatever the
        write op makes of it. The infinities sit beside it as the same guard's other two answers.
    ]]
    Harness.case ("wire.not-a-number", function ()
        for _, entry in GRIDDED do
            local of = built (entry.codec)
            for _, value in UNREAL do
                refused (of, value, `{entry.of} given {value}`)
            end
        end

        for _, entry in CARRIES do
            local of = built (entry.codec)
            local ok = pcall (of.write, SLAB, 0, 0 / 0)
            Expect.holds (ok, `{entry.of} refused a value its span carries`)
        end
    end),

    --[[
        Two keys one schema cannot tell apart, refused on the machine that wrote them. A key codec
        rounding onto a grid has fewer codes than the doubles a caller can key a table by, so the
        pair that sorted second lands on top of the first and the map comes back a pair short of its
        own count.
    ]]
    Harness.case ("wire.keys-apart", function ()
        local of = built (Lync.map (COARSE, Lync.bool (), 0, KEYS))
        names (refused (of, TOGETHER, "two keys on one point"), ROOT, "a key collision")

        Expect.holds (of.write (SLAB, 0, APART) > 0, "two keys on two points wrote nothing")
    end),

    --[[
        A map holding more than its bound, and one holding less, refused where they were written.
        Both key forms are put to it: keys that sit on a grid sort as the indices they land on and
        keys spelled as bytes sort by what they spell, so each counts its own entries and a bound
        held by one of them is not a bound held by the other.
    ]]
    Harness.case ("wire.map-bounds", function ()
        local forms = {
            { of = "gridded", codec = Lync.map (Lync.int (0, 15), Lync.bool (), FEWEST, MOST) },
            { of = "spelled", codec = Lync.map (Lync.str (1, 2), Lync.bool (), FEWEST, MOST) },
        }

        for _, form in forms do
            local of = built (form.codec)

            local function holding (count: number): any
                local made: any = {}
                for index = 1, count do
                    made[if form.of == "gridded" then index else tostring (index)] = true
                end
                return made
            end

            refused (of, holding (FEWEST - 1), `a {form.of} map under its bound of {FEWEST}`)
            refused (of, holding (MOST + 1), `a {form.of} map over its bound of {MOST}`)

            local wrote = of.write (SLAB, 0, holding (FEWEST))
            Expect.holds (wrote > 0, `a {form.of} map inside its bounds wrote nothing`)
        end
    end),

    --[[
        An element of a packed run that sits on no point of its grid, refused where it was written.
        A run carries one grid across every element and asks it once each, so an element the grid
        cannot answer is one the run has nowhere to put, and writing it would spell some other
        element's value in its place.
    ]]
    Harness.case ("wire.run-element-off-its-grid", function ()
        local of = built (Lync.array (Lync.int (0, 3), 1, 4))

        Expect.holds (
            of.write (SLAB, 0, { 1, 2, 3 }) > 0,
            "a run of values on its grid wrote nothing"
        )
        -- Named, since a run writing a nothing raises where the nothing is read instead.
        names (refused (of, { 1, 9 }, "a run element over its grid"), ROOT, "an element over")
        names (refused (of, { -1, 2 }, "a run element under its grid"), ROOT, "an element under")
        names (refused (of, { 1, 0 / 0 }, "a run element on no grid"), ROOT, "an element off")
    end),

    --[[
        The values a composite has nowhere to put, refused where they were written and named where
        they were. A record is what a group reads its fields out of, a tag is what a union picks an
        arm by, and a map asks its grids once a key and once a value, so each of them turns away a
        value of its own kind and each says which one it was.
    ]]
    Harness.case ("wire.composites-refuse-what-they-cannot-hold", function ()
        local nested = built (Lync.struct ({ inner = Lync.struct ({ n = Lync.int (0, 5) }) }))
        names (
            refused (nested, { inner = 7 }, "a record given something that is not one"),
            ROOT,
            "a record of no table"
        )

        local picked = built (Lync.tagged ("tag", {
            a = Lync.struct ({ x = Lync.bool () }),
            b = Lync.struct ({ y = Lync.bool () }),
        }))
        names (
            refused (picked, { tag = "c", z = true }, "a tag naming no arm"),
            ROOT,
            "a tag of no arm"
        )

        --[[
            Both map forms, since keys on a grid sort as the indices they land on and keys spelled
            as bytes sort by what they spell, and each asks its own grids in a walk of its own.
        ]]
        local gridded = built (Lync.map (Lync.int (0, 5), Lync.int (0, 5), 0, 4))
        names (refused (gridded, { [9] = 1 }, "a map key off its grid"), ROOT, "a key off its grid")
        names (
            refused (gridded, { [1] = 9 }, "a map value off its grid"),
            ROOT,
            "a value off its grid"
        )

        local spelled = built (Lync.map (Lync.str (1, 1), Lync.int (0, 5), 0, 4))
        names (
            refused (spelled, { a = 9 }, "a spelled map's value off its grid"),
            ROOT,
            "a spelled value off its grid"
        )
    end),

    --[[
        Text and bytes outside the count they were declared to hold, refused where they were
        written. A count is what a reader is told to walk and the bound is what a caller declared
        it would never pass, so a value over it would go out under a count the far side refuses,
        and one under it under a count that reads whatever lies past the value.
    ]]
    Harness.case ("wire.counted-refuses-its-bounds", function ()
        const LEAST = 2
        const MOST = 4

        for _, mark in { "x", "a" } do
            local under = string.rep (mark, LEAST - 1)
            local fits = string.rep (mark, LEAST)
            local over = string.rep (mark, MOST + 1)

            -- Both text forms, since an alphabet counts its characters in a run of its own.
            local codec = if mark == "x" then Lync.str (LEAST, MOST) else Lync.str.hex (LEAST, MOST)
            local of = built (codec)

            Expect.holds (of.write (SLAB, 0, fits) > 0, `{mark} at its floor wrote nothing`)
            names (refused (of, under, `{mark} under its count`), ROOT, `{mark} under`)
            names (refused (of, over, `{mark} over its count`), ROOT, `{mark} over`)
        end
    end),
}
