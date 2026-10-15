--!strict
--!optimize 2
-- The min-heap alone: what comes out first, what comes out paired, and what an empty one answers.

local Heap = require("@src/kernel/Heap")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")
local Rng = require("@test/harness/Rng")

-- A drawn case pushes and pops this many times over this few keys, so duplicate keys are common.
local STEPS = 40
local KEYS = 12

type Entry = { key: number, value: number }

local function filled(keys: { number }): (Heap.Heap, { Entry })
    local heap = Heap.new()
    local held = {}
    for value, key in keys do
        heap:push(key, value)
        table.insert(held, { key = key, value = value })
    end
    return heap, held
end

-- Every key the heap answers until empty, and no further than the count it was filled with.
local function drained(heap: Heap.Heap, most: number): { number }
    local out = {}
    for _ = 1, most + 1 do
        local key = heap:pop()
        if key == nil then return out end
        table.insert(out, key)
    end
    Expect.holds(false, `the heap answered past the {most} entries it was given`)
    return out
end

local function least(held: { Entry }): number
    local found = math.huge
    for _, entry in held do
        if entry.key < found then found = entry.key end
    end
    return found
end

-- Drops the entry just answered. Equal keys are unordered between themselves, so the pair is
-- looked for rather than the position.
local function taken(held: { Entry }, key: number, value: number): boolean
    for index, entry in held do
        if entry.key == key and entry.value == value then
            table.remove(held, index)
            return true
        end
    end
    return false
end

return {
    Harness.case("heap.empty-pop", function()
        local key, value = Heap.new():pop()
        Expect.equal(key, nil)
        Expect.equal(value, nil)
    end),

    Harness.case("heap.empty-peek", function()
        local key, value = Heap.new():peek()
        Expect.equal(key, nil)
        Expect.equal(value, nil)
    end),

    Harness.case("heap.one", function()
        local heap = Heap.new()
        heap:push(5, 50)

        local key, value = heap:pop()
        Expect.equal(key, 5)
        Expect.equal(value, 50)
        Expect.equal(heap:pop(), nil)
    end),

    Harness.case("heap.peek-holds", function()
        local heap = filled({ 7, 3, 9 })

        local first, firstValue = heap:peek()
        local again, againValue = heap:peek()
        Expect.equal(first, 3)
        Expect.equal(again, 3)
        Expect.equal(firstValue, againValue)

        local key, value = heap:pop()
        Expect.equal(key, first)
        Expect.equal(value, firstValue)
    end),

    Harness.case("heap.ascending", function()
        local heap, held = filled({ 1, 2, 3, 4, 5, 6, 7, 8 })
        Expect.equal(drained(heap, #held), { 1, 2, 3, 4, 5, 6, 7, 8 })
    end),

    Harness.case("heap.descending", function()
        local heap, held = filled({ 8, 7, 6, 5, 4, 3, 2, 1 })
        Expect.equal(drained(heap, #held), { 1, 2, 3, 4, 5, 6, 7, 8 })
    end),

    Harness.case("heap.shuffled", function()
        local heap, held = filled({ 5, 1, 8, 3, 7, 2, 6, 4 })
        Expect.equal(drained(heap, #held), { 1, 2, 3, 4, 5, 6, 7, 8 })
    end),

    -- A deadline is a float and a slot is a whole number, and the heap holds both.
    Harness.case("heap.fractional", function()
        local heap, held = filled({ 0.75, 0.25, 0.5 })
        Expect.equal(drained(heap, #held), { 0.25, 0.5, 0.75 })
    end),

    Harness.case("heap.negative", function()
        local heap, held = filled({ 5, -5, 0 })
        Expect.equal(drained(heap, #held), { -5, 0, 5 })
    end),

    Harness.case("heap.duplicates", function()
        local heap, held = filled({ 3, 1, 3, 1 })

        local keys = {}
        while #held > 0 do
            local key, value = heap:pop()
            Expect.holds(key ~= nil, "the heap emptied while entries were held")
            Expect.holds(taken(held, key :: number, value :: number), "an unpaired entry")
            table.insert(keys, key)
        end
        Expect.equal(keys, { 1, 1, 3, 3 })
        Expect.equal(heap:pop(), nil)
    end),

    Harness.case("heap.interleaved", function()
        local heap = Heap.new()
        heap:push(5, 50)
        heap:push(3, 30)
        Expect.equal(heap:pop(), 3)

        heap:push(4, 40)
        Expect.equal(heap:pop(), 4)
        Expect.equal(heap:pop(), 5)
        Expect.equal(heap:pop(), nil)
    end),

    -- A drained heap holds nothing over, which is what slot reuse rides on.
    Harness.case("heap.reused", function()
        local heap, held = filled({ 4, 2, 6 })
        Expect.equal(drained(heap, #held), { 2, 4, 6 })

        heap:push(9, 90)
        heap:push(1, 10)
        Expect.equal(drained(heap, 2), { 1, 9 })
    end),

    -- A random run of pushes and pops against a plain list: every pop answers the smallest key
    -- held and the value pushed beside it, and the run then drains empty.
    Harness.property("heap.mirrors", "leaves", function(rng: Rng.Rng)
        local heap = Heap.new()
        local held: { Entry } = {}

        local function takes()
            local wanted = least(held)
            local peeked = heap:peek()
            local key, value = heap:pop()
            Expect.equal(key, wanted)
            Expect.equal(peeked, wanted)
            Expect.holds(taken(held, key :: number, value :: number), `{key} came unpaired`)
        end

        for step = 1, rng:int(0, STEPS) do
            if #held > 0 and rng:bool() then
                takes()
                continue
            end
            local key = rng:int(0, KEYS)
            heap:push(key, step)
            table.insert(held, { key = key, value = step })
        end

        while #held > 0 do
            takes()
        end
        Expect.equal(heap:pop(), nil)
    end),
}
