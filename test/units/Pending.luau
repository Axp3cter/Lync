--!strict
--!optimize 2
-- The requests a machine is waiting on. Every one ends exactly once and says which of the four
-- ways it ended, since a caller branches on that to decide whether asking again is sensible.

local Pending = require("@src/runtime/Pending")
local Protocol = require("@src/wire/Protocol")
local Types = require("@src/Types")

local Doubles = require("@fixtures/Doubles")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")

local SPACE = "pending"

-- The id space, twice the ceiling on requests in flight, which is where an id wraps.
local IDS = Protocol.QUERY_CAP * 2
local ASKED = "ask"
local NOW = 100
local LATER = NOW + Protocol.QUERY_TIMEOUT + 1
local SOONER = 2

type Done = { ok: boolean, code: unknown, data: Types.OutcomeData? }

-- One request, and the list its completion writes to, so a check reads what it was told.
local function asking(
    of: Pending.Pending,
    now: number,
    player: Player?,
    timeout: number?
): ({ Done }, number)
    local done: { Done } = {}
    local id = of:open(now, ASKED, player, timeout, function(ok, code, data)
        table.insert(done, { ok = ok, code = code, data = data })
    end)
    return done, id
end

return {
    -- A request opened and answered is handed the value and nothing about how it ended, is
    -- answered once, and two live requests never share an id.
    Harness.case("pending.opens-and-answers", function()
        local of = Pending.new(SPACE)
        local done, id = asking(of, NOW, nil, nil)
        local second, two = asking(of, NOW, nil, nil)
        Expect.holds(id ~= two, `two live requests took the id {id}`)
        Expect.equal(of.count, 2)

        -- Ids climb by one, so the bytes a run of requests puts on the wire are the same on every
        -- machine, and the one after a request ended is still the next up rather than a reuse.
        Expect.equal(two, (id + 1) % IDS)
        local _, three = asking(of, NOW, nil, nil)
        Expect.equal(three, (two + 1) % IDS)
        Expect.equal(of.count, 3)
        of:answer(three, ASKED)

        -- A wrap that lands on a live id steps forward past it, never back onto a free one behind.
        of.next = id
        local _, four = asking(of, NOW, nil, nil)
        Expect.equal(four, three)
        Expect.equal(of.next, (three + 1) % IDS)
        of:answer(four, ASKED)

        Expect.equal(of:answer(id, ASKED), true)
        Expect.equal(done, { { ok = true, code = ASKED } })
        Expect.equal(#second, 0)
        Expect.equal(of.count, 1)
        Expect.equal(of:answer(id, ASKED), false)
        Expect.equal(#done, 1)
    end),

    -- The deadline is the one the caller named or the one the protocol gives them. A sweep before
    -- it takes nothing, one after it takes the request, and the failure carries how long it waited.
    Harness.case("pending.deadlines", function()
        local of = Pending.new(SPACE)
        local done = asking(of, NOW, nil, nil)
        of:sweep(NOW)
        of:sweep(NOW + Protocol.QUERY_TIMEOUT - 1)
        Expect.equal(#done, 0)
        of:sweep(LATER)
        Expect.equal(#done, 1)
        Expect.equal(done[1].ok, false)
        Expect.equal(done[1].code, "timeout")
        Expect.equal((done[1].data :: any).elapsed, LATER - NOW)
        Expect.equal((done[1].data :: any).definition, ASKED)
        Expect.equal(of.count, 0)

        local named = asking(of, NOW, nil, SOONER)
        of:sweep(NOW + SOONER - 1)
        Expect.equal(#named, 0)
        of:sweep(NOW + SOONER)
        Expect.equal(named[1].code, "timeout")
    end),

    -- An id answered before its deadline is not failed when the deadline comes round, and the
    -- ceiling on requests in flight is refused rather than exceeded.
    Harness.case("pending.answered-before-the-deadline", function()
        local of = Pending.new(SPACE)
        local done, id = asking(of, NOW, nil, SOONER)
        of:answer(id, ASKED)
        of:sweep(LATER)
        Expect.equal(#done, 1)

        for _ = 1, Protocol.QUERY_CAP do
            asking(of, NOW, nil, nil)
        end
        Expect.throws(function()
            asking(of, NOW, nil, nil)
        end, "which is the ceiling")
    end),

    -- A machine leaving ends only what it was waiting on, as a leave rather than a timeout, and a
    -- namespace closing ends everything as a shutdown.
    Harness.case("pending.leave-and-shutdown", function()
        local of = Pending.new(SPACE)
        local roster = Doubles.roster()
        local one, two = roster:join("one"), roster:join("two")
        local mine = asking(of, NOW, one, nil)
        local theirs = asking(of, NOW, two, nil)
        of:rejectFor(one, NOW)
        Expect.equal(mine[1].code, "leave")
        Expect.equal(#theirs, 0)
        Expect.equal(of.count, 1)

        local more = asking(of, NOW, nil, nil)
        of:rejectAll(LATER)
        Expect.equal(theirs[1].code, "shutdown")
        Expect.equal(more[1].code, "shutdown")
        Expect.equal((more[1].data :: any).elapsed, LATER - NOW)
        Expect.equal(of.count, 0)
        Expect.equal(of:answer(0, ASKED), false)
    end),
}
