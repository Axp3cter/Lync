--!strict
--!optimize 2
-- The second law: bytes nobody wrote come back as a value or a refusal, and never as anything else.

local Catalog = require ("@src/kernel/Catalog")
local Lync = require ("@src")
local Protocol = require ("@src/wire/Protocol")

local Expect = require ("@test/harness/Expect")
local Generate = require ("@test/harness/Generate")
local Harness = require ("@test/harness")
local Rng = require ("@test/harness/Rng")
local Schemas = require ("@fixtures/Schemas")
local Turns = require ("@test/harness/Turns")

-- Constants -----------------------------------------------------------

const DEPTH = Generate.DEEP

--[[
    Multiples of a schema's own width that a hostile frame is offered at. In a frame the schema
    could have written, an over-count runs off the end and the buffer refuses it, which is the
    right answer for the wrong reason. Room to spare tells the two apart, a believed count then
    having bytes to eat and handing back a collection the schema does not own.
]]
const OVERLONG = table.freeze ({ 2, 4, 16 })

--[[
    What a byte is written over with where a check corrupts one on purpose.

    All ones and all zeros are the two ends. The other two alternate, which is what sets a pad bit
    without setting every bit, and reaching a pad bit at all is the whole point of them.
]]
const HOSTILE = table.freeze ({ 0x00, 0x55, 0xAA, 0xFF })

-- How many bytes are laid after a frame to give a believed count something to eat.
const SPARE = 512

-- How many values a byte takes, which is where a run of climbing bytes turns over.
const BYTES = 256

--[[
    The two frames a reader is handed that it never wrote. All ones is every count, every tag and
    every index at its widest, which is what drives a length-believing decoder off the end. All
    zeros is the opposite and the one a padding bug reads as a legal empty everything.
]]
const ADVERSARIES = table.freeze ({
    table.freeze ({ of = "ones", byte = 0xFF }),
    table.freeze ({ of = "zeros", byte = 0x00 }),
})

-- A map of exactly four pairs over exactly four keys, which is the map with one legal value.
const FOUR = 4
const KEYED = table.freeze ({ "n1", "n2", "n3", "n4" })

-- A map of two pairs, and the keys it is given, which `total.map-order-holds` puts the other way.
const PAIRED = 2
const LOW = 1
const HIGH = 2

-- The widest a byte-wide key or value reaches, which is what puts each of them in one byte.
const BYTE_WIDE = 255

-- Not an instance, which is what a sender is free to leave where one is looked up.
const PRETEND = table.freeze ({ pretending = true })

-- The class a reference declares and one it does not, kept apart from what a fault would put there.
const WANTED = "Folder"
const STAND_IN = "Part"

-- Three colours, which is a span of three and one index the wire can say it has not.
const PALETTE = table.freeze ({ Color3.new (1, 0, 0), Color3.new (0, 1, 0), Color3.new (0, 0, 1) })

-- Three variants, for the same reason, each a record of one bit.
const TAGS = table.freeze ({
    a = Lync.struct ({ x = Lync.bool () }),
    b = Lync.struct ({ y = Lync.bool () }),
    c = Lync.struct ({ z = Lync.bool () }),
})

