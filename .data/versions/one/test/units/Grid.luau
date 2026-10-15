--!strict
--!optimize 2
-- The quantization grid alone: the index a value lands on, and the value an index answers.

local Grid = require("@src/shape/Grid")
local Scalars = require("@src/codec/Scalars")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")
local Rng = require("@test/harness/Rng")

-- Steps a drawn grid is laid on. The last three leave a remainder in a whole range, where the top
-- rounds past the last index the wire has room for.
local STEPS = table.freeze({ 1, 0.5, 0.25, 0.1, 0.05, 0.3, 3, 7 })

-- Steps a drawn cyclic grid is laid on, each dividing the turn.
local DEGREES = table.freeze({ 90, 10, 5, 1, 0.5 })
local TURN = Scalars.TURN

local MOST = 1000
local TURNS = 3
local NARROW = 4

-- The margin two distances may differ by and still count as a tie.
local TINY = 1e-6

-- The slack a grid allows past either end: a millionth of the range or so, per unit of range,
-- as the grid itself reckons it, and the float step that lands just past it.
local ROOM = 2 * 2 ^ -20
local PAST = 2 ^ -30

type Laid = { grid: Grid.Grid, min: number, max: number, step: number, wraps: boolean }

local function within(chosen: number, other: number, step: number): boolean
    return chosen <= other + step * TINY
end

-- A grid and the numbers it was laid from. Cyclic ones come in the angle codec's shape.
local function laid(rng: Rng.Rng): Laid
    if rng:bool() then
        local step = rng:pick(DEGREES)
        local max = TURN - step
        return { grid = Grid.of(0, max, step, true), min = 0, max = max, step = step, wraps = true }
    end

    local step = rng:pick(STEPS)
    local min = rng:int(-MOST, MOST)
    local reach = if rng:bool() then NARROW else MOST
    local max = min + rng:int(0, reach)
    return { grid = Grid.of(min, max, step), min = min, max = max, step = step, wraps = false }
end

-- A value inside a grid, on an end or a midpoint as often as anywhere between.
local function inside(rng: Rng.Rng, of: Laid): number
    local span = of.grid.span
    local pick = rng:int(0, 3)
    if pick == 0 then return of.min end
    if pick == 1 then return of.max end
    if pick == 2 and span > 0 then return of.min + (rng:int(0, span - 1) + 0.5) * of.step end
    return rng:number(of.min, of.max)
end

