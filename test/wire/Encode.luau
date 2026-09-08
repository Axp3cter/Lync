--!strict
--!optimize 2
-- The edge of a domain from the writing side: what a codec refuses, and what it says.

local Codecs = require("@src/codec")
local Shape = require("@src/shape")

local Expect = require("@test/harness/Expect")
local Generate = require("@test/harness/Generate")
local Harness = require("@test/harness")
local Rng = require("@test/harness/Rng")

-- Where every codec here is built. A capitalised word shaped like a definition name cannot be
-- spelled by accident inside an ordinary sentence, where two lowercase letters can.
local ROOT = "Origin"

-- Where every encode here is written, wide enough that nothing but the codec is left to raise.
local ROOM = 2 ^ 18
local SLAB = buffer.create(ROOM)

local DEPTH = Generate.DEEP

-- The kinds whose value one step outside is a value of the same Luau type, merely out of the
-- domain, which is what reaches a schema's own rejection with a path to name.
local RANGED =
    table.freeze({ "int", "quant", "vlq", "vli", "str", "str.alphabet", "buffer", "enum" })

-- The kinds that round a number onto a grid, which have to refuse what is no number before they
-- compute an index, and the two that carry every bit pattern a double takes.
local GRIDDED = table.freeze({
    { of = "int", codec = Codecs.int(-10, 10) },
    { of = "quant", codec = Codecs.quant(-10, 10, 0.5) },
    { of = "angle", codec = Codecs.angle(1) },
    { of = "vlq", codec = Codecs.vlq() },
    { of = "vli", codec = Codecs.vli() },
})
local CARRIES =
    table.freeze({ { of = "f32", codec = Codecs.f32() }, { of = "f64", codec = Codecs.f64() } })
local UNREAL = table.freeze({ 0 / 0, math.huge, -math.huge })

-- A key codec coarser than the keys a caller can hand it, and keys spelled as bytes that two
-- doubles collapse onto.
local COARSE = Codecs.quant(0, 1, 0.5)
local TOGETHER = table.freeze({ [0.1] = true, [0.2] = false })
local APART = table.freeze({ [0] = true, [1] = false })
local NEARLY = table.freeze({ [1.0000000001] = true, [1.0000000002] = false })
local CLEARLY = table.freeze({ [1] = true, [2] = false })

local FLAGS = 8
local SHORT = 200
local FULL = 255
local NAMED = "near"
local WIDENED = 12
local KEYS = 4
local FEWEST = 2
local MOST = 3
local WIDEST = 2 ^ 40

local function built(codec: any): any
    local of = Shape.build(codec, ROOT)
    Expect.holds(of.maxBytes * 2 <= ROOM, `a codec of {of.maxBytes} bytes outgrows the slab`)
    return of
end

-- The line a refused encode raised.
local function refused(of: any, value: any, what: string): string
    local ok, caught = pcall(of.write, SLAB, 0, value)
    if not ok then return tostring(caught) end
    Expect.holds(false, `{what} encoded to {caught} bytes`)
    return ""
end

-- Whether the value one step outside this shape reaches a codec that writes nothing at all.
local function totalled(shape: Generate.Shape): boolean
    if shape.at == "optional" then return totalled(shape.of[1]) end
    return shape.at == Generate.TOTAL
end

local function names(line: string, part: string, what: string)
    Expect.holds(
        string.find(line, part, 1, true) ~= nil,
        `{what} threw {line}, which does not name {part}`
    )
end

-- A codec wrapped in one named field of a struct with a sibling either side, so a line naming the
-- field that failed cannot be mistaken for one naming the only field there is.
local function inside(codec: any, value: any, level: number): (any, any)
    local before, at, after = `a{level}`, `f{level}`, `z{level}`
    local fields = { [before] = Codecs.bool(), [at] = codec, [after] = Codecs.bool() }
    return Codecs.struct(fields), { [before] = true, [at] = value, [after] = false }
end

