--!strict
--!optimize 2
--[[
    The stamp arithmetic alone: milliseconds against an epoch, the field they wrap into, and back.
]]

local Clock = require ("@src/wire/Clock")
local Protocol = require ("@src/wire/Protocol")

local Expect = require ("@test/harness/Expect")
local Harness = require ("@test/harness")
local Rng = require ("@test/harness/Rng")

-- Constants -----------------------------------------------------------

--[[
    The instants one stamp field can tell apart, and the half of that a receiver reconstructs
    within. A stamp is twenty-four bits of milliseconds, so the space is about four and a half
    hours and the window a little over two.
]]
const SPAN = 2 ^ Protocol.STAMP_BITS
const WINDOW = SPAN / 2

--[[
    A shared-clock reading, which is Unix seconds. The size is the point: an epoch is a number near
    a billion and a half, and every count below is a difference taken at that scale rather than one
    taken near zero.
]]
const EPOCH = 1750000000

-- Instants where the wrap turns over, drawn as often as everywhere else.
const MOMENTS = table.freeze ({ 0, 1, -1, SPAN - 1, SPAN, SPAN + 1, -SPAN, -(SPAN + 1) })

-- Drifts where the answer turns over, on the same terms.
const DRIFTS = table.freeze ({
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
const REACH = 4

-- Private -------------------------------------------------------------

--[[
    A send instant, in whole milliseconds against the epoch. Negative because a client's shared
    clock can read behind the epoch in the moments after start, and several spaces out because a
    server up a day has passed five of them.
]]
local function instant (rng: Rng.Rng): number
    if Rng.bool (rng) then return Rng.pick (rng, MOMENTS) end
    return Rng.int (rng, -SPAN, REACH * SPAN)
end

--[[
    How far a receiver's estimate sits from the instant it is reconstructing. Inside the window the
    answer is that instant. Outside it the answer is a different instant carrying the same stamp,
    which is the contract reaching its limit rather than failing, and the laws below still hold
    there.
]]
local function drift (rng: Rng.Rng): number
    if Rng.bool (rng) then return Rng.pick (rng, DRIFTS) end
    return Rng.int (rng, -SPAN, SPAN)
end

-- Public --------------------------------------------------------------

return {
    --[[
        Milliseconds since the epoch, asked at a fraction either side of a whole one and at a
        reading below the epoch. Those are the three a floor and a clamp would answer apart.
    ]]
    Harness.case ("clock.elapsed", function ()
        Expect.equal (Clock.elapsed (EPOCH, EPOCH), 0)
        Expect.equal (Clock.elapsed (EPOCH + 1, EPOCH), 1000)
        Expect.equal (Clock.elapsed (EPOCH + 0.25, EPOCH), 250)
        Expect.equal (Clock.elapsed (EPOCH + 60, EPOCH), 60000)

        -- Both of these round to a different answer than they floor to.
        Expect.equal (Clock.elapsed (EPOCH + 1 / 1024, EPOCH), 0)
        Expect.equal (Clock.elapsed (EPOCH - 1 / 4096, EPOCH), -1)

        Expect.equal (Clock.elapsed (EPOCH - 1, EPOCH), -1000)
    end),

    --[[
        The field the wire carries, which is the count wrapped into twenty-four bits and always a
        value those bits can hold. A negative count is what decides the wrap: a remainder following
        the dividend answers a negative stamp, which is not a field at all, and what reaches the
        buffer is whatever it makes of one.
    ]]
    Harness.case ("clock.stamp", function ()
        Expect.equal (Clock.stamp (0), 0)
        Expect.equal (Clock.stamp (1), 1)
        Expect.equal (Clock.stamp (SPAN - 1), SPAN - 1)
        Expect.equal (Clock.stamp (SPAN), 0)
        Expect.equal (Clock.stamp (SPAN + 1), 1)
        Expect.equal (Clock.stamp (5 * SPAN + 77), 77)

        Expect.equal (Clock.stamp (-1), SPAN - 1)
        Expect.equal (Clock.stamp (-SPAN), 0)
        Expect.equal (Clock.stamp (-SPAN - 1), SPAN - 1)
    end),

    --[[
        The instant a stamp came from, recovered against an estimate. The pairs walk the placements
        a receiver is actually in: agreeing with the sender, running ahead of it, running behind it,
        and sitting the other side of a wrap from it. Transit takes time and two shared clocks are
        estimates, so the estimate is never the instant.
    ]]
    Harness.case ("clock.unwrap", function ()
        local placements = {
            { 0, 0 },
            { 0, 40 },
            { 5000, 4950 },
            { SPAN - 1, SPAN + 20 },
            { SPAN + 5, SPAN - 30 },
            { 3 * SPAN + 77, 3 * SPAN + 60 },
        }
        for _, pair in placements do
            local sent, elapsed = pair[1], pair[2]
            Expect.equal (Clock.unwrap (Clock.stamp (sent), elapsed), sent)
        end
    end),

    -- The window's edges. One millisecond inside it the instant still comes back, from either side.
    Harness.case ("clock.edges", function ()
        for _, sent in { 0, SPAN + 77 } do
            local stamp = Clock.stamp (sent)
            Expect.equal (Clock.unwrap (stamp, sent + WINDOW - 1), sent)
            Expect.equal (Clock.unwrap (stamp, sent - WINDOW + 1), sent)
        end

        Expect.equal (Clock.unwrap (77, 77 + WINDOW), 77 + SPAN)
        Expect.equal (Clock.unwrap (77, 77 - WINDOW), 77 - SPAN)
    end),

    --[[
        A client whose shared clock reads behind the epoch, which happens for a moment after
        start. The stamp it writes is still a field and a receiver anywhere in the window recovers
        the negative instant, none of the arithmetic having needed the count to be positive.
    ]]
    Harness.case ("clock.behind", function ()
        local early = Clock.elapsed (EPOCH - 0.125, EPOCH)
        Expect.equal (early, -125)

        local stamp = Clock.stamp (early)
        Expect.holds (stamp >= 0 and stamp < SPAN, `a count of {early} stamped {stamp}`)

        for _, elapsed in { -125, -20, 0, 30, 1000 } do
            Expect.equal (Clock.unwrap (stamp, elapsed), early)
        end
    end),

    --[[
        Two receivers reconstructing one stamp. The first two differ across a wrap, so they do not
        agree on how many have happened, and the third is far from both and still inside the
        window. All three answer one instant, or `sent` is not comparable and is worth nothing.
    ]]
    Harness.case ("clock.agree", function ()
        local sent = SPAN + 3
        local stamp = Clock.stamp (sent)

        for _, elapsed in { SPAN - 40, SPAN + 40, SPAN + 100000 } do
            Expect.equal (Clock.unwrap (stamp, elapsed), sent)
        end
    end),

    --[[
        Every instant against every estimate. Two laws hold wherever the estimate lands: the answer
        carries the stamp it was built from, and no instant carrying that stamp lies nearer.
        Together they name one value.
    ]]
    Harness.property ("clock.recovers", "leaves", function (rng: Rng.Rng)
        local sent = instant (rng)
        local apart = drift (rng)
        local elapsed = sent + apart

        local stamp = Clock.stamp (sent)
        Expect.holds (
            stamp >= 0 and stamp < SPAN and stamp % 1 == 0,
            `a count of {sent} stamped {stamp}`
        )

        local got = Clock.unwrap (stamp, elapsed)
        Expect.equal (got % SPAN, stamp)
        Expect.holds (
            math.abs (got - elapsed) <= WINDOW,
            `{got} carries the stamp but {elapsed} has a nearer one`
        )

        if math.abs (apart) < WINDOW then Expect.equal (got, sent) end
    end),
}
