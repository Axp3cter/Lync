--!strict
--!optimize 2
-- The edge of a domain from the writing side: what a codec refuses, and what it says.

local Lync = require ("@src")
local Protocol = require ("@src/wire/Protocol")
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
-- How many flags the run below is allowed, which is more than the three every case hands it.
const FLAGS = 8

--[[
    A grid stopping short of the whole byte that carries it, so a byte holds readings it has no
    point for. A record of two sits on byte boundaries whichever way round it lays them down.
]]
const SHORT = 200

--[[
    The field both refusals hand a value that is no number. Its name is what separates the codec's
    own line from whatever the arithmetic underneath would have said, since a line about a bad
    argument names the call it was made to and never the field a caller wrote.
]]
const NAMED = "near"

-- A grid whose top is the whole of the byte carrying it, which is the one a mask can stand for.
const FULL = 255

const KEYS = 4

--[[
    What a bounded map may hold, and the two counts either side of it. A map counts its entries as
    it walks them, so the bound is held once a key rather than once a call, and a walk that never
    reaches the count is a walk that never reaches the bound either.
]]
const FEWEST = 2
const MOST = 3
-- A span too wide to flow into a region, which is what makes an array of one a list of them.
const WIDEST = 2 ^ 40

const TOGETHER = table.freeze ({ [0.1] = true, [0.2] = false })
const APART = table.freeze ({ [0] = true, [1] = false })

