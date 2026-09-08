--!strict
--!optimize 2
-- The second law: bytes nobody wrote come back as a value or a refusal, and never as anything else.

local Catalog = require("@src/kernel/Catalog")
local Codecs = require("@src/codec")
local Shape = require("@src/shape")

local Schemas = require("@fixtures/Schemas")

local Expect = require("@test/harness/Expect")
local Generate = require("@test/harness/Generate")
local Harness = require("@test/harness")
local Rng = require("@test/harness/Rng")
local Turns = require("@test/harness/Turns")

local DEPTH = Generate.DEEP

-- What a byte is written over with where a check corrupts one on purpose: the two ends, and two
-- that alternate, which sets a pad bit without setting every bit.
local HOSTILE = table.freeze({ 0x00, 0x55, 0xAA, 0xFF })

-- How many bytes are laid after a frame to give a believed count something to eat.
local SPARE = 512
local BYTES = 256

-- Grids stopping short of the byte or pair that carries them, and the byte every reading could be.
local SHORT = 200
local SHORT_PAIR = 60000
local WHOLE_BYTE = 255

-- The two frames a reader is handed that no encoder wrote, and how many times over a frame's
-- own length the longer runs go.
local ADVERSARIES = table.freeze({ { of = "zeros", byte = 0x00 }, { of = "ones", byte = 0xFF } })
local OVERLONG = table.freeze({ 2, 4 })

-- The top of a grid three bits wide, and one nine bits wide that no whole number of bytes fills.
local CUT_TOP = 4
local CUT_WIDE = 300
local ONE_BIT = 1

-- A map of exactly four pairs over exactly four keys, which is the map with one legal value.
local FOUR = 4
local KEYED = table.freeze({ "n1", "n2", "n3", "n4" })
local PAIRED = 2
local LOW = 1
local HIGH = 2
local BYTE_WIDE = 255

-- Not an instance, which is what a sender is free to leave where one is looked up.
local PRETEND = table.freeze({ pretending = true })
local WANTED = "Folder"
local STAND_IN = "Part"

local TAGS = table.freeze({
    a = Codecs.struct({ x = Codecs.bool() }),
    b = Codecs.struct({ y = Codecs.bool() }),
    c = Codecs.struct({ z = Codecs.bool() }),
})

-- One codec of every kind narrow enough to enumerate, each laying out inside a single byte.
local NARROW = table.freeze({
    { of = "bool", codec = Codecs.bool() },
    { of = "int", codec = Codecs.int(0, 4) },
    { of = "quant", codec = Codecs.quant(0, 1, 0.25) },
    { of = "angle", codec = Codecs.angle(72) },
    { of = "str", codec = Codecs.str(1, 1) },
    { of = "str.alphabet", codec = Codecs.str.alphabet("abc", 1, 1) },
    { of = "buffer", codec = Codecs.buffer(1, 1) },
    { of = "enum", codec = Codecs.enum({ "a", "b", "c" }) },
    { of = "bitfield", codec = Codecs.bitfield({ "a", "b", "c" }) },
    { of = "vec3.unit", codec = Codecs.vec3.unit(90) },
    { of = "rotation.none", codec = Codecs.rotation.none() },
    { of = "rotation.quat", codec = Codecs.rotation.quat(90) },
    { of = "optional", codec = Codecs.optional(Codecs.bool()) },
    { of = "array", codec = Codecs.array(Codecs.bool(), 0, 2) },
    { of = "map", codec = Codecs.map(Codecs.int(0, 1), Codecs.bool(), 0, 2) },
    { of = "struct", codec = Codecs.struct({ a = Codecs.bool(), b = Codecs.int(0, 4) }) },
    { of = "tagged", codec = Codecs.tagged("tag", TAGS) },
    { of = "vec2", codec = Codecs.vec2(Codecs.int(0, 4)) },
    { of = "vec3", codec = Codecs.vec3(Codecs.int(0, 1)) },
    { of = "cframe", codec = Codecs.cframe(Codecs.vec3(Codecs.int(0, 1)), Codecs.rotation.none()) },
})

