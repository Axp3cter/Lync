--!strict
--!optimize 2
--[[
    The sequence arithmetic alone: the next number, the newer of two, and when a gate opens.
]]

local Protocol = require ("@src/wire/Protocol")
local Sequence = require ("@src/wire/Sequence")

local Expect = require ("@test/harness/Expect")
local Harness = require ("@test/harness")
local Rng = require ("@test/harness/Rng")

-- Constants -----------------------------------------------------------

--[[
    The window a receiver accepts ahead of what it holds, and the space that window is half of.
    Nothing names the sequence width on its own. The wire calls it sixteen bits and the protocol
    calls the window half of that, so the space is read back through the window rather than written
    down again.
]]
const WINDOW = Protocol.NEWEST_WINDOW
const SPACE = WINDOW * 2

--[[
    Where the whole-space walks start. The second sits near the top, so its walk crosses the wrap in
    its first steps rather than at its far end, and the window edge it reaches is on the other side
    of that crossing.
]]
const ANCHORS = table.freeze ({ 0, SPACE - 3 })

-- The distances around where the answer changes, and the far end of the ring, drawn as often.
const EDGES = table.freeze ({ 0, 1, WINDOW - 1, WINDOW, WINDOW + 1, SPACE - 1 })

--[[
    The samples a second is cut into for the rate walk, and the seconds it runs for. Both are powers
    of two, and so is every rate below, which makes each instant and each interval the gate compares
    exact in a double. The count the walk produces is then a fact rather than a rounding.
]]
const TICKS = 256
const SPAN = 4
const RATES = table.freeze ({ 1, 2, 4, 8, 16 })

-- Private -------------------------------------------------------------

--[[
    Every sequence the ring reaches from an anchor, checked against the number of steps that reached
    it. Stepping is what forward means, so counting steps says which of two is newer without
    repeating the subtraction that answers it, and the two functions have to agree about the
    direction they share.
]]
local function walked (from: number)
    local current = from
    for step = 1, SPACE - 1 do
        current = Sequence.next (current)
        if Sequence.isNewer (current, from) == (step < WINDOW) then continue end
        Expect.holds (false, `{current} is {step} steps past {from}`)
    end
end

--[[
    How many times a gate at this rate opens over the span, counted by walking the samples and
    letting the gate decide each one. This measures what `:newest(hz)` promises, a stream that
    transmits hz times a second, rather than restating the comparison the gate performs.
]]
local function opens (hz: number): number
    local last: number? = nil
    local count = 0

    for tick = 0, TICKS * SPAN - 1 do
        local now = tick / TICKS
        if not Sequence.opened (now, last, hz) then continue end

        count += 1
        last = now
    end
    return count
end

--[[
    A distance around the ring, landing on an edge as often as anywhere between. The answer turns
    over at four places out of sixty-five thousand, and a uniform draw would reach one about as
    often as never.
]]
local function distance (rng: Rng.Rng): number
    if Rng.bool (rng) then return Rng.int (rng, 0, SPACE - 1) end
    return Rng.pick (rng, EDGES)
end

-- Public --------------------------------------------------------------

