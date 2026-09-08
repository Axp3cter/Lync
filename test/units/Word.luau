--!strict
--!optimize 2
-- The bit region emitter: real lowered words laid down and taken back up through both halves.

local Base = require("@src/codec/Base")
local Catalog = require("@src/kernel/Catalog")
local Codecs = require("@src/codec")
local Lower = require("@src/shape/Lower")
local Serial = require("@src/shape/Serial")
local Word = require("@src/shape/emit/Word")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")
local Rng = require("@test/harness/Rng")

local AT = 5
local ROOM = 64
local NAMES = table.freeze({ "red", "green", "blue" })
local FLAGS = table.freeze({ "dead", "airborne" })

type Emitted = {
    word: any,
    pack: Word.Pack,
    unpack: Word.Unpack,
    solo: Word.Solo?,
    slots: { number },
    holds: { any },
}

-- A codec lowered and emitted, with the scratch a group would supply. A word alone lowers to a
-- word node, a record to a group holding one.
local function emitted(of: any): Emitted
    local site: Lower.Site = { paths = Serial.interner(), expected = Serial.interner() }
    local shape: any = Lower.of(Base.cell(of), "root", site)
    local word = if shape.op == "word" then shape else shape.word
    local pack, unpack, solo = Word.emit(word, site.paths, site.expected)
    local holds = {}
    if shape.op == "group" then
        for index in shape.nests do
            holds[index] = {}
        end
    end
    return {
        word = word,
        pack = pack,
        unpack = unpack,
        solo = solo,
        slots = table.create(#word.leaves, 0),
        holds = holds,
    }
end

-- A value through the region and back, into a fresh record, with the bytes around it left alone.
local function through(of: Emitted, value: any): (any, any)
    local b = buffer.create(ROOM)
    buffer.fill(b, 0, 0xA5)
    of.pack(b, AT, value, of.slots, of.holds)
    for at = 0, AT - 1 do
        Expect.equal(buffer.readu8(b, at), 0xA5)
    end
    Expect.equal(buffer.readu8(b, AT + of.word.maxBytes), 0xA5)
    local into = {}
    local bare = of.unpack(b, AT, into, of.slots, of.holds)
    return into, bare
end

local function rejected(call: () -> ()): Catalog.Code?
    local ok, thrown = pcall(call)
    if ok then return nil end
    return (thrown :: any).code
end

return {
    -- A record of plain fields: every field to its bits and back, in one region.
    Harness.case("word.flat-record", function()
        local of = emitted(Codecs.struct({
            hp = Codecs.int(0, 100),
            alive = Codecs.bool(),
            team = Codecs.enum(NAMES),
            speed = Codecs.quant(0, 1, 0.25),
        }))
        Expect.equal(of.word.bits, 7 + 1 + 2 + 3)
        local into = through(of, { hp = 42, alive = true, team = "green", speed = 0.5 })
        Expect.equal(into, { hp = 42, alive = true, team = "green", speed = 0.5 })
        into = through(of, { hp = 100, alive = false, team = "red", speed = 1 })
        Expect.equal(into, { hp = 100, alive = false, team = "red", speed = 1 })
        Expect.equal(of.solo, nil)
    end),

    -- A value the grid has no place for is refused in the caller's words, naming the field.
    Harness.case("word.refuses", function()
        local of = emitted(Codecs.struct({ hp = Codecs.int(0, 100), alive = Codecs.bool() }))
        local b = buffer.create(ROOM)
        local bads =
            { { hp = 101, alive = true }, { hp = "42", alive = true }, { hp = 1, alive = 1 } }
        for _, bad in bads do
            local said = Expect.throws(function()
                of.pack(b, AT, bad, of.slots, of.holds)
            end)
            Expect.holds(string.find(said, "root.", 1, true) ~= nil, `it named no field: {said}`)
            Expect.holds(string.find(said, "expected", 1, true) ~= nil, `it said no want: {said}`)
        end
    end),

    -- Bytes spelling an index past a grid are rejected with the catalogue code, never a crash.
    Harness.case("word.rejects", function()
        local of = emitted(Codecs.struct({ team = Codecs.enum(NAMES) }))
        local grid = of.word.leaves[1]
        local b = buffer.create(ROOM)
        of.pack(b, AT, { team = "blue" }, of.slots, of.holds)
        Expect.equal(buffer.readu8(b, AT), grid.toIndex("blue"))
        Expect.equal(grid.span, 2)
        buffer.writeu8(b, AT, 3)
        Expect.equal(
            rejected(function()
                of.unpack(b, AT, {}, of.slots, of.holds)
            end),
            Catalog.TAG
        )

        -- A grid that fills its bits has nothing to reject: every pattern is a point.
        local flags = emitted(Codecs.struct({ a = Codecs.bool(), b = Codecs.int(0, 3) }))
        buffer.writeu8(b, AT, 0xFF)
        Expect.equal(
            rejected(function()
                flags.unpack(b, AT, {}, flags.slots, flags.holds)
            end),
            nil
        )
    end),

    -- A lone field is the whole word, and offers a solo pair for the group that is only it.
    Harness.case("word.lone", function()
        local of = emitted(Codecs.int(0, 1000))
        Expect.equal(of.word.maxBytes, 2)
        local _, bare = through(of, 777)
        Expect.equal(bare, 777)

        local solo = of.solo :: Word.Solo
        Expect.holds(solo ~= nil, "a lone keyless word offered no solo")
        local b = buffer.create(ROOM)
        Expect.equal(solo.write(b, 0, 999), 2)
        local after, value = (solo.read :: any)(b, 0, nil)
        Expect.equal(after, 2)
        Expect.equal(value, 999)
        Expect.throws(function()
            solo.write(b, 0, 1001)
        end, "root expected")

        local named = emitted(Codecs.enum(NAMES))
        local _, colour = through(named, "green")
        Expect.equal(colour, "green")
        local nb = buffer.create(ROOM)
        buffer.writeu8(nb, 0, 3)
        Expect.equal(
            rejected(function()
                (named.solo :: any).read(nb, 0, nil)
            end),
            Catalog.TAG
        )
    end),

    -- A bitfield and a presence bit are reached through a pull and a push, and a dissolved record
    -- through the record its nest holds, which the group seats there before the word runs.
    Harness.case("word.general", function()
        local of = emitted(Codecs.struct({
            flags = Codecs.bitfield(FLAGS),
            maybe = Codecs.optional(Codecs.str(0, 4)),
            inner = Codecs.struct({ near = Codecs.bool(), far = Codecs.int(0, 7) }),
        }))
        Expect.equal(of.word.bits, 1 + 2 + 1 + 3)
        of.holds[1] = { near = true, far = 5 }
        local into = through(of, { flags = { dead = true }, maybe = "here" })
        Expect.equal(into.flags, { dead = true, airborne = false })
        Expect.equal(into.maybe, nil)
        Expect.equal(into.inner, nil)
        Expect.equal(of.holds[1], { near = true, far = 5 })

        -- The presence bit reads the record for the field's absence.
        local presence = 0
        for _, join in of.word.joins do
            if join.key == "maybe" then presence = join.at end
        end
        local b = buffer.create(ROOM)
        of.pack(b, AT, { flags = {} }, of.slots, of.holds)
        Expect.equal(of.slots[presence], 0)
        of.pack(b, AT, { flags = {}, maybe = "x" }, of.slots, of.holds)
        Expect.equal(of.slots[presence], 1)
    end),

    -- Fields wide enough to straddle windows come back whole.
    Harness.case("word.straddles", function()
        local of = emitted(Codecs.struct({
            a = Codecs.int(0, 2 ^ 20 - 1),
            b = Codecs.int(0, 2 ^ 20 - 1),
            c = Codecs.int(0, 2 ^ 12 - 1),
            d = Codecs.bool(),
        }))
        Expect.equal(#of.word.plan > 1 or of.word.plan[1].bytes == 4, true)
        local values = { a = 2 ^ 20 - 1, b = 123456, c = 4095, d = true }
        Expect.equal(through(of, values), values)
    end),

    -- Every drawn record round-trips, and what comes back is the grid's own reading.
    Harness.property("word.round-trips", "leaves", function(rng: Rng.Rng)
        local of = emitted(Codecs.struct({
            hp = Codecs.int(-50, 50),
            alive = Codecs.bool(),
            team = Codecs.enum(NAMES),
            flags = Codecs.bitfield(FLAGS),
            angle = Codecs.angle(10),
        }))
        local value = {
            hp = rng:int(-50, 50),
            alive = rng:bool(),
            team = rng:pick(NAMES),
            flags = { dead = rng:bool(), airborne = rng:bool() },
            angle = rng:int(0, 35) * 10,
        }
        local into = through(of, value)
        Expect.equal(into, value)
    end),
}