return {
    -- A last index and the bits that carry it: eight bits hold indices a span of two hundred lacks.
    Harness.case("grid.shape", function()
        local byte = Grid.of(0, 255, 1)
        Expect.equal(byte.span, 255)
        Expect.equal(byte.width, 8)
        Expect.equal(byte.whole, true)

        local past = Grid.of(0, 256, 1)
        Expect.equal(past.span, 256)
        Expect.equal(past.width, 9)
        Expect.equal(past.whole, false)

        local fine = Grid.of(-512, 512, 0.1)
        Expect.equal(fine.span, 10240)
        Expect.equal(fine.width, 14)

        local partial = Grid.of(0, 10, 4)
        Expect.equal(partial.span, 2)
        Expect.equal(partial.width, 2)

        local single = Grid.of(5, 5, 1)
        Expect.equal(single.span, 0)
        Expect.equal(single.width, 0)
    end),

    Harness.case("grid.ends", function()
        local whole = Grid.of(-512, 512, 0.1)
        Expect.equal(whole.toIndex(-512), 0)
        Expect.equal(whole.toIndex(512), whole.span)
        Expect.equal(whole.fromIndex(0), -512)
        Expect.equal(whole.fromIndex(whole.span), 512)

        local partial = Grid.of(0, 10, 4)
        Expect.equal(partial.toIndex(0), 0)
        Expect.equal(partial.toIndex(10), 2)
        Expect.equal(partial.fromIndex(2), 8)

        local single = Grid.of(5, 5, 1)
        Expect.equal(single.toIndex(5), 0)
        Expect.equal(single.fromIndex(0), 5)
    end),

    -- A value on a midpoint rounds up, the one place a reasonable grid could answer either way.
    Harness.case("grid.rounds", function()
        local ones = Grid.of(0, 10, 1)
        Expect.equal(ones.toIndex(3), 3)
        Expect.equal(ones.toIndex(3.4), 3)
        Expect.equal(ones.toIndex(3.5), 4)
        Expect.equal(ones.toIndex(3.6), 4)

        local quarters = Grid.of(-1, 1, 0.25)
        Expect.equal(quarters.toIndex(-1), 0)
        Expect.equal(quarters.toIndex(-0.875), 1)
        Expect.equal(quarters.toIndex(-0.8), 1)
        Expect.equal(quarters.toIndex(0), 4)
        Expect.equal(quarters.toIndex(0.125), 5)
    end),

    -- A pair of comparisons rejects the three readings that are no place, on a ring too.
    Harness.case("grid.outside", function()
        local grid = Grid.of(0, 100, 0.5)
        Expect.equal(grid.toIndex(-0.001), nil)
        Expect.equal(grid.toIndex(100.001), nil)
        Expect.equal(grid.toIndex(0 / 0), nil)
        Expect.equal(grid.toIndex(math.huge), nil)
        Expect.equal(grid.toIndex(-math.huge), nil)
        Expect.equal(grid.toIndex("5" :: any), nil)
        Expect.equal(grid.toIndex(0), 0)
        Expect.equal(grid.toIndex(100), grid.span)

        local ring = Grid.of(0, TURN - 1, 1, true)
        Expect.equal(ring.toIndex(0 / 0), nil)
        Expect.equal(ring.toIndex(math.huge), nil)
        Expect.equal(ring.toIndex(-math.huge), nil)
        Expect.equal(ring.toIndex(TURN * 5 + 90), 90)
    end),

    -- A cyclic grid takes every value there is, and the turn is taken out of the value, not the
    -- index, so half a step below the bottom comes round to the top.
    Harness.case("grid.wraps", function()
        local step = 1
        local grid = Grid.of(0, TURN - step, step, true)
        Expect.equal(grid.wrap, true)
        Expect.equal(grid.span, TURN - 1)

        Expect.equal(grid.toIndex(0), 0)
        Expect.equal(grid.toIndex(90), 90)
        Expect.equal(grid.toIndex(TURN - 1), TURN - 1)
        Expect.equal(grid.toIndex(TURN), 0)
        Expect.equal(grid.toIndex(TURN + 90), 90)
        Expect.equal(grid.toIndex(-90), TURN - 90)
        Expect.equal(grid.toIndex(-TURN), 0)
        Expect.equal(grid.toIndex(TURN - 0.5), 0)
        Expect.equal(grid.toIndex(-0.5), 0)
        Expect.equal(grid.toIndex(-1.5), TURN - 1)

        local plain = Grid.of(0, TURN - step, step)
        Expect.equal(plain.wrap, nil)
        Expect.equal(plain.toIndex(TURN), nil)
        Expect.equal(plain.toIndex(-90), nil)
    end),

    -- Every index answers a value that answers it back, which a delta and a newest stream rest on.
    Harness.case("grid.indices", function()
        for _, grid in { Grid.of(-512, 512, 0.1), Grid.of(0, 10, 4), Grid.of(0, 359, 1, true) } do
            for index = 0, grid.span do
                if grid.toIndex(grid.fromIndex(index)) == index then continue end
                Expect.holds(false, `{grid.fromIndex(index)} did not index back to {index}`)
            end
        end
    end),

    -- No point the grid has lies nearer than the one it chose.
    Harness.property("grid.nearest", "leaves", function(rng: Rng.Rng)
        local of = laid(rng)
        local grid = of.grid
        local value = inside(rng, of)

        if of.wraps then
            local index = grid.toIndex(value)
            Expect.holds(index ~= nil, `a cyclic grid refused {value}`)
            Expect.equal(grid.toIndex(value + rng:int(-TURNS, TURNS) * TURN), index)
            return
        end

        local index = grid.toIndex(value)
        Expect.holds(index ~= nil, `{value} is inside the grid and had no index`)
        local at = index :: number
        Expect.holds(at >= 0 and at <= grid.span and at % 1 == 0, `{value} indexed {at}`)

        local chosen = math.abs(grid.fromIndex(at) - value)
        for _, other in { at - 1, at + 1 } do
            if other < 0 or other > grid.span then continue end
            local away = math.abs(grid.fromIndex(other) - value)
            Expect.holds(within(chosen, away, of.step), `{other} sits nearer {value} than {at}`)
        end
    end),

    -- A tenth is not a tenth in a double, so a span of three tenths is counted rather than divided.
    Harness.case("grid.counts-its-steps", function()
        Expect.equal(Grid.of(0, 0.3, 0.1).span, 3)
        Expect.equal(Grid.of(0, 1, 0.1).span, 10)
        Expect.equal(Grid.of(0, TURN, 0.1).span, TURN * 10)
    end),

    Harness.case("grid.counts-within-a-hair", function()
        Expect.equal(Grid.of(0, 2.999999, 1).span, 2)
        Expect.equal(Grid.of(0, 3, 1).span, 3)
    end),

    -- A reading a hair under the bottom is a value a caller measured, and rounds onto the first
    -- point.
    Harness.case("grid.takes-a-hair-under-its-bottom", function()
        local of = Grid.of(0, 4, 1)
        Expect.holds(of.toIndex(-1e-15) == 0, "a hair under the bottom is off the first point")
        Expect.equal(of.toIndex(4 + 1e-15), 4)
        Expect.equal(of.toIndex(-1), nil)
    end),

    -- The slack past either end is inside the grid to its last float, and one float past it is
    -- outside, for a reading and for a window alike.
    Harness.case("grid.slack-ends-are-inside", function()
        local of = Grid.of(-1, 1, 0.25)
        local window = of.window :: (any) -> (number?, number, number, number)
        local under, over = -1 - ROOM, 1 + ROOM
        Expect.equal(of.toIndex(under), 0)
        Expect.equal(of.toIndex(over), of.span)
        Expect.equal((window(under)), 0)
        Expect.equal((window(over)), of.span)
        Expect.equal(of.toIndex(under - PAST), nil)
        Expect.equal(of.toIndex(over + PAST), nil)
        Expect.equal((window(under - PAST)), nil)
        Expect.equal((window(over + PAST)), nil)

        local whole = Grid.of(0, 10, 1)
        Expect.equal(whole.toIndex(-ROOM * 5), 0)
        Expect.equal(whole.toIndex(10 + ROOM * 5), 10)
        Expect.equal(whole.toIndex(-ROOM * 5 - PAST), nil)
        Expect.equal(whole.toIndex(10 + ROOM * 5 + PAST), nil)
    end),

    -- Neither half of a window may name a point the wire carries no index for.
    Harness.case("grid.a-window-off-an-end-holds-onto-it", function()
        local of = Grid.of(-1, 1, 0.25)
        local window = of.window :: (any) -> (number?, number, number, number)
        Expect.holds(window ~= nil, "a stepped grid offered no window")

        for _, value in { -1 - TINY, -1, 0, 1, 1 + TINY } do
            local first, second, low, high = window(value)
            Expect.holds(first ~= nil, `a reading at {value} was left with no pair`)
            local at = first :: number
            Expect.holds(at >= 0 and at <= of.span, `the low half of {value} is {at}`)
            Expect.holds(second >= 0 and second <= of.span, `the high half of {value} is {second}`)
            Expect.equal(low, of.fromIndex(at))
            Expect.equal(high, of.fromIndex(second))
            Expect.holds(second == at or second == at + 1, "the pair is not adjacent")
        end
        Expect.equal((window(0.3)), 5)
        Expect.equal((window("x" :: any)), nil)
    end),

    -- The slack is the range against a hair or half a step, whichever is less.
    Harness.case("grid.holds-a-wide-range-onto-its-ends", function()
        local of = Grid.of(0, 1048576, 1)
        Expect.equal(of.toIndex(-0.5), 0)
        Expect.equal(of.toIndex(1048576.5), 1048576)
        Expect.equal(of.toIndex(-0.5 - 1e-9), nil)
        Expect.equal(of.toIndex(1048576.5 + 1e-9), nil)
    end),

    Harness.case("grid.a-narrow-range-never-reaches-its-ends", function()
        local of = Grid.of(0, 4, 1)
        Expect.equal(of.toIndex(-0.5), nil)
        Expect.equal(of.toIndex(4.5), nil)
    end),

    -- A run turned at once answers as the one-at-a-time form does, and names the first bad place.
    Harness.case("grid.runs", function()
        local plain = Grid.of(0, 100, 1)
        local into = {}
        local toIndices = plain.toIndices :: ({ any }, { number }, number) -> number?
        Expect.equal(toIndices({ 0, 3.4, 100, 50.5 }, into, 4), nil)
        Expect.equal(into, { 0, 3, 100, 51 })
        Expect.equal(toIndices({ 0, 101, 2 }, into, 3), 2)
        Expect.equal(toIndices({ 0, "1" :: any }, into, 2), 2)

        local stepped = Grid.of(-1, 1, 0.5)
        local back = {}
        local fromIndices = stepped.fromIndices :: ({ number }, { any }, number) -> ()
        fromIndices({ 0, 2, 4 }, back, 3)
        Expect.equal(back, { -1, 0, 1 })
        Expect.equal(stepped.toIndices, nil)

        local flag = Grid.flag()
        local bits = {}
        Expect.equal((flag.toIndices :: any)({ true, false, true }, bits, 3), nil)
        Expect.equal(bits, { 1, 0, 1 })
        Expect.equal((flag.toIndices :: any)({ true, 1 }, bits, 2), 2)
        local flags = {}
        local fromFlags = flag.fromIndices :: any
        fromFlags({ 1, 0 }, flags, 2)
        Expect.equal(flags, { true, false })
    end),

    Harness.case("grid.a-flag-spans-one", function()
        local of = Grid.flag()
        Expect.equal(of.span, 1)
        Expect.equal(of.width, 1)
        Expect.equal(of.whole, true)
        Expect.equal(of.toIndex(true), 1)
        Expect.equal(of.toIndex(false), 0)
        Expect.equal(of.toIndex(1), nil)
        Expect.equal(of.fromIndex(1), true)
    end),

    -- The named, index, plane, chord, channel and divides forms, each read at its ends.
    Harness.case("grid.derived-forms", function()
        local named = Grid.named({ "a", "b", "c" })
        Expect.equal(named.span, 2)
        Expect.equal(named.width, 2)
        Expect.equal(named.whole, false)
        Expect.equal(named.toIndex("b"), 1)
        Expect.equal(named.toIndex("z"), nil)
        Expect.equal(named.fromIndex(2), "c")

        local index = Grid.index(4)
        Expect.equal(index.span, 3)
        Expect.equal(index.whole, true)

        local plane = Grid.plane(1)
        Expect.equal(plane.span, 180)
        Expect.equal(plane.toIndex(-1), 0)
        Expect.equal(plane.toIndex(1), 180)

        local chord = Grid.chord(1)
        Expect.equal(chord.span, 180)

        local channel = Grid.channel(5)
        Expect.equal(channel.span, 31)
        Expect.equal(channel.toIndex(1), 31)

        Expect.equal(Grid.divides(TURN, 0.1), true)
        Expect.equal(Grid.divides(TURN, 7), false)
    end),
}