--[[
    A codec of every kind narrow enough to enumerate, one of each, every one of them laying out
    inside a single byte. Written out rather than drawn, because a draw lands on the parameters that
    make a kind wide and what is wanted here is the one shape of each that a sweep can exhaust.
]]
const NARROW = table.freeze ({
    table.freeze ({ of = "bool", codec = Lync.bool () }),
    table.freeze ({ of = "int", codec = Lync.int (0, 4) }),
    table.freeze ({ of = "quant", codec = Lync.quant (0, 1, 0.25) }),
    table.freeze ({ of = "angle", codec = Lync.angle (72) }),
    table.freeze ({ of = "str", codec = Lync.str (1, 1) }),
    table.freeze ({ of = "str.alphabet", codec = Lync.str.alphabet ("abc", 1, 1) }),
    table.freeze ({ of = "buffer", codec = Lync.buffer (1, 1) }),
    table.freeze ({ of = "enum", codec = Lync.enum ({ "a", "b", "c" }) }),
    table.freeze ({ of = "bitfield", codec = Lync.bitfield ({ "a", "b", "c" }) }),
    table.freeze ({ of = "vec3.unit", codec = Lync.vec3.unit (90) }),
    table.freeze ({ of = "vec3.bounded", codec = Lync.vec3.bounded (1, 1) }),
    table.freeze ({ of = "rotation.none", codec = Lync.rotation.none () }),
    table.freeze ({ of = "rotation.axis", codec = Lync.rotation.axis (Vector3.yAxis, 90) }),
    table.freeze ({ of = "rotation.direction", codec = Lync.rotation.direction (90) }),
    table.freeze ({ of = "rotation.quat", codec = Lync.rotation.quat (90) }),
    table.freeze ({ of = "color3.palette", codec = Lync.color3.palette (PALETTE) }),
    table.freeze ({ of = "optional", codec = Lync.optional (Lync.bool ()) }),
    table.freeze ({ of = "array", codec = Lync.array (Lync.bool (), 0, 2) }),
    table.freeze ({ of = "map", codec = Lync.map (Lync.int (0, 1), Lync.bool (), 0, 2) }),
    table.freeze ({
        of = "struct",
        codec = Lync.struct ({ a = Lync.bool (), b = Lync.int (0, 4) }),
    }),
    table.freeze ({ of = "tagged", codec = Lync.tagged ("tag", TAGS) }),
    table.freeze ({ of = "vec2", codec = Lync.vec2 (Lync.int (0, 4)) }),
    table.freeze ({ of = "vec3", codec = Lync.vec3 (Lync.int (0, 1)) }),
    table.freeze ({
        of = "cframe",
        codec = Lync.cframe (Lync.vec3.bounded (1, 1), Lync.rotation.none ()),
    }),
})

-- The kinds a byte does not hold, and why each is absent rather than narrowed.
const WIDE = table.freeze ({ "f32", "f64", "color3", "color3.rgb565", "vlq", "vli" })

-- Private -------------------------------------------------------------

--[[
    What a read of hostile bytes answered, as either a refusal or a value. A refusal is the whole of
    what the boundary needs: it pcalls one payload and turns whatever came out into a drop, so a
    raise is the contract rather than a failure. What must never happen is neither, and that is what
    the shape of this function makes checkable.
]]
local function decoded (of: any, text: string): (boolean, any, number)
    local bytes = Turns.held (text)
    local ok, at, value = pcall (of.read, bytes, 0, Turns.CTX)
    if not ok then return false, nil, 0 end
    return true, value, at
end

--[[
    Whether a value a hostile frame produced is one the schema would have produced itself.
    Re-encoding is the test: a decoder that believed a count and handed back nine hundred elements
    of a six-element array answers a value its own encoder refuses, and that refusal is the only
    thing here that knows the bound without being told it a second time.
]]
local function legal (of: any, value: any): string?
    local out = buffer.create (of.maxBytes)
    local ok, at = pcall (of.write, out, 0, value)
    if not ok then return `the value it answered does not encode` end
    if at > of.maxBytes then return `the value it answered encodes to {at} bytes` end
    return nil
end

--[[
    One hostile frame judged. Either the read refused, which is the contract, or it answered, and
    then the answer has to be a value the schema owns and the cursor has to have stayed inside the
    bytes it was given.
]]
local function survives (of: any, text: string, what: string)
    local answered, value, at = decoded (of, text)
    if not answered then return end

    if at > #text then
        Expect.holds (false, `{what}: a read of {at} bytes out of {#text}`)
        return
    end

    local wrong = legal (of, value)
    if wrong == nil then return end
    Expect.holds (false, `{what}: {wrong}`)
end

--[[
    One collection, against the bound its own shape declares.

    Named as what came back and what the kind takes, because a count is a number a person can
    compare at a glance and a path is what tells them which of a nested schema's collections it was.
]]
local function counted (path: string, held: number, shape: Generate.Shape)
    if held >= shape.min and held <= shape.max then return end

    Expect.holds (
        false,
        `{path} came back holding {held}, and its {shape.at} takes {shape.min} to {shape.max}`
    )
