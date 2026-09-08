--!strict
--!optimize 2
-- One field of a set across many records: the bytes a column becomes and what a reader turns away.

local Catalog = require("@src/kernel/Catalog")
local Column = require("@src/shape/emit/Column")
local Grid = require("@src/shape/Grid")
local Ir = require("@src/shape/Ir")
local Serial = require("@src/shape/Serial")
local Types = require("@src/Types")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")

local ROOM = 256
local WHERE = "Origin.field"
local SAID = "a run of bits"

-- A grid narrower than the bits carrying it, so two of its patterns are ones it has no point for,
-- and a step that makes its points other than the numbers handed to it.
local REACH = 5
local STEPPED = 0.5
local PAST = 0x0F
local HELD = table.freeze({ 1, 3, 5 })

local CTX: Types.ValidateContext = table.freeze({ player = nil, now = 0, last = nil })

local function tagged(): (Ir.Tag, Serial.Interner, Serial.Interner)
    local paths, expected = Serial.interner(), Serial.interner()
    local tag = {
        pathId = Serial.intern(paths, WHERE),
        expectId = Serial.intern(expected, `int(0,{REACH})`),
    }
    return tag, paths, expected
end

local function column(grid: Grid.Grid): (Column.Write, Column.Read)
    local tag, paths, expected = tagged()
    return Column.grid(tag, paths, expected, grid)
end