--[[
    The same pair for a key spelled as bytes rather than landing on a grid. A float of four bytes
    holds fewer numbers than a double does, so two doubles a caller keys a table by come out as one
    key, which a map of fixed-width keys finds by the two spelling the same bytes.
]]
const NEARLY = table.freeze ({ [1.0000000001] = true, [1.0000000002] = false })
const CLEARLY = table.freeze ({ [1] = true, [2] = false })

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
        A record laid down on byte boundaries, handed a value its grid has no point for. Writing
        each field where it sits skips the scratch array a window walk fills, and the guard in
        front of that array goes with it, so the one left in its place is the whole of the refusal.
    ]]
    Harness.case ("wire.a-record-on-boundaries-refuses-a-value-off-its-grid", function ()
        local of = built (Lync.struct ({
            near = Lync.int (0, SHORT),
            after = Lync.int (0, SHORT),
        }))

        Expect.equal (select (2, pcall (of.write, SLAB, 0, { near = 0, after = 0 })), 2)
        refused (of, { near = SHORT + 1, after = 0 }, "int")
        refused (of, { near = 0, after = SHORT + 1 }, "int")
        refused (of, { near = -1, after = 0 }, "int")

        --[[
            A value that is no number at all. Where a field is put down as it stands the arithmetic
            deciding whether it can be is arithmetic on whatever arrived, so what has to come back
            is the codec's refusal rather than whatever the arithmetic itself would have said.
        ]]
        local line = refused (of, { near = "no", after = 0 }, "int")
        Expect.holds (string.find (line, NAMED, 1, true) ~= nil, `it said {line}`)
    end),

    --[[
        A run of flags handed something that is no flag. A grid answering for a whole run at once
        answers with the place of the first reading it has no point for, and that place is what
        names the value the caller is refused over rather than the run it sat in.
    ]]
    Harness.case ("wire.a-run-of-flags-refuses-what-is-no-flag", function ()
        local of = built (Lync.array (Lync.bool (), 0, FLAGS))

        local ok = pcall (of.write, SLAB, 0, { true, false, true })
        Expect.holds (ok, "a run of flags was refused")

        refused (of, { true, "no", false }, "bool")
        refused (of, { true, false, 1 }, "bool")
        refused (of, { true, false, {} }, "bool")
    end),

    --[[
        A record whose fields all live in the word, handed a name it never declared. A group that
        holds a word and declares its names is written by a pair asking neither of those again, so
        the one check left in that pair is the whole of what refuses a name nobody declared.
    ]]
    Harness.case ("wire.a-record-in-one-word-refuses-a-name-nobody-declared", function ()
        local of = built (Lync.struct ({
            near = Lync.int (0, FULL),
            after = Lync.int (0, FULL),
        }))

        Expect.equal (select (2, pcall (of.write, SLAB, 0, { near = 1, after = 1 })), 2)
        refused (of, { near = 1, after = 1, spare = 1 }, "struct")
    end),

    --[[
        The same where both grids fill the bytes carrying them. A grid whose top is its byte's own
        is held to by masking the reading down to the byte rather than by comparing against the
        top, so all three of over the top, under the bottom and no number at all have to come back
        as the codec's refusal and not as whatever the mask would have made of them.
    ]]
    Harness.case ("wire.a-record-filling-its-bytes-refuses-a-value-off-its-grid", function ()
        local of = built (Lync.struct ({
            near = Lync.int (0, FULL),
            after = Lync.int (0, FULL),
        }))

        Expect.equal (select (2, pcall (of.write, SLAB, 0, { near = FULL, after = 0 })), 2)
        refused (of, { near = FULL + 1, after = 0 }, "int")
        refused (of, { near = -1, after = 0 }, "int")

        local said = refused (of, { near = "no", after = 0 }, "int")
        Expect.holds (string.find (said, NAMED, 1, true) ~= nil, `it said {said}`)
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

        -- The same, for keys spelled as bytes, which a map sorts by what they spell instead.
        local spelled = built (Lync.map (Lync.f32 (), Lync.bool (), 0, KEYS))
        names (refused (spelled, NEARLY, "two keys on one float"), ROOT, "a spelled collision")

        Expect.holds (spelled.write (SLAB, 0, CLEARLY) > 0, "two floats apart wrote nothing")
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

        -- A run asks one grid across every element, so what it names is the array it is.
        for _, one in { { 1, 9 }, { -1, 2 }, { 1, 0 / 0 } } do
            names (refused (of, one, "a run element off its grid"), ROOT, "an element off its grid")
        end
    end),

    --[[
        An element that is a record of its own, refused by the field inside it. An array names what
        it holds `element` so the path down to a field carries it, and one that did not would read
        as the array's own field, which is a declaration the caller never wrote.
    ]]
    Harness.case ("wire.run-element-is-named", function ()
        local of = built (Lync.array (Lync.struct ({ n = Lync.int (0, 3) }), 1, 4))

        Expect.holds (
            of.write (SLAB, 0, { { n = 1 } }) > 0,
            "a record element on its grid wrote nothing"
        )

        local said = refused (of, { { n = 9 } }, "a record element off its grid")
        names (said, "element", "an element by its own name")
        names (said, "n", "the field inside it")
    end),

    --[[
        An optional's payload off its grid, named by the payload rather than by the optional. What
        a caller declared is a value that may be absent, so a refusal about the value it carries
        when it is there has to say so, or it reads as a refusal about the absence itself.
    ]]
    Harness.case ("wire.optional-payload-off-its-grid", function ()
        local of = built (Lync.optional (Lync.int (0, 3)))

        Expect.holds (of.write (SLAB, 0, nil) > 0, "an optional holding nothing wrote nothing")
        Expect.holds (of.write (SLAB, 0, 2) > 0, "an optional on its grid wrote nothing")

        names (refused (of, 9, "an optional payload off its grid"), ROOT, "a payload off its grid")

        --[[
            The same inside a record, which is the form a caller writes most and the one that
            lowers through a field rather than standing on its own.
        ]]
        local held = built (Lync.struct ({ maybe = Lync.optional (Lync.int (0, 3)) }))
        Expect.holds (held.write (SLAB, 0, { maybe = 2 }) > 0, "an optional field wrote nothing")

        local said = refused (held, { maybe = 9 }, "an optional field off its grid")
        names (said, "maybe", "a payload by the field holding it")
        names (said, "inner", "a payload by its own name")
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

    --[[
        An array whose element is too wide to pack, which is a list of aligned elements rather than
        a run. A run carries one width across every element and costs the bits that width comes to,
        so an element the region could not take would come out a byte short of what a reader of the
        same schema walks, and every element after the first would be read off the wrong bit.
    ]]
    Harness.case ("wire.array-of-a-wide-element", function ()
        const HELD = 2

        --[[
            What one of them spends. A span of two to the fortieth wants forty one bits, which is
            six whole bytes, where a run of two would have spent the eighty two bits between them.
        ]]
        const EACH = 6

        local of = built (Lync.array (Lync.int (0, WIDEST), HELD, HELD))

        Expect.equal (of.maxBytes, HELD * EACH)
        Expect.equal (of.write (SLAB, 0, { 1, 2 }), HELD * EACH)
    end),
    --[[
        The four things a value nobody declared is held to, since its declaration says only how
        much room it may take. Every one of them is the only bound left once the shape is gone:
        what it may hold, how deep it may nest, how much room it fills, and that the room is what
        the frame keeps rather than what the writer discovers.
    ]]
    Harness.case ("wire.unknown-holds-what-it-can", function ()
        --[[
            Sixteen bytes takes a tag, a count and fourteen characters, so fifteen is the first
            string that cannot fit. The bound is exact rather than approached, which is the whole
            claim: nothing is written past what the declaration asked for.
        ]]
        const ROOM = 16
        const FITS = 14

        local of = built (Lync.unknown (ROOM))

        Expect.equal (of.write (SLAB, 0, string.rep ("x", FITS)), ROOM)
        names (refused (of, string.rep ("x", FITS + 1), "a string over the room"), ROOT, "over")

        -- A value the schema has no tag for, which is every Luau type a frame cannot carry.
        names (refused (of, print, "a function"), ROOT, "a function")

        --[[
            Nesting past what a reader walks, which a sender rather than a schema chooses. Asked in
            room nothing could fill, because a nest deep enough is also a nest wide enough and the
            two refusals would otherwise stand in for one another.
        ]]
        local wide = built (Lync.unknown (Protocol.SECTION_BYTES))
        local deep: any = {}
        local walk = deep
        for _ = 1, Protocol.UNKNOWN_DEPTH + 1 do
            local under = {}
            walk[1] = under
            walk = under
        end
        names (refused (wide, deep, "a value nested past the depth"), ROOT, "nested")
    end),

    --[[
        That the frame keeps the room the writer needs to discover a varint's width. A varint says
        how wide it is by being written, so the bytes it takes past the bound land in slack the
        frame reserved and the refusal drops the frame. Without the slack the write is what runs
        past the buffer, and a schema cannot say afterwards that it should not have.
    ]]
    Harness.case ("wire.unknown-keeps-room-for-the-widest", function ()
        --[[
            Room a whole starts inside and ends past. A tag and the six groups two to the fortieth
            folds into come to seven, so four bytes is room the write begins in and cannot finish
            in: the refusal has to come from what the write discovered, since nothing before it
            had anything to go on.
        ]]
        const ROOM = 4

        local of = built (Lync.unknown (ROOM))

        Expect.equal (of.maxBytes, ROOM + Protocol.UNKNOWN_SLACK)
        names (refused (of, WIDEST, "a whole wider than the room"), ROOT, "wide")
    end),
}
