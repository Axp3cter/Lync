--!strict
--!optimize 2
-- The stamp arithmetic alone: milliseconds against an epoch, the field they wrap into, and back.

local Clock = require("@src/wire/Clock")
local Protocol = require("@src/wire/Protocol")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")
local Rng = require("@test/harness/Rng")

-- Twenty-four bits of milliseconds: a space of about four and a half hours, a window of half that.
local SPAN = 2 ^ Protocol.STAMP_BITS
local WINDOW = SPAN / 2

-- A shared-clock reading in Unix seconds, so every count below is a difference at that scale.
local EPOCH = 1750000000

local MOMENTS = table.freeze({ 0, 1, -1, SPAN - 1, SPAN, SPAN + 1, -SPAN, -(SPAN + 1) })
local DRIFTS = table.freeze({
    0,
    1,
    -1,
    WINDOW - 1,
    -(WINDOW - 1),
    WINDOW,
    -WINDOW,
    WINDOW + 1,
    -(WINDOW + 1),
})

-- How many spaces past the epoch a drawn instant may reach.
local REACH = 4

local function instant(rng: Rng.Rng): number
    if rng:bool() then return rng:pick(MOMENTS) end
    return rng:int(-SPAN, REACH * SPAN)
end

local function drift(rng: Rng.Rng): number
    if rng:bool() then return rng:pick(DRIFTS) end
    return rng:int(-SPAN, SPAN)
end

return {
    Harness.case("clock.elapsed", function()
        Expect.equal(Clock.elapsed(EPOCH, EPOCH), 0)
        Expect.equal(Clock.elapsed(EPOCH + 1, EPOCH), 1000)
        Expect.equal(Clock.elapsed(EPOCH + 0.25, EPOCH), 250)
        Expect.equal(Clock.elapsed(EPOCH + 60, EPOCH), 60000)

        -- Both round to a different answer than they floor to.
        Expect.equal(Clock.elapsed(EPOCH + 1 / 1024, EPOCH), 0)
        Expect.equal(Clock.elapsed(EPOCH - 1 / 4096, EPOCH), -1)
        Expect.equal(Clock.elapsed(EPOCH - 1, EPOCH), -1000)
    end),

    -- A negative count decides the wrap: the field must still be one those bits can hold.
    Harness.case("clock.stamp", function()
        Expect.equal(Clock.stamp(0), 0)
        Expect.equal(Clock.stamp(1), 1)
        Expect.equal(Clock.stamp(SPAN - 1), SPAN - 1)
        Expect.equal(Clock.stamp(SPAN), 0)
        Expect.equal(Clock.stamp(SPAN + 1), 1)
        Expect.equal(Clock.stamp(5 * SPAN + 77), 77)
        Expect.equal(Clock.stamp(-1), SPAN - 1)
        Expect.equal(Clock.stamp(-SPAN), 0)
        Expect.equal(Clock.stamp(-SPAN - 1), SPAN - 1)
    end),

    -- The placements a receiver is in: agreeing, ahead, behind, and across a wrap from the sender.
    Harness.case("clock.unwrap", function()
        for _, pair in
            {
                { 0, 0 },
                { 0, 40 },
                { 5000, 4950 },
                { SPAN - 1, SPAN + 20 },
                { SPAN + 5, SPAN - 30 },
                { 3 * SPAN + 77, 3 * SPAN + 60 },
            }
        do
            local sent, elapsed = pair[1], pair[2]
            Expect.equal(Clock.unwrap(Clock.stamp(sent), elapsed), sent)
        end
    end),

    Harness.case("clock.edges", function()
        for _, sent in { 0, SPAN + 77 } do
            local stamp = Clock.stamp(sent)
            Expect.equal(Clock.unwrap(stamp, sent + WINDOW - 1), sent)
            Expect.equal(Clock.unwrap(stamp, sent - WINDOW + 1), sent)
        end
        Expect.equal(Clock.unwrap(77, 77 + WINDOW), 77 + SPAN)
        Expect.equal(Clock.unwrap(77, 77 - WINDOW), 77 - SPAN)
    end),

    -- A client whose shared clock reads behind the epoch still writes a field, and a receiver
    -- anywhere in the window recovers the negative instant.
    Harness.case("clock.behind", function()
        local early = Clock.elapsed(EPOCH - 0.125, EPOCH)
        Expect.equal(early, -125)

        local stamp = Clock.stamp(early)
        Expect.holds(stamp >= 0 and stamp < SPAN, `a count of {early} stamped {stamp}`)
        for _, elapsed in { -125, -20, 0, 30, 1000 } do
            Expect.equal(Clock.unwrap(stamp, elapsed), early)
        end
    end),

    -- Receivers either side of a wrap, and one far from both, answer one instant.
    Harness.case("clock.agree", function()
        local sent = SPAN + 3
        local stamp = Clock.stamp(sent)
        for _, elapsed in { SPAN - 40, SPAN + 40, SPAN + 100000 } do
            Expect.equal(Clock.unwrap(stamp, elapsed), sent)
        end
    end),

    -- The answer carries the stamp it was built from, and no instant carrying that stamp lies
    -- nearer the estimate.
    Harness.property("clock.recovers", "leaves", function(rng: Rng.Rng)
        local sent = instant(rng)
        local apart = drift(rng)
        local elapsed = sent + apart

        local stamp = Clock.stamp(sent)
        Expect.holds(stamp >= 0 and stamp < SPAN and stamp % 1 == 0, `{sent} stamped {stamp}`)

        local got = Clock.unwrap(stamp, elapsed)
        Expect.equal(got % SPAN, stamp)
        Expect.holds(math.abs(got - elapsed) <= WINDOW, `{elapsed} has a nearer instant than {got}`)
        if math.abs(apart) < WINDOW then Expect.equal(got, sent) end
    end),
}