-- A column of the values held, and the buffer it went down in.
local function laid(): (buffer, Column.Read)
    local write, read = column(Grid.of(0, REACH, 1))
    local b = buffer.create(ROOM)
    write(b, 0, HELD :: any, {}, #HELD)
    return b, read
end

local function rejected(call: () -> ()): Catalog.Code?
    local ok, why = pcall(call)
    if ok or type(why) ~= "table" then return nil end
    return (why :: any).code
end

local function refused(read: Column.Read, b: buffer): Catalog.Code?
    return rejected(function()
        read(b, 0, {}, {}, #HELD, CTX)
    end)
end

-- One value's pair, for the columns that write a value at a time.
local function byteWise(): (Ir.Write, Ir.Read)
    local function write(b: buffer, pos: number, value: any): number
        buffer.writeu8(b, pos, value)
        return pos + 1
    end
    local function read(b: buffer, pos: number, _c: Types.ValidateContext): (number, any)
        return pos + 1, buffer.readu8(b, pos)
    end
    return write, read
end

return {
    Harness.case("column.round-trip", function()
        local b, read = laid()
        local into: { any } = {}
        read(b, 0, into, {}, #HELD, CTX)
        Expect.equal(into, HELD)

        -- A stepped grid goes back through its reading, and a whole one in a single move.
        local write, back = column(Grid.of(0, REACH, STEPPED))
        write(b, 0, { 0, 2.5, 5 } :: any, {}, 3)
        local out: { any } = {}
        back(b, 0, out, {}, 3, CTX)
        Expect.equal(out, { 0, 2.5, 5 })
        local whole, wholeBack = column(Grid.of(0, 7, 1))
        whole(b, 0, { 7, 0, 3 } :: any, {}, 3)
        wholeBack(b, 0, out, {}, 3, CTX)
        Expect.equal(out, { 7, 0, 3 })
    end),

    -- Three values of three bits leave seven bits over, and they have to be nothing.
    Harness.case("column.refuses-a-pad", function()
        local b, read = laid()
        buffer.writeu8(b, 1, bit32.bor(buffer.readu8(b, 1), 0x80))
        Expect.equal(refused(read, b), Catalog.PAD)
    end),

    -- Three bits carry eight patterns and the grid holds six.
    Harness.case("column.refuses-a-value-off-its-grid", function()
        local b, read = laid()
        buffer.writeu8(b, 0, 0x3F)
        Expect.equal(refused(read, b), Catalog.TAG)

        local write, stepped = column(Grid.of(0, REACH, STEPPED))
        write(b, 0, { 0, 1, 2 } :: any, {}, #HELD)
        buffer.writeu8(b, 0, PAST)
        Expect.equal(refused(stepped, b), Catalog.TAG)
    end),

    -- A value the grid cannot take is refused where it is written, naming the path and the value
    -- the grid stopped on, whether the grid took the run whole or a value at a time.
    Harness.case("column.refuses-writing-off-its-grid", function()
        for _, step in { 1, STEPPED } do
            local write = column(Grid.of(0, REACH, step))
            local said = Expect.throws(function()
                write(buffer.create(ROOM), 0, { 1, REACH + 4, 2 } :: any, {}, 3)
            end)
            Expect.holds(string.find(said, WHERE, 1, true) ~= nil, `it said {said}`)
            Expect.holds(string.find(said, `got {REACH + 4}`, 1, true) ~= nil, `it said {said}`)
        end
    end),

    -- A run of bare bits is still a run, and the bits over its last element are still nothing.
    Harness.case("column.bits", function()
        local write, read = Column.bits(3, SAID)
        local b = buffer.create(ROOM)
        write(b, 0, HELD :: any, {}, #HELD)
        local into: { any } = {}
        read(b, 0, into, {}, #HELD, CTX)
        Expect.equal(into, HELD)

        buffer.writeu8(b, 1, bit32.bor(buffer.readu8(b, 1), 0x80))
        local ok, why = pcall(read, b, 0, {}, {}, #HELD, CTX)
        Expect.holds(not ok, "a run of bits padded with ones was taken rather than refused")
        Expect.equal((why :: any).code, Catalog.SECTION)
        Expect.equal((why :: any).facts.said, SAID)
    end),

    -- A field written a value at a time, stating its indices beside where it has a grid.
    Harness.case("column.each", function()
        local writeOne, readOne = byteWise()
        local write, read = Column.each(writeOne, readOne, nil)
        local b = buffer.create(ROOM)
        Expect.equal(write(b, 0, { 9, 8, 7 }, {}, 3), 3)
        local into: { any }, at: { number } = {}, {}
        Expect.equal(read(b, 0, into, at, 3, CTX), 3)
        Expect.equal(into, { 9, 8, 7 })
        Expect.equal(at, {})

        local stated, statedBack = Column.each(writeOne, readOne, Grid.of(0, 20, 2))
        stated(b, 0, { 4, 10, 20 }, at, 3)
        Expect.equal(at, { 2, 5, 10 })
        local back: { any }, seen: { number } = {}, {}
        statedBack(b, 0, back, seen, 3, CTX)
        Expect.equal(back, { 4, 10, 20 })
        Expect.equal(seen, { 2, 5, 10 })
    end),

    -- A gain carries the step from what a record last held. A value off the grid is refused where
    -- it is written, and a step that lands past the grid is turned away where it is read.
    Harness.case("column.refuses-a-gain-off-its-grid", function()
        local tag, paths, expected = tagged()
        local gain, regain = Column.gain(tag, paths, expected, Grid.of(0, REACH, 1), true)
        local slots = { 1, 2, 3 }
        local was = { [1] = 1, [2] = 1, [3] = 1 }
        local b = buffer.create(ROOM)

        local said = Expect.throws(function()
            gain(b, 0, { 1, REACH + 4, 2 } :: any, slots, was, {}, 3)
        end)
        Expect.holds(string.find(said, WHERE, 1, true) ~= nil, `it said {said}`)

        gain(b, 0, { 2, 3, 4 } :: any, slots, was, {}, 3)
        local into: { any } = {}
        regain(b, 0, into, slots, was, {}, 3)
        Expect.equal(into, { 2, 3, 4 })
        Expect.equal(
            rejected(function()
                regain(b, 0, {}, slots, { [1] = REACH, [2] = REACH, [3] = REACH }, {}, 3)
            end),
            Catalog.TAG
        )

        -- A varint that never ends is a drop of its own.
        buffer.fill(b, 0, 0xFF)
        Expect.equal(
            rejected(function()
                regain(b, 0, {}, slots, was, {}, 3)
            end),
            Catalog.VARINT
        )
    end),

    -- A step is written for every slot the sender named, and only the ones this side holds a
    -- baseline for come back as values.
    Harness.case("column.gain-leaves-a-slot-it-does-not-hold", function()
        local tag, paths, expected = tagged()
        local gain, regain = Column.gain(tag, paths, expected, Grid.of(0, REACH, STEPPED), true)
        local slots = { 1, 2, 3 }
        local b = buffer.create(ROOM)
        local whole = { [1] = 1, [2] = 1, [3] = 1 }
        gain(b, 0, { 0.5, 1, 1.5 } :: any, slots, whole, {}, #slots)

        local part = { [1] = 1, [3] = 1 }
        local into: { any } = {}
        regain(b, 0, into, slots, part, {}, #slots)
        Expect.equal(into, { [1] = 0.5, [3] = 1.5 })

        into = {}
        regain(b, 0, into, slots, whole, {}, #slots)
        Expect.equal(into, { 0.5, 1, 1.5 })
    end),

    -- On a grid that wraps a signed gain takes the short way round, and an unsigned one counts up.
    Harness.case("column.gain-wraps", function()
        local tag, paths, expected = tagged()
        local turn = Grid.of(0, 359, 1, true)
        local signed, back = Column.gain(tag, paths, expected, turn, true)
        local slots = { 1, 2 }
        local was = { [1] = 350, [2] = 10 }
        local b = buffer.create(ROOM)
        local after = signed(b, 0, { 5, 355 } :: any, slots, was, {}, 2)
        Expect.equal(after, 2)
        local into: { any } = {}
        back(b, 0, into, slots, was, {}, 2)
        Expect.equal(into, { 5, 355 })

        local counted, count = Column.gain(tag, paths, expected, turn, false)
        counted(b, 0, { 5, 355 } :: any, slots, was, {}, 2)
        count(b, 0, into, slots, was, {}, 2)
        Expect.equal(into, { 5, 355 })
    end),
}