-- The kinds no single byte holds, which is why a sweep over one byte cannot reach them.
local WIDE = table.freeze({ "f32", "f64", "color3", "color3.rgb565", "vlq", "vli" })

-- What a read of hostile bytes answered: a refusal, which is the contract, or a value.
local function decoded(of: any, text: string): (boolean, any, number)
    local ok, at, value = pcall(of.read, Turns.held(text), 0, Turns.CTX)
    if not ok then return false, nil, 0 end
    return true, value, at
end

-- Whether a value a hostile frame produced is one the schema would have produced itself, which a
-- re-encode is the test of.
local function legal(of: any, value: any): string?
    local out = buffer.create(of.maxBytes)
    local ok, at = pcall(of.write, out, 0, value)
    if not ok then return "the value it answered does not encode" end
    if at > of.maxBytes then return `the value it answered encodes to {at} bytes` end
    return nil
end

-- One hostile frame judged: refused, or answered with a value the schema owns and a cursor
-- inside the bytes it was given.
local function survives(of: any, text: string, what: string)
    local answered, value, at = decoded(of, text)
    if not answered then return end
    Expect.holds(at <= #text, `{what}: a read of {at} bytes out of {#text}`)
    local wrong = legal(of, value)
    Expect.holds(wrong == nil, `{what}: {wrong}`)
end

local function counted(path: string, held: number, shape: Generate.Shape)
    Expect.holds(
        held >= shape.min and held <= shape.max,
        `{path} came back holding {held}, and its {shape.at} takes {shape.min} to {shape.max}`
    )
end

-- Every collection in a decoded value, held to its own bound.
local function within(shape: Generate.Shape, value: any, path: string)
    local at = shape.at
    if at == "optional" then
        if value ~= nil then within(shape.of[1], value, path) end
    elseif at == "struct" then
        for index, name in shape.names do
            within(shape.of[index], value[name], `{path}.{name}`)
        end
    elseif at == "tagged" then
        local named = tostring(value[shape.text])
        local index = table.find(shape.names, named)
        if index ~= nil then within(shape.of[index], value, `{path}.{named}`) end
    elseif at == "array" then
        counted(path, #value, shape)
        for index, one in value do
            within(shape.of[1], one, `{path}[{index}]`)
        end
    elseif at == "map" then
        local held = 0
        for key, one in value do
            held += 1
            within(shape.of[2], one, `{path}[{tostring(key)}]`)
        end
        counted(path, held, shape)
    elseif at == "str" or at == "str.alphabet" then
        counted(path, #value, shape)
    elseif at == "buffer" then
        counted(path, buffer.len(value), shape)
    end
end

-- Room whose bytes climb a byte at a time and around again, so keys taken out of it arrive in
-- the order a map requires.
local function climbing(): string
    local out = table.create(SPARE)
    for at = 1, SPARE do
        out[at] = string.char((at - 1) % BYTES)
    end
    return table.concat(out)
end

-- Every single-bit flip of a text, and the codes the reads of them were refused under.
local function flipped(of: any, text: string): { [string]: boolean }
    local seen: { [string]: boolean } = {}
    for at = 1, #text do
        local byte = string.byte(text, at)
        for bit = 0, 7 do
            local moved = string.char(bit32.bxor(byte, bit32.lshift(1, bit)))
            local hostile = `{string.sub(text, 1, at - 1)}{moved}{string.sub(text, at + 1)}`
            local ok, caught = pcall(of.read, Turns.held(hostile), 0, Turns.CTX)
            if not ok and type(caught) == "table" then seen[caught.code] = true end
        end
    end
    return seen
end

local function refusedAs(of: any, text: string): string?
    local ok, caught = pcall(of.read, Turns.held(text), 0, Turns.CTX)
    if ok then return nil end
    return if type(caught) == "table" then caught.code else "raise"
end

-- One fixture case as a built shape and the bytes it wrote, which the corpus sweeps damage.
type Frame = { read of: string, read built: any, read bytes: string }

-- Every case of every fixture, so a hostile sweep runs over frames a real schema wrote.
local function frames(): { Frame }
    local out: { Frame } = {}
    for _, fixture in Schemas.all do
        local built = Shape.build(fixture.codec, fixture.name)
        for _, one in fixture.cases do
            table.insert(out, {
                of = `{fixture.name}.{one.name}`,
                built = built,
                bytes = Turns.text(built, one.value),
            })
        end
    end
    return out
end

return {
    -- Every schema the vocabulary can build, over bytes damaged every way a frame is damaged.
    Harness.property("total.no-crash", "decode", function(rng: Rng.Rng)
        local shape = Generate.shape(rng, DEPTH)
        local of = Turns.built(Generate.codec(shape))
        local bytes = Turns.text(of, Generate.value(shape, rng))
        local other = Turns.text(of, Generate.value(shape, rng))
        local damaged, way = Generate.corrupted(rng, bytes, other)
        survives(of, damaged, `{shape.at} {way}`)
    end),

    -- A count read and believed is a table sized by whoever wrote the bytes, so every collection a
    -- hostile frame produces is held to its own bound.
    Harness.property("total.bounded-alloc", "decode", function(rng: Rng.Rng)
        local shape = Generate.shape(rng, DEPTH)
        local of = Turns.built(Generate.codec(shape))
        local bytes = Turns.text(of, Generate.value(shape, rng))
        local other = Turns.text(of, Generate.value(shape, rng))
        local damaged = Generate.corrupted(rng, bytes, other)
        local flat = string.rep(string.char(rng:pick(HOSTILE)), SPARE)
        local noise = buffer.tostring(rng:bytes(SPARE))
        for _, text in { damaged, damaged .. flat, damaged .. noise, damaged .. climbing() } do
            local answered, value = decoded(of, text)
            if answered then within(shape, value, shape.at) end
        end
    end),

    -- A map with one legal value comes back holding its count or not at all, and a map whose keys
    -- descend is a frame this schema could not have written.
    Harness.case("total.map-count-and-order-hold", function()
        local of = Turns.built(Codecs.map(Codecs.enum(KEYED), Codecs.vlq(), FOUR, FOUR))
        local value = {}
        for index, name in KEYED do
            value[name] = index
        end
        local bytes = Turns.text(of, value)
        for at = 1, #bytes do
            for _, byte in HOSTILE do
                local text = string.sub(bytes, 1, at - 1)
                    .. string.char(byte)
                    .. string.sub(bytes, at + 1)
                local answered, got = decoded(of, text)
                if not answered then continue end
                local count = 0
                for _ in got do
                    count += 1
                end
                Expect.equal(count, FOUR)
            end
        end

        local one = Codecs.int(0, BYTE_WIDE)
        local pairs = Turns.built(Codecs.map(one, one, PAIRED, PAIRED))
        local written = Turns.text(pairs, { [LOW] = LOW, [HIGH] = HIGH })
        Expect.equal(#written, PAIRED * PAIRED)
        Expect.holds(decoded(pairs, written), "the map this codec wrote was refused")
        local reversed = string.sub(written, LOW + 1, LOW + 1)
            .. string.sub(written, LOW, LOW)
            .. string.sub(written, PAIRED + 1)
        Expect.equal(decoded(pairs, reversed), false)
    end),

    -- A lone field cut across two bytes, a one-window word beside a flag, and a word whose last
    -- field is cut, each swept with hostile bytes.
    Harness.case("total.words", function()
        local lone = Turns.built(Codecs.int(0, CUT_WIDE))
        Expect.holds(
            decoded(lone, Turns.text(lone, CUT_WIDE)),
            "the reading this codec wrote was refused"
        )
        for first = 0, WHOLE_BYTE do
            for second = 0, ONE_BIT do
                survives(lone, string.char(first, second), `a lone field at {first} {second}`)
            end
        end

        local one = Turns.built(Codecs.struct({ a = Codecs.int(0, CUT_TOP), b = Codecs.bool() }))
        local bytes = Turns.text(one, { a = 0, b = false })
        Expect.holds(decoded(one, bytes), "the word this codec wrote was refused")
        for at = 1, #bytes do
            local before, after = string.sub(bytes, 1, at - 1), string.sub(bytes, at + 1)
            for byte = 0, WHOLE_BYTE do
                survives(one, before .. string.char(byte) .. after, `byte {at} at {byte}`)
            end
        end

        local narrow = Codecs.int(0, CUT_TOP)
        local cut = Turns.built(Codecs.struct({ a = narrow, b = narrow, c = narrow }))
        local text = Turns.text(cut, { a = 0, b = 0, c = 0 })
        Expect.holds(decoded(cut, text), "the word this codec wrote was refused")
        for at = 1, #text do
            local before, after = string.sub(text, 1, at - 1), string.sub(text, at + 1)
            for _, byte in HOSTILE do
                survives(cut, before .. string.char(byte) .. after, `byte {at} at {byte}`)
            end
        end
    end),

    -- Every frame of a byte or less against a codec of every kind: whether anything a reader can
    -- be handed comes back as a value its own writer would refuse.
    Harness.case("total.enumerated", function()
        local named: { [string]: boolean } = {}
        for _, entry in NARROW do
            Expect.holds(named[entry.of] == nil, `{entry.of} is swept twice`)
            named[entry.of] = true
        end
        for _, at in WIDE do
            Expect.holds(named[at] == nil, `{at} is both swept and named wide`)
            named[at] = true
        end
        for _, at in Generate.KINDS do
            Expect.holds(named[at] ~= nil, `{at} is neither swept nor named wide`)
            named[at] = nil
        end
        Expect.equal(next(named), nil)

        for _, entry in NARROW do
            local of = Turns.built(entry.codec)
            survives(of, "", `{entry.of} empty`)
            for byte = 0, 255 do
                survives(of, string.char(byte), `{entry.of} {byte}`)
            end
        end
    end),

    -- The sender fills the reference array, so a slot may hold anything, another class, or a
    -- varint that never ends, and each is refused.
    Harness.case("total.sidecar-holds", function()
        for _, of in { Turns.built(Codecs.inst()), Turns.built(Codecs.inst("Player")) } do
            local out = buffer.create(math.max(of.maxBytes, 1))
            of.write(out, 0, PRETEND)
            Expect.equal(typeof(of.sidecar.refs[1]), "table")
            Expect.holds(not pcall(of.read, out, 0, Turns.CTX), "a reference answered a table")
        end

        local of = Turns.built(Codecs.inst(WANTED))
        local b = buffer.create(math.max(of.maxBytes, 1))
        of.write(b, 0, Instance.new(WANTED))
        local _, one = of.read(b, 0, Turns.CTX)
        Expect.holds(one ~= nil, `a reference of a {WANTED} came back as nothing`)
        of.sidecar.refs[1] = Instance.new(STAND_IN)
        local ok, why = pcall(of.read, b, 0, Turns.CTX)
        Expect.holds(not ok, `a reference of a {STAND_IN} was taken where a {WANTED} was declared`)
        Expect.equal((why :: any).code, Catalog.SIDECAR)

        local endless = buffer.create(16)
        buffer.fill(endless, 0, 0xFF)
        Expect.equal(
            refusedAs(Turns.built(Codecs.inst()), buffer.tostring(endless)),
            Catalog.VARINT
        )
    end),

    -- A pad that is not zero spells one value two ways, and every form that leaves one is refused.
    Harness.case("total.pad-is-refused", function()
        local forms = {
            {
                of = "a run",
                codec = Codecs.array(Codecs.int(0, 3), 3, 3),
                value = { 1, 2, 3 } :: any,
            },
            {
                of = "an alphabet",
                codec = Codecs.str.alphabet("0123456789abcdef", 3, 3),
                value = "abc",
            },
            { of = "a wide field", codec = Codecs.int(0, 2 ^ 40), value = 12345 },
            {
                of = "a map's keys",
                codec = Codecs.map(Codecs.int(0, 5), Codecs.int(0, 255), 3, 3),
                value = { [1] = 1, [3] = 2, [5] = 3 },
            },
            {
                of = "a map's values",
                codec = Codecs.map(Codecs.int(0, 255), Codecs.int(0, 5), 3, 3),
                value = { [1] = 1, [3] = 2, [5] = 3 },
            },
            {
                of = "a spelled map",
                codec = Codecs.map(Codecs.str(1, 1), Codecs.int(0, 5), 3, 3),
                value = { a = 1, b = 2, c = 3 },
            },
        }
        for _, form in forms do
            local of = Turns.built(form.codec)
            local seen = flipped(of, Turns.text(of, form.value))
            Expect.holds(seen[Catalog.PAD], `no bit of {form.of} reached the pad it left over`)
        end
    end),

    -- Bits under a field's width that name no point on its grid are a tag, told apart from a pad,
    -- for a wide field and for the elements of a run in three forms.
    Harness.case("total.past-the-grid", function()
        local wide = Turns.built(Codecs.int(0, 2 ^ 40))
        Expect.holds(
            flipped(wide, Turns.text(wide, 12345))[Catalog.TAG],
            "a wide field named no tag"
        )

        local forms = {
            {
                of = "a run",
                codec = Codecs.array(Codecs.int(0, 2), 3, 3),
                value = { 1, 2, 1 } :: any,
            },
            { of = "an alphabet", codec = Codecs.str.alphabet("abc", 3, 3), value = "abc" },
            {
                of = "a shifted run",
                codec = Codecs.array(Codecs.int(1, 3), 3, 3),
                value = { 1, 2, 3 },
            },
        }
        for _, form in forms do
            local of = Turns.built(form.codec)
            local seen = flipped(of, Turns.text(of, form.value))
            Expect.holds(seen[Catalog.TAG], `no bit of {form.of} named an element off its grid`)
        end
    end),

    -- The three ways a map can be a frame no encoder wrote, told apart by their codes, and a tag
    -- naming no variant.
    Harness.case("total.map-refusals-are-told-apart", function()
        local WHOLE = Codecs.int(0, 255)
        local PART = Codecs.int(0, 5)
        local forms = {
            {
                of = "a gridded map",
                codec = Codecs.map(PART, PART, 0, 3),
                value = { [1] = 1, [3] = 2, [5] = 3 } :: any,
                wants = { Catalog.COUNT, Catalog.TAG, Catalog.MAP_ORDER },
            },
            {
                of = "a gridded map's keys",
                codec = Codecs.map(PART, WHOLE, 0, 3),
                value = { [1] = 1, [3] = 2, [5] = 3 },
                wants = { Catalog.TAG },
            },
            {
                of = "a gridded map's values",
                codec = Codecs.map(WHOLE, PART, 0, 3),
                value = { [1] = 1, [3] = 2, [5] = 3 },
                wants = { Catalog.TAG },
            },
            {
                of = "a spelled map",
                codec = Codecs.map(Codecs.str(1, 1), PART, 0, 3),
                value = { a = 1, b = 2, c = 3 },
                wants = { Catalog.COUNT, Catalog.TAG, Catalog.MAP_ORDER },
            },
            {
                of = "a tagged union",
                codec = Codecs.tagged("tag", TAGS),
                value = { tag = "a", x = true },
                wants = { Catalog.TAG },
            },
        }
        for _, form in forms do
            local of = Turns.built(form.codec)
            local seen = flipped(of, Turns.text(of, form.value))
            for _, code in form.wants do
                Expect.holds(seen[code], `{form.of} was never refused as {code}`)
            end
        end
    end),

    -- Two keys a frame spells apart and a reader answers as one: a float of one and a signed zero
    -- still climb by their bytes, and both read back as the one zero.
    Harness.case("total.map-keys-that-read-as-one", function()
        local of = Turns.built(Codecs.map(Codecs.f32(), Codecs.bool(), 0, 4))
        local text = Turns.text(of, { [0] = true, [1] = false })
        local ONE = string.char(0, 0, 128, 63)
        local SIGNED = string.char(0, 0, 0, 128)
        local at = string.find(text, ONE, 1, true)
        Expect.holds(at ~= nil, "a float of one was not spelled where a key goes")
        local held = at :: number
        local hostile = `{string.sub(text, 1, held - 1)}{SIGNED}{string.sub(text, held + #ONE)}`
        Expect.equal(refusedAs(of, hostile), Catalog.MAP_ORDER)
    end),

    -- Records whose fields sit on their own bytes, read from bytes carrying a reading the grids
    -- under them have no point for, laid in one call and in two.
    Harness.case("total.records-on-boundaries-refuse-a-reading-off-their-grid", function()
        local of = Turns.built(
            Codecs.struct({ near = Codecs.int(0, SHORT), after = Codecs.int(0, SHORT) })
        )
        Expect.equal(refusedAs(of, string.char(SHORT + 1, SHORT + 1)), Catalog.TAG)

        local wider = Turns.built(Codecs.struct({
            near = Codecs.int(0, SHORT),
            wider = Codecs.int(0, SHORT_PAIR),
            after = Codecs.int(0, SHORT),
        }))
        Expect.equal(refusedAs(wider, string.rep(string.char(WHOLE_BYTE), 4)), Catalog.TAG)
    end),

    -- Every fixture frame cut at every offset, which is the damage a reader meets without any
    -- hostility, and every single bit flipped, which keeps the length honest and drives the reader
    -- all the way in on bytes that mean something else.
    Harness.case("total.truncation-and-bit-flip", function()
        for _, frame in frames() do
            for cut = 0, #frame.bytes - 1 do
                survives(frame.built, string.sub(frame.bytes, 1, cut), `{frame.of} cut at {cut}`)
            end
            for at = 1, #frame.bytes do
                local byte = string.byte(frame.bytes, at)
                for bit = 0, 7 do
                    local moved = string.char(bit32.bxor(byte, bit32.lshift(1, bit)))
                    local damaged = `{string.sub(frame.bytes, 1, at - 1)}{moved}{string.sub(
                        frame.bytes,
                        at + 1
                    )}`
                    survives(frame.built, damaged, `{frame.of} bit {bit} of byte {at}`)
                end
            end
        end
    end),

    -- Two frames spliced, which no single encode produces: every byte is one some encoder wrote,
    -- in an order none of them wrote them in.
    Harness.case("total.splice", function()
        local all = frames()
        for _, frame in all do
            for _, other in all do
                survives(frame.built, frame.bytes .. other.bytes, `{frame.of} then {other.of}`)
                survives(frame.built, other.bytes .. frame.bytes, `{other.of} then {frame.of}`)
            end
        end
    end),

    -- The all-ones and all-zeros frames at every length up to the one a reader expects and at
    -- multiples past it: one runs out of bytes and the other runs out of meaning.
    Harness.case("total.no-hang", function()
        for _, frame in frames() do
            local widest = #frame.bytes
            for _, adversary in ADVERSARIES do
                local of = string.char(adversary.byte)
                for size = 0, widest do
                    survives(
                        frame.built,
                        string.rep(of, size),
                        `{frame.of} {adversary.of} at {size}`
                    )
                end
                for _, times in OVERLONG do
                    local size = widest * times
                    survives(
                        frame.built,
                        string.rep(of, size),
                        `{frame.of} {adversary.of} at {size}`
                    )
                end
            end
        end
    end),
}