return {
    -- Every kind, and the one value a step outside it: a value inside encodes and the same codec's
    -- value outside does not.
    Harness.property("wire.refuses", "encode", function(rng: Rng.Rng)
        local shape = Generate.shape(rng, DEPTH)
        local of = built(Generate.codec(shape))
        local ok, at = pcall(of.write, SLAB, 0, Generate.value(shape, rng))
        Expect.holds(ok, `{shape.at} refused a value of its own domain: {tostring(at)}`)
        if totalled(shape) then return end
        refused(of, Generate.outside(shape, rng), shape.at)
    end),

    -- Records laid on byte boundaries and records filling their bytes, handed values off their
    -- grids and one that is no number, with the codec's own line naming the field.
    Harness.case("wire.records-refuse-values-off-their-grids", function()
        for _, top in { SHORT, FULL } do
            local of =
                built(Codecs.struct({ near = Codecs.int(0, top), after = Codecs.int(0, top) }))
            Expect.equal(select(2, pcall(of.write, SLAB, 0, { near = top, after = 0 })), 2)
            refused(of, { near = top + 1, after = 0 }, "int")
            refused(of, { near = 0, after = top + 1 }, "int")
            refused(of, { near = -1, after = 0 }, "int")
            names(
                refused(of, { near = "no", after = 0 }, "int"),
                NAMED,
                "a value that is no number"
            )
        end
    end),

    -- A run of flags handed something that is no flag, and a run element off its grid, each
    -- refused where it was written and naming the array it sat in.
    Harness.case("wire.runs-refuse-what-is-off-their-grid", function()
        local flags = built(Codecs.array(Codecs.bool(), 0, FLAGS))
        Expect.holds(
            pcall(flags.write, SLAB, 0, { true, false, true }),
            "a run of flags was refused"
        )
        refused(flags, { true, "no", false }, "bool")
        refused(flags, { true, false, 1 }, "bool")
        refused(flags, { true, false, {} }, "bool")

        local of = built(Codecs.array(Codecs.int(0, 3), 1, 4))
        Expect.holds(of.write(SLAB, 0, { 1, 2, 3 }) > 0, "a run on its grid wrote nothing")
        for _, one in { { 1, 9 }, { -1, 2 }, { 1, 0 / 0 } } do
            names(refused(of, one, "a run element off its grid"), ROOT, "an element off its grid")
        end
    end),

    -- A record whose fields all live in the word, handed a name it never declared, whether beside
    -- its own names or in place of one, and the refusal names the stranger.
    Harness.case("wire.a-record-refuses-a-name-nobody-declared", function()
        local of = built(Codecs.struct({ near = Codecs.int(0, FULL), after = Codecs.int(0, FULL) }))
        Expect.equal(select(2, pcall(of.write, SLAB, 0, { near = 1, after = 1 })), 2)
        refused(of, { near = 1, after = 1, spare = 1 }, "struct")
        names(
            refused(of, { near = 1, spare = 1 }, "struct"),
            "spare",
            "the one that does not belong"
        )
    end),

    -- A value out of range at a named node, at every depth a draw reaches, names the root and
    -- every field on the way down.
    Harness.property("wire.names-path", "encode", function(rng: Rng.Rng)
        local shape = Generate.among(rng, RANGED, 0)
        local codec = Generate.codec(shape)
        local value = Generate.outside(shape, rng)
        local levels = rng:int(0, DEPTH)
        for level = levels, 1, -1 do
            codec, value = inside(codec, value, level)
        end
        local line = refused(built(codec), value, shape.at)
        names(line, ROOT, shape.at)
        for level = 1, levels do
            names(line, `f{level}`, shape.at)
        end
    end),

    -- A value off its grid in a record wider than one window where no grid runs from nothing,
    -- with the line naming the piece.
    Harness.case("wire.a-wide-turned-record-names-its-piece", function()
        local fields, value = {}, {}
        for at = 1, WIDENED do
            fields[`turn{at}`] = Codecs.int(-1, 1)
            value[`turn{at}`] = 0
        end
        value.turn1 = 2
        names(refused(built(Codecs.struct(fields)), value, "int at turn1"), "turn1", "int at turn1")
    end),

    -- The three parts of a line held apart: where, what was expected, and what arrived.
    Harness.case("wire.names-fault", function()
        local function faulted(span: number, at: string, value: number): string
            local codec = Codecs.struct({ [at] = Codecs.int(0, span), keep = Codecs.bool() })
            return refused(built(codec), { [at] = value, keep = true }, `int at {at}`)
        end
        local base = faulted(10, "spot", 11)
        Expect.holds(faulted(10, "spot", 12) ~= base, `two values read alike: {base}`)
        Expect.holds(faulted(10, "mark", 11) ~= base, `two paths read alike: {base}`)
        Expect.holds(faulted(5, "spot", 11) ~= base, `two expectations read alike: {base}`)
    end),

    -- The numbers on no grid. NaN gets through a guard written the obvious way round, since it
    -- compares false against both bounds. An IEEE span carries them all.
    Harness.case("wire.not-a-number", function()
        for _, entry in GRIDDED do
            local of = built(entry.codec)
            for _, value in UNREAL do
                refused(of, value, `{entry.of} given {value}`)
            end
        end
        for _, entry in CARRIES do
            Expect.holds(pcall(built(entry.codec).write, SLAB, 0, 0 / 0), `{entry.of} refused NaN`)
        end
    end),

    -- Two keys one schema cannot tell apart, on a grid or spelled as bytes, refused on the machine
    -- that wrote them.
    Harness.case("wire.keys-apart", function()
        local of = built(Codecs.map(COARSE, Codecs.bool(), 0, KEYS))
        names(refused(of, TOGETHER, "two keys on one point"), ROOT, "a key collision")
        Expect.holds(of.write(SLAB, 0, APART) > 0, "two keys on two points wrote nothing")

        local spelled = built(Codecs.map(Codecs.f32(), Codecs.bool(), 0, KEYS))
        names(refused(spelled, NEARLY, "two keys on one float"), ROOT, "a spelled collision")
        Expect.holds(spelled.write(SLAB, 0, CLEARLY) > 0, "two floats apart wrote nothing")
    end),

    -- A map holding more than its bound and one holding less, in both key forms, since each
    -- counts its own entries.
    Harness.case("wire.map-bounds", function()
        local forms = {
            { of = "gridded", codec = Codecs.map(Codecs.int(0, 15), Codecs.bool(), FEWEST, MOST) },
            { of = "spelled", codec = Codecs.map(Codecs.str(1, 2), Codecs.bool(), FEWEST, MOST) },
        }
        for _, form in forms do
            local of = built(form.codec)
            local function holding(count: number): any
                local made: any = {}
                for index = 1, count do
                    made[if form.of == "gridded" then index else tostring(index)] = true
                end
                return made
            end
            refused(of, holding(FEWEST - 1), `a {form.of} map under its bound of {FEWEST}`)
            refused(of, holding(MOST + 1), `a {form.of} map over its bound of {MOST}`)
            Expect.holds(of.write(SLAB, 0, holding(FEWEST)) > 0, `a {form.of} map wrote nothing`)
        end
    end),

    -- An element that is a record is refused by the field inside it, named through `element`,
    -- and an optional's payload is named through the field and `inner`.
    Harness.case("wire.nested-names", function()
        local of = built(Codecs.array(Codecs.struct({ n = Codecs.int(0, 3) }), 1, 4))
        Expect.holds(of.write(SLAB, 0, { { n = 1 } }) > 0, "a record element wrote nothing")
        local said = refused(of, { { n = 9 } }, "a record element off its grid")
        names(said, "element", "an element by its own name")
        names(said, "n", "the field inside it")

        local bare = built(Codecs.optional(Codecs.int(0, 3)))
        Expect.holds(bare.write(SLAB, 0, nil) > 0, "an optional holding nothing wrote nothing")
        Expect.holds(bare.write(SLAB, 0, 2) > 0, "an optional on its grid wrote nothing")
        names(refused(bare, 9, "an optional payload off its grid"), ROOT, "a payload off its grid")

        local held = built(Codecs.struct({ maybe = Codecs.optional(Codecs.int(0, 3)) }))
        Expect.holds(held.write(SLAB, 0, { maybe = 2 }) > 0, "an optional field wrote nothing")
        local inner = refused(held, { maybe = 9 }, "an optional field off its grid")
        names(inner, "maybe", "a payload by the field holding it")
        names(inner, "inner", "a payload by its own name")
    end),

    -- The values a composite has nowhere to put: a record of no table, a tag naming no arm, and a
    -- map key or value off its grid in either key form.
    Harness.case("wire.composites-refuse-what-they-cannot-hold", function()
        local nested = built(Codecs.struct({ inner = Codecs.struct({ n = Codecs.int(0, 5) }) }))
        names(
            refused(nested, { inner = 7 }, "a record given no table"),
            ROOT,
            "a record of no table"
        )

        local picked = built(Codecs.tagged("tag", {
            a = Codecs.struct({ x = Codecs.bool() }),
            b = Codecs.struct({ y = Codecs.bool() }),
        }))
        names(
            refused(picked, { tag = "c", z = true }, "a tag naming no arm"),
            ROOT,
            "a tag of no arm"
        )

        local gridded = built(Codecs.map(Codecs.int(0, 5), Codecs.int(0, 5), 0, 4))
        names(refused(gridded, { [9] = 1 }, "a map key off its grid"), ROOT, "a key off its grid")
        names(
            refused(gridded, { [1] = 9 }, "a map value off its grid"),
            ROOT,
            "a value off its grid"
        )
        local spelled = built(Codecs.map(Codecs.str(1, 1), Codecs.int(0, 5), 0, 4))
        names(
            refused(spelled, { a = 9 }, "a spelled map's value off its grid"),
            ROOT,
            "a spelled value"
        )

        -- A value of no type the node can measure, which is what a record with a field left out
        -- hands every counted kind: refused on the codec's line, never a raise from a length.
        for _, one in
            {
                { of = Codecs.str(0, 4), what = "a string given nothing" },
                { of = Codecs.str.alphabet("ab", 0, 4), what = "an alphabet given nothing" },
                { of = Codecs.buffer(0, 4), what = "a buffer given nothing" },
                { of = Codecs.array(Codecs.int(0, 5), 0, 4), what = "a run given nothing" },
                { of = Codecs.array(Codecs.str(0, 2), 0, 4), what = "a list given nothing" },
                {
                    of = Codecs.map(Codecs.int(0, 5), Codecs.int(0, 5), 0, 4),
                    what = "a gridded map given nothing",
                },
                {
                    of = Codecs.map(Codecs.str(1, 1), Codecs.int(0, 5), 0, 4),
                    what = "a spelled map given nothing",
                },
            }
        do
            names(refused(built(one.of), nil, one.what), ROOT, one.what)
            names(refused(built(one.of), 7, `{one.what}, given a number`), ROOT, one.what)
        end
    end),

    -- Text and bytes outside the count they were declared to hold, in both text forms.
    Harness.case("wire.counted-refuses-its-bounds", function()
        local LEAST, TOP = 2, 4
        for _, form in
            {
                { mark = "x", codec = Codecs.str(LEAST, TOP) },
                { mark = "a", codec = Codecs.str.alphabet("abc", LEAST, TOP) },
            }
        do
            local of = built(form.codec)
            local mark = form.mark
            Expect.holds(
                of.write(SLAB, 0, string.rep(mark, LEAST)) > 0,
                `{mark} at its floor wrote nothing`
            )
            names(
                refused(of, string.rep(mark, LEAST - 1), `{mark} under its count`),
                ROOT,
                `{mark} under`
            )
            names(
                refused(of, string.rep(mark, TOP + 1), `{mark} over its count`),
                ROOT,
                `{mark} over`
            )
        end
    end),

    -- An array whose element is too wide to pack is a list of aligned elements rather than a run:
    -- forty one bits is six whole bytes each, not eighty two bits between two.
    Harness.case("wire.array-of-a-wide-element", function()
        local of = built(Codecs.array(Codecs.int(0, WIDEST), 2, 2))
        Expect.equal(of.maxBytes, 12)
        Expect.equal(of.write(SLAB, 0, { 1, 2 }), 12)
    end),
}
