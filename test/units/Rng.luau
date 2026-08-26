--!strict
--!optimize 2
--[[
    The seeded generator held to varying, which every drawn case in every tree assumes it does.
]]

local Expect = require ("@test/harness/Expect")
local Harness = require ("@test/harness")
local Rng = require ("@test/harness/Rng")

-- Constants -----------------------------------------------------------

--[[
    Draws a check takes before reading what came out. Enough that a span of ten is covered many
    times over by chance, so a run that misses one is a generator that cannot reach it rather than
    one that did not get round to it.
]]
const DRAWS = 400

-- A span small enough to be covered and wide enough that covering it is not an accident.
const LOW = 1
const HIGH = 10

-- Seeds, fixed so a failure is the generator changing rather than a run being unlucky.
const SEED = 20260825
const OTHER = 99999

-- What a shuffle is asked of, long enough that one ordering out of its permutations is unlikely.
const LONG = 12

-- Bytes a draw is asked for.
const BYTES = 32

-- Private -------------------------------------------------------------

-- Every value a call answered over the draws above, as the set of them and the order they came in.
local function drawn (call: (Rng.Rng) -> number, seed: number?): ({ [number]: boolean }, { number })
    local of = Rng.new (seed or SEED)
    local seen: { [number]: boolean } = {}
    local order: { number } = {}

    for _ = 1, DRAWS do
        local value = call (of)
        seen[value] = true
        table.insert (order, value)
    end
    return seen, order
end

-- A list of known values, which a shuffle has to answer with the same of and no more.
local function counted (list: { number }): { [number]: number }
    local held: { [number]: number } = {}
    for _, value in list do
        held[value] = (held[value] or 0) + 1
    end
    return held
end

-- Public --------------------------------------------------------------