end

-- Every collection in a decoded value, held to its own bound.
local function within (shape: Generate.Shape, value: any, path: string)
    local at = shape.at

    if at == "optional" then
        if value ~= nil then within (shape.of[1], value, path) end
    elseif at == "struct" then
        for index, name in shape.names do
            within (shape.of[index], value[name], `{path}.{name}`)
        end
    elseif at == "tagged" then
        local named = tostring (value[shape.text])
        local index = table.find (shape.names, named)
        if index ~= nil then within (shape.of[index], value, `{path}.{named}`) end
    elseif at == "array" then
        counted (path, #value, shape)
        for index, one in value do
            within (shape.of[1], one, `{path}[{index}]`)
        end
    elseif at == "map" then
        local held = 0
        for key, one in value do
            held += 1
            within (shape.of[2], one, `{path}[{tostring (key)}]`)
        end
        counted (path, held, shape)
    elseif at == "str" or at == "str.alphabet" then
        counted (path, #value, shape)
    elseif at == "buffer" then
        counted (path, buffer.len (value), shape)
    end
end

--[[
    Room whose bytes climb, a byte at a time from nothing upward and around again.

    Whatever a key codec is, a wider run of bytes reads as a wider key, so keys taken out of this
    arrive in the order a map requires and a reader goes on believing the count that named them.
]]
local function climbing (): string
    local out = table.create (SPARE)
    for at = 1, SPARE do
        out[at] = string.char ((at - 1) % BYTES)
    end
    return table.concat (out)
end

-- Every fixture case, encoded once, so a sweep pays for the encode once as well.
local function frames (): { { of: string, codec: any, built: any, bytes: string } }
    local out = {}
    for _, fixture in Schemas.all do
        local of = Turns.built (fixture.codec)
        for _, case in fixture.cases do
            table.insert (out, {
                of = `{fixture.name}.{case.name}`,
                codec = fixture.codec,
                built = of,
                bytes = Turns.text (of, case.value),
            })
        end
    end
    return out
end

-- Public --------------------------------------------------------------

return {
    --[[
        Every schema the vocabulary can build, over bytes damaged every way a frame is damaged,
        which is the law itself: a decoder handed bytes nobody wrote answers a value or refuses and
        never a third thing.
    ]]
    Harness.property ("total.no-crash", "decode", function (rng: Rng.Rng)
        local shape = Generate.shape (rng, DEPTH)
        local of = Turns.built (Generate.codec (shape))

        local bytes = Turns.text (of, Generate.value (shape, rng))
        local other = Turns.text (of, Generate.value (shape, rng))

        local damaged, way = Generate.corrupted (rng, bytes, other)
        survives (of, damaged, `{shape.at} {way}`)
    end),

    --[[
        What a hostile frame made the decoder allocate. A length prefix is the one number a decoder
        acts on before it can know whether to believe it, so a count read and believed is a table
        sized by whoever wrote the bytes.
    ]]
    Harness.property ("total.bounded-alloc", "decode", function (rng: Rng.Rng)
        local shape = Generate.shape (rng, DEPTH)
        local of = Turns.built (Generate.codec (shape))

        local bytes = Turns.text (of, Generate.value (shape, rng))
        local other = Turns.text (of, Generate.value (shape, rng))

        local damaged = Generate.corrupted (rng, bytes, other)
        local flat = string.rep (string.char (Rng.pick (rng, HOSTILE)), SPARE)
        local noise = buffer.readstring (Rng.bytes (rng, SPARE), 0, SPARE)

        for _, text in { damaged, damaged .. flat, damaged .. noise, damaged .. climbing () } do
            local answered, value = decoded (of, text)
            if answered then within (shape, value, shape.at) end
        end
    end),

    --[[
        A map handed bytes nobody wrote, and the count it comes back with. Its schema has one legal
        value, so the reading is a count rather than a comparison and can say what is wrong rather
        than that something is.
    ]]
    Harness.case ("total.map-count-holds", function ()
        local of = Turns.built (Lync.map (Lync.enum (KEYED), Lync.vlq (), FOUR, FOUR))

        local value = {}
        for index, name in KEYED do
            value[name] = index
        end

        local bytes = Turns.text (of, value)
        for at = 1, #bytes do
            for _, byte in HOSTILE do
                local text = string.sub (bytes, 1, at - 1)
                    .. string.char (byte)
                    .. string.sub (bytes, at + 1)

                local answered, got = decoded (of, text)
                if not answered then continue end

                local count = 0
                for _ in got do
                    count += 1
                end

                Expect.equal (count, FOUR)
            end
        end
    end),

    -- A map whose keys descend, which is a frame this schema could not have written.
    Harness.case ("total.map-order-holds", function ()
        local one = Lync.int (0, BYTE_WIDE)
        local of = Turns.built (Lync.map (one, one, PAIRED, PAIRED))

        local bytes = Turns.text (of, { [LOW] = LOW, [HIGH] = HIGH })
        Expect.equal (#bytes, PAIRED * PAIRED)

        local answered = decoded (of, bytes)
        Expect.holds (answered, "the map this codec wrote was refused")

        -- The keys the other way about, which the values after them are no longer in the order of.
        local reversed = string.sub (bytes, LOW + 1, LOW + 1)
            .. string.sub (bytes, LOW, LOW)
            .. string.sub (bytes, PAIRED + 1)

        Expect.equal (#reversed, #bytes)
        Expect.equal (decoded (of, reversed), false)
    end),

    --[[
        Every frame of a byte or less, against a codec of every kind. The sweeps around this one
        damage frames a schema wrote, and this asks the opposite: whether anything a reader can be
        handed comes back as a value its own writer would refuse.
    ]]
    Harness.case ("total.enumerated", function ()
        local named: { [string]: boolean } = {}

        for _, entry in NARROW do
            Expect.holds (named[entry.of] == nil, `{entry.of} is swept twice`)
            named[entry.of] = true
        end
        for _, at in WIDE do
            Expect.holds (named[at] == nil, `{at} is both swept and named wide`)
            named[at] = true
        end

        for _, at in Generate.KINDS do
            Expect.holds (named[at] ~= nil, `{at} is neither swept nor named wide`)
            named[at] = nil
        end
        for at in named do
            Expect.holds (false, `{at} is no kind the vocabulary spells`)
        end

        for _, entry in NARROW do
            local of = Turns.built (entry.codec)
            survives (of, "", `{entry.of} empty`)

            for byte = 0, 255 do
                survives (of, string.char (byte), `{entry.of} {byte}`)
            end
        end
    end),

    --[[
        A frame cut at every offset. Truncation is the damage a reader meets without any hostility
        at all: a dropped packet, a split that went wrong and a client that stopped part way
        through a write all arrive as a short frame, and the cut at zero is the one every length
        check has to survive.
    ]]
    Harness.case ("total.truncation", function ()
        for _, frame in frames () do
            for cut = 0, #frame.bytes - 1 do
                survives (frame.built, string.sub (frame.bytes, 1, cut), `{frame.of} cut at {cut}`)
            end
        end
    end),

    --[[
        One bit flipped at every position. A flip is the damage that keeps the length honest, so
        every length check passes and the reader goes all the way in on bytes that mean something
        else: a tag that names no variant, an index off the end of a grid, a presence bit that
        promises a field the frame does not carry.
    ]]
    Harness.case ("total.bit-flip", function ()
        for _, frame in frames () do
            for at = 1, #frame.bytes do
                local byte = string.byte (frame.bytes, at)
                for bit = 0, 7 do
                    local moved = string.char (bit32.bxor (byte, bit32.lshift (1, bit)))
                    local damaged = `{string.sub (frame.bytes, 1, at - 1)}{moved}{string.sub (
                        frame.bytes,
                        at + 1
                    )}`
                    survives (frame.built, damaged, `{frame.of} bit {bit} of byte {at}`)
                end
            end
        end
    end),

    --[[
        Two frames spliced. This is the damage no single encode can produce: the bytes are all bytes
        some encoder wrote, in an order none of them wrote them in, so every byte is individually
        plausible and the frame as a whole is a lie. A reader that trusts a length because the bytes
        after it look like a payload is a reader this finds.
    ]]
    Harness.case ("total.splice", function ()
        local all = frames ()
        for _, frame in all do
            for _, other in all do
                survives (frame.built, frame.bytes .. other.bytes, `{frame.of} then {other.of}`)
                survives (frame.built, other.bytes .. frame.bytes, `{other.of} then {frame.of}`)
            end
        end
    end),

    --[[
        The two frames of the constants above, at the length a reader expects and at every length up
        to it. Every length because a short frame and a whole one fail differently: one runs out of
        bytes and the other runs out of meaning, and only the pair says which happened. The one a
        padding bug reads as a legal empty everything.
    ]]
    Harness.case ("total.no-hang", function ()
        for _, frame in frames () do
            local widest = #frame.bytes
            for _, adversary in ADVERSARIES do
                local of = string.char (adversary.byte)
                for size = 0, widest do
                    survives (
                        frame.built,
                        string.rep (of, size),
                        `{frame.of} {adversary.of} at {size}`
                    )
                end
                for _, times in OVERLONG do
                    local size = widest * times
                    survives (
                        frame.built,
                        string.rep (of, size),
                        `{frame.of} {adversary.of} at {size}`
                    )
                end
            end
        end
    end),

    --[[
        The sender fills the reference array, so a frame can name a slot holding anything at all.
        A reader handing back whatever it finds there answers a value its own writer would never
        produce, and nothing else here reaches that array.
    ]]
    Harness.case ("total.sidecar-holds", function ()
        for _, of in { Turns.built (Lync.inst ()), Turns.built (Lync.inst ("Player")) } do
            local out = buffer.create (math.max (of.maxBytes, 1))
            of.write (out, 0, PRETEND)

            Expect.equal (typeof (of.sidecar.refs[1]), "table")
            Expect.holds (not (pcall (of.read, out, 0, Turns.CTX)), "a reference answered a table")
        end
    end),

    --[[
    A reference of the class a schema declared, and one of another class in its place. What rides
    beside a frame is never read off the frame, so the class is the one thing a receiver can hold
    it to, and a schema declaring one says every other class is a frame it did not write.
]]
    Harness.case ("total.reference-holds-its-class", function ()
        local of = Turns.built (Lync.inst (WANTED))

        local b = buffer.create (math.max (of.maxBytes, 1))
        of.write (b, 0, Instance.new (WANTED))

        local _, one = of.read (b, 0, Turns.CTX)
        Expect.holds (one ~= nil, `a reference of a {WANTED} came back as nothing`)

        -- The same slot, standing something else in it, which is the frame a class is held against.
        of.sidecar.refs[1] = Instance.new (STAND_IN)

        local ok, why = pcall (of.read, b, 0, Turns.CTX)
        Expect.holds (not ok, `a reference of a {STAND_IN} was taken where a {WANTED} was declared`)
        Expect.equal ((why :: any).code, Catalog.SIDECAR)
    end),

    --[[
        A reference whose slot is a varint that never ends. What rides beside a frame is named by
        an index into it, and the index is the one field here a reader takes on the frame's word
        alone, so bytes that keep saying there is more are bytes a reader has to stop on rather
        than follow past the groups a varint is allowed.
    ]]
    Harness.case ("total.slot-varint-is-refused", function ()
        local of = Turns.built (Lync.inst ())

        local b = buffer.create (16)
        buffer.fill (b, 0, 0xFF)

        local ok, why = pcall (of.read, b, 0, Turns.CTX)
        Expect.holds (not ok, "a slot varint running past its groups was taken")
        Expect.equal ((why :: any).code, Catalog.VARINT)
    end),

    --[[
        A frame whose padding is not zero, which is damage no encoder makes. The bits over the last
        element of a packed run go down as nothing, so a frame carrying anything else in them spells
        one value two ways, and two spellings of one value are what the order of map keys rests on
        being impossible. Each of the three forms that leave a pad behind is put to it.
    ]]
    Harness.case ("total.pad-is-refused", function ()
        local forms = {
            { of = "a run", codec = Lync.array (Lync.int (0, 3), 3, 3), value = { 1, 2, 3 } },
            { of = "an alphabet", codec = Lync.str.hex (3, 3), value = "abc" },
            { of = "a wide field", codec = Lync.int (0, 2 ^ 40), value = 12345 },

            --[[
                The two ways a map spells its keys: on a grid, where they go down as the sorted
                run of indices they land on, and as bytes, where what they spell is what they
                sort by. Each packs a run of its own and each leaves its own pad behind.
            ]]
            {
                of = "a map's keys",
                codec = Lync.map (Lync.int (0, 5), Lync.int (0, 255), 3, 3),
                value = { [1] = 1, [3] = 2, [5] = 3 },
            },
            {
                of = "a map's values",
                codec = Lync.map (Lync.int (0, 255), Lync.int (0, 5), 3, 3),
                value = { [1] = 1, [3] = 2, [5] = 3 },
            },
            {
                of = "a spelled map",
                codec = Lync.map (Lync.str (1, 1), Lync.int (0, 5), 3, 3),
                value = { a = 1, b = 2, c = 3 },
            },
        }

        for _, form in forms do
            local of = Turns.built (form.codec)
            local text = Turns.text (of, form.value)

            local padded = false
            for at = 1, #text do
                local byte = string.byte (text, at)
                for bit = 0, 7 do
                    local moved = string.char (bit32.bxor (byte, bit32.lshift (1, bit)))
                    local hostile =
                        `{string.sub (text, 1, at - 1)}{moved}{string.sub (text, at + 1)}`

                    local ok, caught = pcall (of.read, Turns.held (hostile), 0, Turns.CTX)
                    if not ok and type (caught) == "table" and caught.code == Catalog.PAD then
                        padded = true
                    end
                end
            end

            Expect.holds (padded, `no bit of {form.of} reached the pad it left over`)
        end
    end),

    --[[
        A wide field's two refusals, told apart. Bits over its width are pad nobody wrote, and a
        value under its width that names no point on its grid is a tag nobody could have meant.
        Which of the two a frame is refused under says where the damage is, and a reader told the
        wrong one goes looking in the wrong place.
    ]]
    Harness.case ("total.wide-past-its-grid", function ()
        local of = Turns.built (Lync.int (0, 2 ^ 40))
        local text = Turns.text (of, 12345)

        local seen: { [string]: boolean } = {}
        for at = 1, #text do
            local byte = string.byte (text, at)
            for bit = 0, 7 do
                local moved = string.char (bit32.bxor (byte, bit32.lshift (1, bit)))
                local hostile = `{string.sub (text, 1, at - 1)}{moved}{string.sub (text, at + 1)}`

                local ok, caught = pcall (of.read, Turns.held (hostile), 0, Turns.CTX)
                if not ok and type (caught) == "table" then seen[caught.code] = true end
            end
        end

        Expect.holds (
            seen[Catalog.TAG],
            "no bit under a wide field's width was refused for naming no point on its grid"
        )
    end),

    --[[
        A packed run's element past the end of its own grid. The bits carrying one element hold
        more patterns than the grid has points whenever its span stops short of them, so a frame
        can name an element no encoder could have written, and the run refuses it where it reads
        it rather than handing back a value its own writer would turn away.
    ]]
    Harness.case ("total.run-past-its-grid", function ()
        local forms = {
            {
                of = "a run",
                codec = Lync.array (Lync.int (0, 2), 3, 3),
                value = { 1, 2, 1 } :: any,
            },
            { of = "an alphabet", codec = Lync.str.alphabet ("abc", 3, 3), value = "abc" :: any },

            -- A grid off zero reads its elements back through itself, which is its own walk.
            {
                of = "a shifted run",
                codec = Lync.array (Lync.int (1, 3), 3, 3),
                value = { 1, 2, 3 } :: any,
            },
        }

        for _, form in forms do
            local of = Turns.built (form.codec)
            local text = Turns.text (of, form.value)

            local seen: { [string]: boolean } = {}
            for at = 1, #text do
                local byte = string.byte (text, at)
                for bit = 0, 7 do
                    local moved = string.char (bit32.bxor (byte, bit32.lshift (1, bit)))
                    local hostile =
                        `{string.sub (text, 1, at - 1)}{moved}{string.sub (text, at + 1)}`

                    local ok, caught = pcall (of.read, Turns.held (hostile), 0, Turns.CTX)
                    if not ok and type (caught) == "table" then seen[caught.code] = true end
                end
            end

            Expect.holds (
                seen[Catalog.TAG],
                `no bit of {form.of} named an element off the grid its own width carries`
            )
        end
    end),

    --[[
        The three ways a map can be a frame no encoder wrote, told apart by what each is refused
        under. A count past the bound it declared, an entry naming no point on its grid, and keys
        that do not climb are separate faults with separate codes, and a reader answering one of
        them for another sends whoever reads the log to the wrong half of the schema.
    ]]
    Harness.case ("total.map-refusals-are-told-apart", function ()
        --[[
            Each form reaches one of the checks and not the other of its pair: a grid holding every
            pattern its bits spell has no value off it, so a map built of one on one side is a map
            whose only way to a tag is the other side.
        ]]
        local WHOLE = Lync.int (0, 255)
        local PART = Lync.int (0, 5)

        local forms = {
            {
                of = "a gridded map",
                codec = Lync.map (PART, PART, 0, 3),
                value = { [1] = 1, [3] = 2, [5] = 3 } :: any,
                wants = { Catalog.COUNT, Catalog.TAG, Catalog.MAP_ORDER },
            },
            {
                of = "a gridded map's keys",
                codec = Lync.map (PART, WHOLE, 0, 3),
                value = { [1] = 1, [3] = 2, [5] = 3 } :: any,
                wants = { Catalog.TAG },
            },
            {
                of = "a gridded map's values",
                codec = Lync.map (WHOLE, PART, 0, 3),
                value = { [1] = 1, [3] = 2, [5] = 3 } :: any,
                wants = { Catalog.TAG },
            },
            {
                of = "a spelled map",
                codec = Lync.map (Lync.str (1, 1), PART, 0, 3),
                value = { a = 1, b = 2, c = 3 } :: any,
                wants = { Catalog.COUNT, Catalog.TAG, Catalog.MAP_ORDER },
            },
            {
                of = "a tagged union",
                codec = Lync.tagged ("tag", TAGS),
                value = { tag = "a", x = true } :: any,
                wants = { Catalog.TAG },
            },
        }

        for _, form in forms do
            local of = Turns.built (form.codec)
            local text = Turns.text (of, form.value)

            local seen: { [string]: boolean } = {}
            for at = 1, #text do
                local byte = string.byte (text, at)
                for bit = 0, 7 do
                    local moved = string.char (bit32.bxor (byte, bit32.lshift (1, bit)))
                    local hostile =
                        `{string.sub (text, 1, at - 1)}{moved}{string.sub (text, at + 1)}`

                    local ok, caught = pcall (of.read, Turns.held (hostile), 0, Turns.CTX)
                    if not ok and type (caught) == "table" then seen[caught.code] = true end
                end
            end

            for _, code in form.wants do
                Expect.holds (seen[code], `{form.of} was never refused as {code}`)
            end
        end
    end),

    --[[
        Two keys a frame spells apart and a reader answers as one. A map holds its keys to climbing
        by what they spell, which every pair spelled differently passes, so the pair that reads back
        as one key walks straight through it and the second takes the place of the first. What comes
        back is a map a pair short of the count it stated, which is why the key is refused instead.
    ]]
    Harness.case ("total.map-keys-that-read-as-one", function ()
        local of = Turns.built (Lync.map (Lync.f32 (), Lync.bool (), 0, 4))
        local text = Turns.text (of, { [0] = true, [1] = false })

        --[[
            A float of one, and the same four bytes turned into a zero signed the other way. The
            pair still climbs, since the sign sits in the byte that sorts last, and both of them
            read back as the one zero every reader answers with.
        ]]
        local ONE = string.char (0, 0, 128, 63)
        local SIGNED = string.char (0, 0, 0, 128)

        local at = string.find (text, ONE, 1, true)
        Expect.holds (at ~= nil, "a float of one was not spelled where a key goes")

        local held = at :: number
        local hostile = `{string.sub (text, 1, held - 1)}{SIGNED}{string.sub (text, held + #ONE)}`

        local ok, caught = pcall (of.read, Turns.held (hostile), 0, Turns.CTX)
        Expect.holds (not ok, "two keys reading as one were taken rather than refused")
        Expect.equal ((caught :: any).code, Catalog.MAP_ORDER)
    end),

    --[[
        Every shape a value nobody declared can take, written and read back. This is the one kind
        with no schema to draw from, so the corpus is what stands in for one: each entry is a form
        the tags spell, and a value that comes back different is a tag whose two halves disagree.
    ]]
    Harness.case ("total.unknown-comes-back-as-it-went", function ()
        --[[
            A whole past what a varint keeps in one group, so the wide branch is walked rather than
            asserted. Two to the fortieth takes six groups where every other entry takes one.
        ]]
        const WIDE = 2 ^ 40

        local of = Turns.built (Lync.unknown (Protocol.SECTION_BYTES))

        local corpus: { any } = {
            true,
            false,
            0,
            -1,
            WIDE,
            -WIDE,
            0.5,
            "",
            "a string",
            buffer.fromstring ("opaque"),
            { 1, 2, 3 },
            { a = 1, b = "two" },
            { [1] = "one", [true] = "yes" },
            { {}, { { 1 } } },
        }

        for _, value in corpus do
            local bytes, size = Turns.wrote (of, value)
            local at, got = of.read (bytes, 0, Turns.CTX)

            Expect.equal (at, size)
            Expect.equal (got, value)
        end

        -- Nothing, which is the one value a list of them cannot hold and so is asked on its own.
        local bytes, size = Turns.wrote (of, nil)
        local at, got = of.read (bytes, 0, Turns.CTX)

        Expect.equal (at, size)
        Expect.equal (got, nil)
    end),

    --[[
        Bytes nobody wrote where a value describes itself. A tag no writer spells and a count past
        the bytes there are are the two ways such a frame goes wrong, and both are the reader's to
        refuse: the declaration said only how much room it takes, so there is nothing else to check
        the bytes against.
    ]]
    Harness.case ("total.unknown-refuses-a-frame-nobody-wrote", function ()
        -- A tag past every one the wire spells, which is what a byte nobody wrote reads as.
        const UNSPELLED = 200

        local of = Turns.built (Lync.unknown (Protocol.SECTION_BYTES))
        local bytes = Turns.held (string.char (UNSPELLED))

        local ok, caught = pcall (of.read, bytes, 0, Turns.CTX)
        Expect.holds (not ok, "a tag nobody spells was taken rather than refused")
        Expect.equal ((caught :: any).code, Catalog.TAG)

        --[[
            A string tag with a count past the room the declaration gave it. Each part costs at
            least the byte its tag takes, so a count over the bytes left is one no writer could
            have spelled, whatever the parts behind it would have come to. The count is one group
            wide, since a frame that stops inside the count is a shorter frame than this one asks.
        ]]
        const OVER = 100

        local long = Turns.held (string.char (Protocol.UNKNOWN_TEXT, OVER))
        local fine, why = pcall (of.read, long, 0, Turns.CTX)

        Expect.holds (not fine, "a count past the bytes was taken rather than refused")
        Expect.equal ((why :: any).code, Catalog.COUNT)
    end),
}
