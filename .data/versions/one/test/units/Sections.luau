--!strict
--!optimize 2
-- One partition's flush as the bytes a section becomes: every kind out and back through the
-- layout itself, which is where a frame nobody could have written is turned away.

local Catalog = require("@src/kernel/Catalog")
local Codecs = require("@src/codec")
local Compile = require("@src/shape/Compile")
local Protocol = require("@src/wire/Protocol")
local Sections = require("@src/state/Sections")
local Types = require("@src/Types")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")

local ROOM = 512
local AT = 0
local CTX: Types.ValidateContext = table.freeze({ player = nil, now = 0, last = nil })
local WHERE = table.freeze({ file = "Game.Net", line = 1 })

-- Slots that climb by two and ids that climb by one, which store the same step.
local SLOTS = table.freeze({ 1, 3, 5, 7, 9 })
local IDS = table.freeze({ 1, 2, 3, 4, 5 })

-- Where the ids' steps go down in the single-field keyframe: the header, the count with the
-- slots' width, the first slot, the slots' steps, the width the ids take, and the first id.
local STEPS = 6

local function compiled(fields: any, key: string?): any
    local set = { kind = "set", of = Codecs.struct(fields), keyField = key, at = WHERE }
    return Compile.build("sections", { roster = set :: any }).byName.roster
end

local function partition(def: any): (Sections.Columns, Sections.History)
    local columns: Sections.Columns, prev: Sections.History = {}, {}
    for index = 1, def.fieldCount do
        columns[index] = {}
        prev[index] = {}
    end
    return columns, prev
end

-- A keyframe over the listed slots, with the one field counting up.
local function keyframed(def: any): (Sections.Layout, buffer, number, Sections.History)
    local of = Sections.of(def)
    local columns, prev = partition(def)
    local frame = of.frame
    frame.count = #SLOTS
    for index, slot in SLOTS do
        frame.slots[index] = slot
        frame.ids[index] = IDS[index]
        columns[1][slot] = index
    end
    local b = buffer.create(ROOM)
    local after = Sections.keyframe(of, b, AT, columns)
    return of, b, after, prev
end

local function rejected(call: () -> ()): (Catalog.Code?, string?)
    local ok, why = pcall(call)
    if ok or type(why) ~= "table" then return nil, nil end
    return (why :: any).code, (why :: any).facts.said
end

