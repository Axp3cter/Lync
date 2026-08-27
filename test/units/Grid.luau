--!strict
--!optimize 2
--[[
    The quantization grid alone: the index a value lands on, and the value an index answers.
]]

local Grid = require ("@src/shape/Grid")
local Scalars = require ("@src/codec/Scalars")

local Expect = require ("@test/harness/Expect")
local Harness = require ("@test/harness")
local Rng = require ("@test/harness/Rng")

-- Constants -----------------------------------------------------------

--[[
    Steps a drawn grid is laid on. The last three leave a remainder in a whole range, which is the
    shape the codec fuzzers never draw: their steps all divide a whole number of units, so their
    grids always end on a grid point. A range with a remainder is where the top rounds past the last
    index the wire has room for.
]]
const STEPS = table.freeze ({ 1, 0.5, 0.25, 0.1, 0.05, 0.3, 3, 7 })

--[[
    Steps a drawn cyclic grid is laid on, each dividing the turn. That is the shape the angle codec
    asks for, and the turn is the only thing it brings.
]]
const DEGREES = table.freeze ({ 90, 10, 5, 1, 0.5 })
const TURN = Scalars.TURN

-- How far a drawn grid's ends sit from zero, and how far past one a value may.
const MOST = 1000
const TURNS = 3

-- The widest range a drawn grid takes when it is drawn narrow.
const NARROW = 4

--[[
    The margin two distances may differ by and still count as a tie. Two grid points either side of
    a midpoint are the same distance from it only in exact arithmetic. A fault here is a whole step
    wide, so nothing a rounding can do reaches this margin and nothing this margin hides is a fault.
]]
const TINY = 1e-6

-- Types ---------------------------------------------------------------

type Laid = {
    grid: Grid.Grid,
    min: number,
    max: number,
    step: number,
    wraps: boolean,
}

-- Private -------------------------------------------------------------

-- Whether the first distance is no greater than the second, ties allowed.
local function within (chosen: number, other: number, step: number): boolean
    return chosen <= other + step * TINY
end

--[[
    A grid, and the numbers it was laid from, because a case cannot ask a grid what it was built
    with. Cyclic ones come in the angle codec's shape, since that is the only cyclic grid the
    library builds.
]]
local function laid (rng: Rng.Rng): Laid
    if Rng.bool (rng) then
        local step = Rng.pick (rng, DEGREES)
        local max = TURN - step
        return {
            grid = Grid.of (0, max, step, true),
            min = 0,
            max = max,
            step = step,
            wraps = true,
        }
    end

    local step = Rng.pick (rng, STEPS)
    local min = Rng.int (rng, -MOST, MOST)

    --[[
        Narrow as often as wide, because a range of none is a legal grid of one point costing no
        bits, and a uniform draw over a thousand reaches it about never.
    ]]
    local reach = if Rng.bool (rng) then NARROW else MOST
    local max = min + Rng.int (rng, 0, reach)

    return { grid = Grid.of (min, max, step), min = min, max = max, step = step, wraps = false }
end

--[[
    A value inside a grid, landing on an end or on the midpoint between two points as often as
    anywhere between. A uniform draw across a span of forty thousand lands on a midpoint about
    never, and a midpoint is the only place the rounding is decided.
]]
local function inside (rng: Rng.Rng, of: Laid): number
    local span = of.grid.span

    local pick = Rng.int (rng, 0, 3)
    if pick == 0 then return of.min end
    if pick == 1 then return of.max end
    if pick == 2 and span > 0 then
        local point = Rng.int (rng, 0, span - 1)
        return of.min + (point + 0.5) * of.step
    end
    return Rng.number (rng, of.min, of.max)
end

-- Public --------------------------------------------------------------

