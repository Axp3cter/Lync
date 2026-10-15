--!strict
--!optimize 2
-- The seeded generator held to varying, which every drawn case in every tree assumes.

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")
local Rng = require("@test/harness/Rng")

-- Draws before reading what came out: enough that a span of ten is covered many times by chance.
local DRAWS = 400
local LOW = 1
local HIGH = 10
local SEED = 20260825
local OTHER = 99999
local LONG = 12
local BYTES = 32

local function drawn(call: (Rng.Rng) -> number, seed: number?): ({ [number]: boolean }, { number })
    local rng = Rng.new(seed or SEED)
    local seen: { [number]: boolean } = {}
    local order: { number } = {}
    for _ = 1, DRAWS do
        local value = call(rng)
        seen[value] = true
        table.insert(order, value)
    end
    return seen, order
end

local function distinct(seen: { [number]: boolean }): number
    local count = 0
    for _ in seen do
        count += 1
    end
    return count
end

local function counted(list: { number }): { [number]: number }
    local held: { [number]: number } = {}
    for _, value in list do
        held[value] = (held[value] or 0) + 1
    end
    return held
end

return {
    Harness.case("rng.int-covers-its-span", function()
        local seen = drawn(function(rng)
            return rng:int(LOW, HIGH)
        end)
        for value = LOW, HIGH do
            Expect.holds(seen[value] == true, `{DRAWS} draws never answered {value}`)
        end
    end),

    Harness.case("rng.int-stays-in-bounds", function()
        local _, order = drawn(function(rng)
            return rng:int(LOW, HIGH)
        end)
        for _, value in order do
            Expect.holds(value >= LOW and value <= HIGH, `a draw answered {value}`)
            Expect.holds(value % 1 == 0, `a draw answered {value}, which is not whole`)
        end
    end),

    -- A span of one has one answer and must not spend a word finding it.
    Harness.case("rng.int-degenerate-span", function()
        local rng = Rng.new(SEED)
        Expect.equal(rng:int(HIGH, HIGH), HIGH)
        Expect.equal(#rng:tape(), 0)
    end),

    Harness.case("rng.number-in-bounds", function()
        local seen, order = drawn(function(rng)
            return rng:number(LOW, HIGH)
        end)
        Expect.holds(distinct(seen) > 1, `{DRAWS} draws answered {distinct(seen)} distinct numbers`)
        for _, value in order do
            Expect.holds(value >= LOW and value < HIGH, `a draw answered {value}`)
        end
    end),

    Harness.case("rng.bool-answers-both", function()
        local rng = Rng.new(SEED)
        local yes, no = false, false
        for _ = 1, DRAWS do
            if rng:bool() then
                yes = true
            else
                no = true
            end
        end
        Expect.holds(yes and no, `{DRAWS} draws did not answer both ways`)

        for _ = 1, DRAWS do
            Expect.equal(rng:bool(0), false)
            Expect.equal(rng:bool(1), true)
        end
    end),

    Harness.case("rng.pick-reaches-everything", function()
        local from: { number } = {}
        for value = LOW, HIGH do
            table.insert(from, value)
        end
        local seen = drawn(function(rng)
            return rng:pick(from)
        end)
        for value = LOW, HIGH do
            Expect.holds(seen[value] == true, `{DRAWS} picks never answered {value}`)
        end
    end),

    Harness.case("rng.shuffle-permutes", function()
        local was: { number } = {}
        for value = 1, LONG do
            table.insert(was, value)
        end

        local rng = Rng.new(SEED)
        local moved = false
        for _ = 1, DRAWS do
            local list = table.clone(was)
            rng:shuffle(list)
            Expect.equal(counted(list), counted(was))
            if list[1] ~= was[1] then moved = true end
        end
        Expect.holds(moved, `{DRAWS} shuffles left the list where it was`)
    end),

    Harness.case("rng.bytes-vary", function()
        local held = Rng.new(SEED):bytes(BYTES)
        Expect.equal(buffer.len(held), BYTES)

        local first = buffer.readu8(held, 0)
        local same = true
        for at = 1, BYTES - 1 do
            if buffer.readu8(held, at) ~= first then same = false end
        end
        Expect.holds(not same, `{BYTES} bytes came back all the same`)
        Expect.equal(buffer.len(Rng.new(SEED):bytes(BYTES - 1)), BYTES - 1)
    end),

    Harness.case("rng.seed-decides-the-run", function()
        local _, one = drawn(function(rng)
            return rng:int(LOW, HIGH)
        end, SEED)
        local _, again = drawn(function(rng)
            return rng:int(LOW, HIGH)
        end, SEED)
        Expect.equal(one, again)

        local _, other = drawn(function(rng)
            return rng:int(LOW, HIGH)
        end, OTHER)
        Expect.holds(not Expect.alike(one, other), "two seeds answered one run")
    end),

    Harness.case("rng.seed-is-reported", function()
        Expect.equal(Rng.new(SEED):seed(), SEED)
        Expect.equal(Rng.new():seed(), Rng.BASE)
    end),

    -- A tape replays the run it was taken from, which is how a shrink candidate is re-run.
    Harness.case("rng.replay-reproduces", function()
        local rng = Rng.new(SEED)
        local was: { number } = {}
        for _ = 1, DRAWS do
            table.insert(was, rng:int(LOW, HIGH))
        end

        local again = Rng.replay(rng:tape())
        local held: { number } = {}
        for _ = 1, DRAWS do
            table.insert(held, again:int(LOW, HIGH))
        end

        Expect.equal(held, was)
        Expect.equal(again:seed(), 0)
    end),

    -- An all-zero state is xoshiro's fixed point, and the constructor steps around it.
    Harness.case("rng.zero-seed-still-varies", function()
        local seen = drawn(function(rng)
            return rng:int(LOW, HIGH)
        end, 0)
        Expect.holds(distinct(seen) > 1, `a seed of zero answered {distinct(seen)} distinct values`)
    end),

    Harness.case("rng.next-is-a-word", function()
        local seen, order = drawn(function(rng)
            return rng:next()
        end)
        Expect.holds(distinct(seen) > 1, `{DRAWS} words came back as {distinct(seen)} values`)
        for _, value in order do
            Expect.holds(value >= 0 and value <= Rng.LARGEST, `a word came back as {value}`)
            Expect.holds(value % 1 == 0, `a word came back as {value}, which is not whole`)
        end
    end),
}
