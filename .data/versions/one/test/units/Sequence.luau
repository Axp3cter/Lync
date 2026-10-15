--!strict
--!optimize 2
-- The sequence arithmetic alone: the next number, the newer of two, and when a gate opens.

local Protocol = require("@src/wire/Protocol")
local Sequence = require("@src/wire/Sequence")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")
local Rng = require("@test/harness/Rng")

local WINDOW = Protocol.NEWEST_WINDOW
local SPACE = WINDOW * 2

-- Where the whole-space walks start. The second sits near the top so its walk crosses the wrap
-- in its first steps.
local ANCHORS = table.freeze({ 0, SPACE - 3 })

-- The distances where the answer changes, and the far end of the ring, drawn as often.
local EDGES = table.freeze({ 0, 1, WINDOW - 1, WINDOW, WINDOW + 1, SPACE - 1 })

-- Samples a second is cut into for the rate walk and the seconds it runs. Powers of two, like every
-- rate below, so each instant and interval is exact in a double.
local TICKS = 256
local SECONDS = 4
local RATES = table.freeze({ 1, 2, 4, 8, 16 })

-- Every sequence the ring reaches from an anchor, held to the number of steps that reached it.
local function walked(from: number)
    local current = from
    for step = 1, SPACE - 1 do
        current = Sequence.next(current)
        if Sequence.isNewer(current, from) == (step < WINDOW) then continue end
        Expect.holds(false, `{current} is {step} steps past {from}`)
    end
end

-- How many times a gate at this rate opens over the span, letting the gate decide each sample.
local function opens(hz: number): number
    local last: number? = nil
    local count = 0
    for tick = 0, TICKS * SECONDS - 1 do
        local now = tick / TICKS
        if not Sequence.isOpen(now, last, hz) then continue end
        count += 1
        last = now
    end
    return count
end

-- A distance round the ring, landing on an edge as often as anywhere between.
local function distance(rng: Rng.Rng): number
    if rng:bool() then return rng:int(0, SPACE - 1) end
    return rng:pick(EDGES)
end

return {
    Harness.case("sequence.next", function()
        Expect.equal(Sequence.next(0), 1)
        Expect.equal(Sequence.next(1), 2)
        Expect.equal(Sequence.next(SPACE - 2), SPACE - 1)
        Expect.equal(Sequence.next(SPACE - 1), 0)
    end),

    -- Stepping from zero visits every sequence once and lands back where it started.
    Harness.case("sequence.cycle", function()
        local seen = table.create(SPACE, false)
        local current = 0
        for _ = 1, SPACE do
            current = Sequence.next(current)
            if seen[current + 1] then Expect.holds(false, `{current} came round twice`) end
            seen[current + 1] = true
        end
        Expect.equal(current, 0)
        for value = 0, SPACE - 1 do
            if seen[value + 1] then continue end
            Expect.holds(false, `{value} never came round`)
        end
    end),

    -- What follows a sequence is newer than it, everywhere on the ring including where it closes.
    Harness.case("sequence.next-is-newer", function()
        for value = 0, SPACE - 1 do
            local after = Sequence.next(value)
            Expect.holds(Sequence.isNewer(after, value), `{after} follows {value}, not newer`)
            Expect.holds(not Sequence.isNewer(value, after), `{value} precedes {after}, newer`)
        end
    end),

    -- A repeat reading as newer would let a duplicated frame overwrite what was already applied.
    Harness.case("sequence.same", function()
        for value = 0, SPACE - 1 do
            if not Sequence.isNewer(value, value) then continue end
            Expect.holds(false, `{value} reads newer than itself`)
        end
    end),

    Harness.case("sequence.window", function()
        for _, anchor in ANCHORS do
            walked(anchor)
        end
    end),

    -- Half the space away, neither is newer, the one pair the order does not rank.
    Harness.case("sequence.antipode", function()
        for _, anchor in ANCHORS do
            local across = (anchor + WINDOW) % SPACE
            Expect.equal(Sequence.isNewer(across, anchor), false)
            Expect.equal(Sequence.isNewer(anchor, across), false)
        end
    end),

    Harness.case("sequence.gate", function()
        Expect.equal(Sequence.isOpen(0, nil, nil), true)
        Expect.equal(Sequence.isOpen(0, nil, 10), true)
        Expect.equal(Sequence.isOpen(0, 0, nil), true)

        Expect.equal(Sequence.isOpen(0.1, 0, 10), true)
        Expect.equal(Sequence.isOpen(0.05, 0, 10), false)
        Expect.equal(Sequence.isOpen(1, 0, 10), true)
        Expect.equal(Sequence.isOpen(0, 0, 10), false)
        Expect.equal(Sequence.isOpen(0.3, 0.2, 4), false)
    end),

    -- A stream declared at hz opens hz times a second, the promise measured rather than the
    -- comparison restated.
    Harness.case("sequence.rate", function()
        for _, hz in RATES do
            Expect.equal(opens(hz), SECONDS * hz)
        end
    end),

    Harness.property("sequence.wraps", "leaves", function(rng: Rng.Rng)
        local anchor = rng:int(0, SPACE - 1)
        local apart = distance(rng)
        local ahead = (anchor + apart) % SPACE
        Expect.equal(Sequence.isNewer(ahead, anchor), apart ~= 0 and apart < WINDOW)
        Expect.equal(Sequence.isNewer(anchor, ahead), apart ~= 0 and SPACE - apart < WINDOW)
    end),
}