return {
    --[[
        What a grid answers about itself, which is a last index and the bits that carry it. The two
        together are why a decoder rejects an index it can read: eight bits hold indices a span of
        two hundred does not.
    ]]
    Harness.case ("grid.shape", function ()
        local byte = Grid.of (0, 255, 1)
        Expect.equal (byte.span, 255)
        Expect.equal (byte.width, 8)

        local past = Grid.of (0, 256, 1)
        Expect.equal (past.span, 256)
        Expect.equal (past.width, 9)

        local fine = Grid.of (-512, 512, 0.1)
        Expect.equal (fine.span, 10240)
        Expect.equal (fine.width, 14)

        -- A range the step does not divide, which is the shape the two numbers are read on.
        local partial = Grid.of (0, 10, 4)
        Expect.equal (partial.span, 2)
        Expect.equal (partial.width, 2)

        local single = Grid.of (5, 5, 1)
        Expect.equal (single.span, 0)
        Expect.equal (single.width, 0)
    end),

    --[[
        The ends. The bottom is index none and the top is the last index, and the top is the one
        worth asking: a range with a remainder is the shape where the two could differ, and an
        index past the span is a field the decoder rejects.
    ]]
    Harness.case ("grid.ends", function ()
        local whole = Grid.of (-512, 512, 0.1)
        Expect.equal (whole.toIndex (-512), 0)
        Expect.equal (whole.toIndex (512), whole.span)
        Expect.equal (whole.fromIndex (0), -512)
        Expect.equal (whole.fromIndex (whole.span), 512)

        -- A range with a remainder, where the top of it is not a point the grid has.
        local partial = Grid.of (0, 10, 4)
        Expect.equal (partial.toIndex (0), 0)
        Expect.equal (partial.toIndex (10), 2)
        Expect.equal (partial.fromIndex (2), 8)

        local single = Grid.of (5, 5, 1)
        Expect.equal (single.toIndex (5), 0)
        Expect.equal (single.fromIndex (0), 5)
    end),

    --[[
        Where one index gives way to the next. A value on a point answers that point's index, one
        either side of a midpoint answers the point it is nearer, and one exactly on a midpoint
        rounds up. The last is asked because it is the only one a reasonable grid could answer
        either way.
    ]]
    Harness.case ("grid.rounds", function ()
        local ones = Grid.of (0, 10, 1)
        Expect.equal (ones.toIndex (3), 3)
        Expect.equal (ones.toIndex (3.4), 3)
        Expect.equal (ones.toIndex (3.5), 4)
        Expect.equal (ones.toIndex (3.6), 4)

        local quarters = Grid.of (-1, 1, 0.25)
        Expect.equal (quarters.toIndex (-1), 0)
        Expect.equal (quarters.toIndex (-0.875), 1)
        Expect.equal (quarters.toIndex (-0.8), 1)
        Expect.equal (quarters.toIndex (0), 4)
        Expect.equal (quarters.toIndex (0.125), 5)
    end),

    --[[
        A value the grid has no index for: below the bottom, above the top, and the three readings
        that are no place at all. A pair of comparisons rejects them all, since a comparison
        against NaN is false either way where two rejections would let it through both.
    ]]
    Harness.case ("grid.outside", function ()
        local grid = Grid.of (0, 100, 0.5)

        Expect.equal (grid.toIndex (-0.001), nil)
        Expect.equal (grid.toIndex (100.001), nil)
        Expect.equal (grid.toIndex (0 / 0), nil)
        Expect.equal (grid.toIndex (math.huge), nil)
        Expect.equal (grid.toIndex (-math.huge), nil)

        -- And the ends themselves are inside.
        Expect.equal (grid.toIndex (0), 0)
        Expect.equal (grid.toIndex (100), grid.span)

        --[[
            A cyclic grid takes every place on the line, and the three readings that are no place
            are no place on a ring either. Nothing above reaches this: a value outside a cyclic grid
            is a lap rather than a fault, so the test that catches these on a plain grid is not one
            a cyclic grid performs, and an index of NaN would reach the emitter.
        ]]
        local ring = Grid.of (0, TURN - 1, 1, true)
        Expect.equal (ring.toIndex (0 / 0), nil)
        Expect.equal (ring.toIndex (math.huge), nil)
        Expect.equal (ring.toIndex (-math.huge), nil)
        Expect.equal (ring.toIndex (TURN * 5 + 90), 90)
    end),

    --[[
        A cyclic grid takes every value there is. Past the top it comes round to the bottom, below
        the bottom it comes round to the top, and a whole turn either way changes nothing. That is
        the one thing an angle needs and the one thing a plain grid must not do, since a position
        past its bounds is a caller's mistake rather than a lap.
    ]]
    Harness.case ("grid.wraps", function ()
        local step = 1
        local grid = Grid.of (0, TURN - step, step, true)
        Expect.equal (grid.wrap, true)
        Expect.equal (grid.span, TURN - 1)

        Expect.equal (grid.toIndex (0), 0)
        Expect.equal (grid.toIndex (90), 90)
        Expect.equal (grid.toIndex (TURN - 1), TURN - 1)

        Expect.equal (grid.toIndex (TURN), 0)
        Expect.equal (grid.toIndex (TURN + 90), 90)
        Expect.equal (grid.toIndex (-90), TURN - 90)
        Expect.equal (grid.toIndex (-TURN), 0)

        -- Half a step short of the turn rounds up to it, which is the bottom.
        Expect.equal (grid.toIndex (TURN - 0.5), 0)

        --[[
            And half a step below the bottom comes round to the top the same way. The pair is
            what says the turn is taken out of the value and not out of the index, since a grid
            that reduced afterwards would answer this one a point short and the one above it
            correctly.
        ]]
        Expect.equal (grid.toIndex (-0.5), 0)
        Expect.equal (grid.toIndex (-1.5), TURN - 1)

        local plain = Grid.of (0, TURN - step, step)
        Expect.equal (plain.wrap, nil)
        Expect.equal (plain.toIndex (TURN), nil)
        Expect.equal (plain.toIndex (-90), nil)
    end),

    --[[
        Every index answers a value that answers it back. This is what the state engine rests on: a
        field's delta is the difference of two indices and a newest stream suppresses on index
        equality, so a point that did not index back to itself would send a record that never
        settles.
    ]]
    Harness.case ("grid.indices", function ()
        local grids = { Grid.of (-512, 512, 0.1), Grid.of (0, 10, 4), Grid.of (0, 359, 1, true) }
        for _, grid in grids do
            for index = 0, grid.span do
                if grid.toIndex (grid.fromIndex (index)) == index then continue end
                Expect.holds (false, `{grid.fromIndex (index)} did not index back to {index}`)
            end
        end
    end),

    --[[
        Every value on every grid, checked against the points either side rather than against the
        rounding that produced it: no point the grid has lies nearer than the one it chose. On an
        evenly spaced grid that settles it and says nothing about how the index was computed.
    ]]
    Harness.property ("grid.nearest", "leaves", function (rng: Rng.Rng)
        local of = laid (rng)
        local grid = of.grid
        local value = inside (rng, of)

        if of.wraps then
            local index = grid.toIndex (value)
            Expect.holds (index ~= nil, `a cyclic grid refused {value}`)

            local turns = Rng.int (rng, -TURNS, TURNS)
            Expect.equal (grid.toIndex (value + turns * TURN), index)
            return
        end

        local index = grid.toIndex (value)
        Expect.holds (index ~= nil, `{value} is inside the grid and had no index`)

        local at = index :: number
        Expect.holds (
            at >= 0 and at <= grid.span and at % 1 == 0,
            `{value} indexed {at} on a span of {grid.span}`
        )

        local chosen = math.abs (grid.fromIndex (at) - value)
        for _, other in { at - 1, at + 1 } do
            if other < 0 or other > grid.span then continue end

            local away = math.abs (grid.fromIndex (other) - value)
            Expect.holds (within (chosen, away, of.step), `{other} sits nearer {value} than {at}`)
        end
    end),

    --[[
        How many steps a span holds, counted rather than divided. A tenth is not a tenth in a
        double, so a span of three tenths divides to a shade under three and a division believed
        answers two, which is a grid one point short of what a caller declared.
    ]]
    Harness.case ("grid.counts-its-steps", function ()
        Expect.equal (Grid.of (0, 0.3, 0.1).span, 3)
        Expect.equal (Grid.of (0, 1, 0.1).span, 10)
        Expect.equal (Grid.of (0, TURN, 0.1).span, TURN * 10)
    end),

    --[[
        The hair a count is taken within, which has to be wide enough to close the gap a tenth
        leaves and narrow enough not to close a real one. A span stopping a hair short of three
        holds two steps and not three, however near the third it came.
    ]]
    Harness.case ("grid.counts-within-a-hair", function ()
        Expect.equal (Grid.of (0, 2.999999, 1).span, 2)
        Expect.equal (Grid.of (0, 3, 1).span, 3)
    end),

    --[[
        A reading a hair under the bottom, which is a value a caller measured rather than one they
        made up. Rounding it up onto the first point is what the room below the bottom is for, and
        a grid without it turns away a number that is the bottom for every purpose but a compare.
    ]]
    Harness.case ("grid.takes-a-hair-under-its-bottom", function ()
        local of = Grid.of (0, 4, 1)

        -- Compared rather than equated, since rounding a number under nothing answers a signed one.
        Expect.holds (of.toIndex (-1e-15) == 0, "a hair under the bottom is off the first point")
        Expect.equal (of.toIndex (4 + 1e-15), 4)
        Expect.equal (of.toIndex (-1), nil)
    end),

    --[[
        The pair for a reading that sits a hair past an end, which the grid takes rather than
        refuses. A search over neighbours spends the pair as it comes, so neither half may name a
        point the wire carries no index for.
    ]]
    Harness.case ("grid.a-window-off-an-end-holds-onto-it", function ()
        local of = Grid.of (-1, 1, 0.25)
        local window = of.window
        Expect.holds (window ~= nil, "a stepped grid offered no window")

        local reach = window :: (any) -> (number?, number?, number, number)
        for _, value in { -1 - TINY, -1, 0, 1, 1 + TINY } do
            local first, second = reach (value)

            Expect.holds (first ~= nil, `a reading at {value} was left with no pair`)
            Expect.holds (
                first :: number >= 0 and first :: number <= of.span,
                `the low half of {value} is {first}, which is off the grid`
            )
            Expect.holds (
                second :: number >= 0 and second :: number <= of.span,
                `the high half of {value} is {second}, which is off the grid`
            )
        end
    end),

    --[[
        The slack a reading is allowed is the range against a hair, or half a step, whichever is
        less. A range wide enough to make it the whole half lets a value reach a half past either
        end, which rounds off the grid and has to be held back onto it.
    ]]
    Harness.case ("grid.holds-a-wide-range-onto-its-ends", function ()
        local of = Grid.of (0, 1048576, 1)

        Expect.equal (of.toIndex (-0.5), 0)
        Expect.equal (of.toIndex (1048576.5), 1048576)
        Expect.equal (of.toIndex (-0.5 - 1e-9), nil)
        Expect.equal (of.toIndex (1048576.5 + 1e-9), nil)
    end),

    -- A range too narrow for that keeps the slack well under a half, so nothing reaches an end.
    Harness.case ("grid.a-narrow-range-never-reaches-its-ends", function ()
        local of = Grid.of (0, 4, 1)

        Expect.equal (of.toIndex (-0.5), nil)
        Expect.equal (of.toIndex (4.5), nil)
    end),

    -- A flag, which is two points and so one step between them.
    Harness.case ("grid.a-flag-spans-one", function ()
        local of = Grid.flag ()

        Expect.equal (of.span, 1)
        Expect.equal (of.width, 1)
    end),
}