return {
    -- A keyframe written and read back by a second layout, every id, slot and value itself.
    Harness.case("sections.keyframe-round-trip", function()
        local def = compiled({ score = Codecs.int(0, 100) })
        local _, b, wrote, prev = keyframed(def)
        local reader = Sections.of(def)
        local kind, after = Sections.taken(reader, b, AT, prev, CTX)
        Expect.equal(kind, Protocol.SECTION_KEYFRAME)
        Expect.equal(after, wrote)
        Expect.equal(reader.frame.count, #SLOTS)
        for index = 1, #SLOTS do
            Expect.equal(reader.frame.slots[index], SLOTS[index])
            Expect.equal(reader.frame.ids[index], IDS[index])
            Expect.equal(reader.frame.values[1][index], index)
        end
        Expect.equal(Sections.about(reader, b, AT, CTX), Protocol.SECTION_KEYFRAME)
    end),

    -- The ids' steps padded with something other than zero, which spells one list two ways.
    Harness.case("sections.keyframe-ids-refuse-a-pad", function()
        local def = compiled({ score = Codecs.int(0, 100) })
        local of, b, _, prev = keyframed(def)
        buffer.writeu8(b, AT + STEPS, bit32.bor(buffer.readu8(b, AT + STEPS), 0x80))
        local code, said = rejected(function()
            Sections.taken(of, b, AT, prev, CTX)
        end)
        Expect.equal(code, Catalog.SECTION)
        Expect.holds(string.find(said :: string, "padding", 1, true) ~= nil, `it said {said}`)
    end),

    -- Ids that do not climb are spelled in signed varints, and a keyframe of a set with a newest
    -- field carries a generation per slot.
    Harness.case("sections.keyframe-ids-and-generations", function()
        local def = compiled({ score = Codecs.int(0, 100), pos = Codecs.vec3():newest() })
        local of = Sections.of(def)
        local columns, prev = partition(def)
        local frame = of.frame
        local ids = { 9, -4, 2 }
        frame.count = 3
        for index, slot in { 2, 3, 4 } do
            frame.slots[index] = slot
            frame.ids[index] = ids[index]
            frame.gens[index] = index % 4
            columns[def.fieldIndex.score][slot] = index
            columns[def.fieldIndex.pos][slot] = Vector3.new(index, 0, 0)
        end
        local b = buffer.create(ROOM)
        Sections.keyframe(of, b, AT, columns)

        local reader = Sections.of(def)
        Sections.taken(reader, b, AT, prev, CTX)
        Expect.equal({ reader.frame.ids[1], reader.frame.ids[2], reader.frame.ids[3] }, ids)
        Expect.equal(
            { reader.frame.gens[1], reader.frame.gens[2], reader.frame.gens[3] },
            { 1, 2, 3 }
        )
        Expect.equal(reader.frame.values[def.fieldIndex.pos][2], Vector3.new(2, 0, 0))
    end),

    -- A delta: one field covering every slot as a run, one wide field on some of them as gains
    -- against the baseline, and a string a value at a time.
    Harness.case("sections.delta-round-trip", function()
        local def = compiled({
            flag = Codecs.bool(),
            name = Codecs.str(0, 8),
            score = Codecs.int(0, 100000),
        })
        local flag, name, score = def.fieldIndex.flag, def.fieldIndex.name, def.fieldIndex.score
        Expect.holds(Sections.of(def).fields[score].gain ~= nil, "a wide int takes no gain")
        Expect.equal(Sections.of(def).fields[flag].gain, nil)

        local of = Sections.of(def)
        local columns, prev = partition(def)
        columns[flag][2], columns[flag][5] = true, false
        columns[name][2], columns[name][5] = "two", "five"
        columns[score][2], columns[score][5] = 500, 7
        local was = prev[score] :: { [number]: number }
        was[2], was[5] = 450, 7

        local frame = of.frame
        frame.count = 2
        frame.slots[1], frame.slots[2] = 2, 5
        local chosen = frame.chosen
        chosen.count = 3
        chosen.fields[1], chosen.fields[2], chosen.fields[3] = flag, name, score
        chosen.full[1], chosen.full[2], chosen.full[3] = 1, 0, 0
        frame.present[2][1], frame.present[2][2] = 0, 1
        frame.present[3][1], frame.present[3][2] = 1, 0
        local b = buffer.create(ROOM)
        local after = Sections.delta(of, b, AT, columns, prev)

        local reader = Sections.of(def)
        local kind, ends = Sections.taken(reader, b, AT, prev, CTX)
        Expect.equal(kind, Protocol.SECTION_DELTA)
        Expect.equal(ends, after)
        local back = reader.frame
        Expect.equal(back.count, 2)
        Expect.equal({ back.slots[1], back.slots[2] }, { 2, 5 })
        Expect.equal(back.chosen.count, 3)
        Expect.equal(
            { back.chosen.fields[1], back.chosen.fields[2], back.chosen.fields[3] },
            { 1, 2, 3 }
        )
        Expect.equal({ back.values[flag][1], back.values[flag][2] }, { true, false })
        Expect.equal(back.covered[2], 1)
        Expect.equal(back.under[2][1], 5)
        Expect.equal(back.values[name][1], "five")
        Expect.equal(back.covered[3], 1)
        Expect.equal(back.under[3][1], 2)
        Expect.equal(back.values[score][1], 500)
    end),

    -- A removal carries the slots and nothing else, a clear nothing but the header, and a keyed
    -- set names its partition after the header where `about` reads it without the rest.
    Harness.case("sections.removal-clear-and-about", function()
        local def = compiled({ team = Codecs.int(0, 3), hp = Codecs.int(0, 100) }, "team")
        local of = Sections.of(def)
        local frame = of.frame
        frame.key = 2
        frame.count = 2
        frame.slots[1], frame.slots[2] = 4, 6
        local b = buffer.create(ROOM)
        local after = Sections.removal(of, b, AT)
        Expect.equal(after, def.head.bytes + 1 + 3)

        local reader = Sections.of(def)
        local kind, ends = Sections.taken(reader, b, AT, partition(def), CTX)
        Expect.equal(kind, Protocol.SECTION_REMOVAL)
        Expect.equal(ends, after)
        Expect.equal(reader.frame.key, 2)
        Expect.equal({ reader.frame.slots[1], reader.frame.slots[2] }, { 4, 6 })
        Expect.equal({ Sections.about(reader, b, AT, CTX) }, { Protocol.SECTION_REMOVAL, 2 })

        frame.key = 3
        local cleared = Sections.clear(of, b, AT)
        Expect.equal(cleared, def.head.bytes + 1)
        kind, ends = Sections.taken(reader, b, AT, partition(def), CTX)
        Expect.equal({ kind, ends, reader.frame.key }, { Protocol.SECTION_CLEAR, cleared, 3 })
    end),

    -- What a layout says a section costs: the opening before any record and the entry per one.
    Harness.case("sections.costs", function()
        local def = compiled({ score = Codecs.int(0, 100), name = Codecs.str(0, 8) })
        local of = Sections.of(def)
        Expect.equal(of.opening, def.head.bytes + Protocol.VARINT_GROUPS + 1)
        Expect.equal(of.entry, Protocol.VARINT_GROUPS * 2 + 1 + 9)
        Expect.equal(of.each[def.fieldIndex.score], 1)
        Expect.equal(of.gained[def.fieldIndex.score], 1)

        local keyed =
            Sections.of(compiled({ team = Codecs.int(0, 3), big = Codecs.int(0, 2 ^ 20) }, "team"))
        Expect.equal(keyed.opening, keyed.def.head.bytes + 1 + Protocol.VARINT_GROUPS + 1)
        Expect.equal(keyed.gained[keyed.def.fieldIndex.big], Protocol.VARINT_GROUPS)
    end),
}