return {
    --[[
        The claim every budget in the register rests on: a span is covered rather than sampled at
        one end. A generator answering its low bound forever passes every property there is.
    ]]
    Harness.case ("rng.int-covers-its-span", function ()
        local seen = drawn (function (of) return Rng.int (of, LOW, HIGH) end)

        for value = LOW, HIGH do
            Expect.holds (seen[value] == true, `{DRAWS} draws never answered {value}`)
        end
    end),

    -- And never outside it, which is the other half of a bound meaning anything.
    Harness.case ("rng.int-stays-in-bounds", function ()
        local _, order = drawn (function (of) return Rng.int (of, LOW, HIGH) end)

        for _, value in order do
            Expect.holds (value >= LOW and value <= HIGH, `a draw answered {value}`)
            Expect.holds (value % 1 == 0, `a draw answered {value}, which is not whole`)
        end
    end),

    -- A span of one, which has one answer and must not reach for a word to find it.
    Harness.case ("rng.int-degenerate-span", function ()
        local of = Rng.new (SEED)
        Expect.equal (Rng.int (of, HIGH, HIGH), HIGH)
        Expect.equal (#Rng.tape (of), 0)
    end),

    -- The continuous draw, held to its half-open bounds and to reaching more than one value.
    Harness.case ("rng.number-in-bounds", function ()
        local seen, order = drawn (function (of) return Rng.number (of, LOW, HIGH) end)

        local count = 0
        for _ in seen do
            count += 1
        end
        Expect.holds (count > 1, `{DRAWS} draws answered {count} distinct numbers`)

        for _, value in order do
            Expect.holds (value >= LOW and value < HIGH, `a draw answered {value}`)
        end
    end),

    --[[
        Both answers, and the two probabilities that have only one. A coin that always says the same
        thing takes every branch a suite meant to exercise both ways.
    ]]
    Harness.case ("rng.bool-answers-both", function ()
        local of = Rng.new (SEED)
        local yes, no = false, false
        for _ = 1, DRAWS do
            if Rng.bool (of) then
                yes = true
            else
                no = true
            end
        end
        Expect.holds (yes and no, `{DRAWS} draws did not answer both ways`)

        for _ = 1, DRAWS do
            Expect.equal (Rng.bool (of, 0), false)
            Expect.equal (Rng.bool (of, 1), true)
        end
    end),

    -- A pick reaches every element, which is the same claim as the span one list further out.
    Harness.case ("rng.pick-reaches-everything", function ()
        local from: { number } = {}
        for value = LOW, HIGH do
            table.insert (from, value)
        end

        local seen = drawn (function (of) return Rng.pick (of, from) end)
        for value = LOW, HIGH do
            Expect.holds (seen[value] == true, `{DRAWS} picks never answered {value}`)
        end
    end),

    --[[
        A shuffle answers the list it was given and a different order. The first half is what
        makes it a shuffle rather than a draw, which is what selecting a subset of fields needs.
    ]]
    Harness.case ("rng.shuffle-permutes", function ()
        local was: { number } = {}
        for value = 1, LONG do
            table.insert (was, value)
        end

        local of = Rng.new (SEED)
        local moved = false
        for _ = 1, DRAWS do
            local list = table.clone (was)
            Rng.shuffle (of, list)

            Expect.equal (counted (list), counted (was))
            if list[1] ~= was[1] then moved = true end
        end
        Expect.holds (moved, `{DRAWS} shuffles left the list where it was`)
    end),

    -- Bytes, which the decode suites corrupt and which have to differ from one another.
    Harness.case ("rng.bytes-vary", function ()
        local of = Rng.new (SEED)
        local held = Rng.bytes (of, BYTES)
        Expect.equal (buffer.len (held), BYTES)

        local first = buffer.readu8 (held, 0)
        local same = true
        for at = 1, BYTES - 1 do
            if buffer.readu8 (held, at) ~= first then same = false end
        end
        Expect.holds (not same, `{BYTES} bytes came back all the same`)
    end),

    --[[
        The two things a seeded generator is for. One seed answers one run, so a failure reprints as
        a number a reader can hand back, and two seeds answer two.
    ]]
    Harness.case ("rng.seed-decides-the-run", function ()
        local _, one = drawn (function (of) return Rng.int (of, LOW, HIGH) end, SEED)
        local _, again = drawn (function (of) return Rng.int (of, LOW, HIGH) end, SEED)
        Expect.equal (one, again)

        local _, other = drawn (function (of) return Rng.int (of, LOW, HIGH) end, OTHER)
        Expect.holds (not Expect.alike (one, other), "two seeds answered one run")
    end),

    -- And the seed a generator reports is the one it was built from, which is what gets reprinted.
    Harness.case ("rng.seed-is-reported", function ()
        Expect.equal (Rng.seed (Rng.new (SEED)), SEED)
        Expect.equal (Rng.seed (Rng.new ()), Rng.BASE)
    end),

    --[[
        A tape replays the run it was taken from, which is how a corpus case and every shrink
        candidate are re-run. A replay that drew afresh would shrink a different failure.
    ]]
    Harness.case ("rng.replay-reproduces", function ()
        local of = Rng.new (SEED)
        local was: { number } = {}
        for _ = 1, DRAWS do
            table.insert (was, Rng.int (of, LOW, HIGH))
        end

        local again = Rng.replay (Rng.tape (of))
        local held: { number } = {}
        for _ = 1, DRAWS do
            table.insert (held, Rng.int (again, LOW, HIGH))
        end

        Expect.equal (held, was)
        Expect.equal (Rng.seed (again), 0)
    end),

    --[[
        The fixed point the module steps around. An all-zero state answers a constant forever, and
        `Rng.new` says so and guards it, and nothing until here asked whether the guard works.
    ]]
    Harness.case ("rng.zero-seed-still-varies", function ()
        local seen = drawn (function (of) return Rng.int (of, LOW, HIGH) end, 0)

        local count = 0
        for _ in seen do
            count += 1
        end
        Expect.holds (count > 1, `a seed of zero answered {count} distinct values`)
    end),

    -- The word every other call is built from, held to its width.
    Harness.case ("rng.next-is-a-word", function ()
        local seen, order = drawn (Rng.next)

        local count = 0
        for _ in seen do
            count += 1
        end
        Expect.holds (count > 1, `{DRAWS} words came back as {count} distinct values`)

        for _, value in order do
            Expect.holds (value >= 0 and value <= Rng.LARGEST, `a word came back as {value}`)
            Expect.holds (value % 1 == 0, `a word came back as {value}, which is not whole`)
        end
    end),
}