return {
    --[[
        One step, and the step that closes the ring. The size of the step is what this pins: a
        counter advancing by three rings the whole space just as cleanly, so nothing about the ring
        being whole would notice it, and a stream would spend the space three times as fast as the
        window it is read through was sized for.
    ]]
    Harness.case ("sequence.next", function ()
        Expect.equal (Sequence.next (0), 1)
        Expect.equal (Sequence.next (1), 2)
        Expect.equal (Sequence.next (SPACE - 2), SPACE - 1)
        Expect.equal (Sequence.next (SPACE - 1), 0)
    end),

    --[[
        The ring is exactly the space wide. Stepping from zero visits every sequence once and lands
        back where it started, which is what makes a counter of it. A modulus one short would skip a
        value, and one half the space would hand out every number twice a cycle.
    ]]
    Harness.case ("sequence.cycle", function ()
        local seen = table.create (SPACE, false)
        local current = 0

        for _ = 1, SPACE do
            current = Sequence.next (current)
            if seen[current + 1] then Expect.holds (false, `{current} came round twice`) end
            seen[current + 1] = true
        end
        Expect.equal (current, 0)

        for value = 0, SPACE - 1 do
            if seen[value + 1] then continue end
            Expect.holds (false, `{value} never came round`)
        end
    end),

    --[[
        What follows a sequence is newer than it, and it is not newer than what follows it,
        everywhere on the ring including where it closes. This is the one fact a sender rests on. It
        stamps `next` and expects the receiver to take it.
    ]]
    Harness.case ("sequence.next-is-newer", function ()
        for value = 0, SPACE - 1 do
            local after = Sequence.next (value)
            if not Sequence.isNewer (after, value) then
                Expect.holds (false, `{after} follows {value} and does not read newer`)
            end
            if Sequence.isNewer (value, after) then
                Expect.holds (false, `{value} precedes {after} and reads newer`)
            end
        end
    end),

    --[[
        A sequence is not newer than itself. A receiver keeps the highest it has seen and takes
        anything newer, so a repeat reading as newer would let a duplicated frame overwrite what was
        already applied. A compare written without the guard is right about every ordered pair and
        wrong only here, which is why the distance of none has a case of its own.
    ]]
    Harness.case ("sequence.same", function ()
        for value = 0, SPACE - 1 do
            if not Sequence.isNewer (value, value) then continue end
            Expect.holds (false, `{value} reads newer than itself`)
        end
    end),

    --[[
        The window, walked. From an anchor, every sequence the ring reaches is newer exactly while
        it is under a window of steps away, and stale from there round to the far side. Two anchors,
        because a compare can be right about distances and wrong about where zero is.
    ]]
    Harness.case ("sequence.window", function ()
        for _, anchor in ANCHORS do
            walked (anchor)
        end
    end),

    --[[
        Half the space away, neither is newer. It is the one pair the order does not rank, because
        the same distance separates them going either way. The lane accepts that: a receiver a whole
        half-space behind has lost more than an ordering could recover, and every value it carries
        is absolute.
    ]]
    Harness.case ("sequence.antipode", function ()
        for _, anchor in ANCHORS do
            local across = (anchor + WINDOW) % SPACE
            Expect.equal (Sequence.isNewer (across, anchor), false)
            Expect.equal (Sequence.isNewer (anchor, across), false)
        end
    end),

    --[[
        When a gate lets a stream through. One that never transmitted goes now, one with no rate
        goes every flush, and a gated one waits out its interval. The interval reached exactly
        opens, and two flushes in one instant are one transmission.
    ]]
    Harness.case ("sequence.gate", function ()
        Expect.equal (Sequence.opened (0, nil, nil), true)
        Expect.equal (Sequence.opened (0, nil, 10), true)
        Expect.equal (Sequence.opened (0, 0, nil), true)

        Expect.equal (Sequence.opened (0.1, 0, 10), true)
        Expect.equal (Sequence.opened (0.05, 0, 10), false)
        Expect.equal (Sequence.opened (1, 0, 10), true)
        Expect.equal (Sequence.opened (0, 0, 10), false)

        Expect.equal (Sequence.opened (0.3, 0.2, 4), false)
    end),

    --[[
        The rate a gate delivers. Sampled far above the rate it caps and counted over several
        seconds, a stream declared at hz opens hz times a second. That is the promise measured,
        where the case above is the comparison checked, and a gate can pass one while failing the
        other.
    ]]
    Harness.case ("sequence.rate", function ()
        for _, hz in RATES do
            Expect.equal (opens (hz), SPAN * hz)
        end
    end),

    --[[
        Every distance across the ring, from anywhere on it. The pair is built out of the distance
        rather than measured back out of it, so the answer is known before the compare is asked,
        and the subtraction that answers it goes negative where the addition never does.
    ]]
    Harness.property ("sequence.wraps", "leaves", function (rng: Rng.Rng)
        local anchor = Rng.int (rng, 0, SPACE - 1)
        local apart = distance (rng)
        local ahead = (anchor + apart) % SPACE

        Expect.equal (Sequence.isNewer (ahead, anchor), apart ~= 0 and apart < WINDOW)
        Expect.equal (Sequence.isNewer (anchor, ahead), apart ~= 0 and SPACE - apart < WINDOW)
    end),
}
