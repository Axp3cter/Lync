--!strict
--!optimize 2
--[[
    The requests a machine is waiting on. Every one of them ends exactly once and says which of the
    four ways it ended, since a caller branches on that to decide whether asking again is sensible,
    and a request that ended twice or not at all is a completion nobody can reason about.
]]

local Pending = require ("@src/runtime/Pending")
local Protocol = require ("@src/wire/Protocol")
local Types = require ("@src/Types")

local Expect = require ("@test/harness/Expect")
local Harness = require ("@test/harness")

-- Constants -----------------------------------------------------------

const SPACE = "pending"
const ASKED = "ask"

-- A moment to open at, and one far enough past it that every deadline below has gone.
const NOW = 100
const LATER = NOW + Protocol.QUERY_TIMEOUT + 1

-- A deadline a caller names instead of the one the protocol gives them.
const SOONER = 2

-- Types ---------------------------------------------------------------

type Done = { ok: boolean, code: unknown, data: Types.OutcomeData? }

-- Private -------------------------------------------------------------

-- One request, and the list its completion writes to, so a check reads what it was told.
local function asking (of: any, now: number, player: Player?, timeout: number?): ({ Done }, number)
    local done: { Done } = {}
    local id = of:open (
        now,
        ASKED,
        player,
        timeout,
        function (ok: boolean, code: unknown, data: Types.OutcomeData?)
            table.insert (done, { ok = ok, code = code, data = data })
        end
    )

    return done, id
end

-- Public --------------------------------------------------------------

return {
    --[[
        A request opened and answered. What a caller is handed is the value and nothing about how
        it ended, since it ended the way they asked for, and the machine is left waiting on one
        request fewer than it was.
    ]]
    Harness.case ("pending.opens-and-answers", function ()
        local of = Pending.new (SPACE)
        local done, id = asking (of, NOW, nil, nil)

        Expect.equal ((of :: any).count, 1)
        Expect.equal (of:answer (id, ASKED), true)

        Expect.equal (#done, 1)
        Expect.equal (done[1].ok, true)
        Expect.equal (done[1].code, ASKED)
        Expect.equal (done[1].data, nil)
        Expect.equal ((of :: any).count, 0)

        -- Answered once, since the id is taken out of the live set as it is answered.
        Expect.equal (of:answer (id, ASKED), false)
        Expect.equal (#done, 1)
    end),

    --[[
        Two requests open at once, which may not be handed one id between them. An id is what an
        answer comes back under, so a second request taking a live one would be answered by the
        first reply to arrive and the other would wait out its deadline for nothing.
    ]]
    Harness.case ("pending.ids-are-not-reused", function ()
        local of = Pending.new (SPACE)

        local first, one = asking (of, NOW, nil, nil)
        local second, two = asking (of, NOW, nil, nil)

        Expect.holds (one ~= two, `two live requests took the id {one}`)
        Expect.equal ((of :: any).count, 2)

        of:answer (one, ASKED)
        Expect.equal (#first, 1)
        Expect.equal (#second, 0)
    end),

    --[[
        The deadline a request is kept until, which is the one the caller named or the one the
        protocol gives them. A sweep before it takes nothing and a sweep after it takes the
        request, and what the failure carries is how long the request waited rather than the
        deadline it waited on.
    ]]
    Harness.case ("pending.a-deadline-is-kept", function ()
        local of = Pending.new (SPACE)
        local done = asking (of, NOW, nil, nil)

        of:sweep (NOW)
        Expect.equal (#done, 0)

        of:sweep (NOW + Protocol.QUERY_TIMEOUT - 1)
        Expect.equal (#done, 0)

        of:sweep (LATER)
        Expect.equal (#done, 1)
        Expect.equal (done[1].ok, false)
        Expect.equal (done[1].code, "timeout")
        Expect.equal ((done[1].data :: any).elapsed, LATER - NOW)
        Expect.equal ((of :: any).count, 0)
    end),

    -- A deadline the caller named, which is kept instead of the one they did not.
    Harness.case ("pending.a-named-deadline-is-kept", function ()
        local of = Pending.new (SPACE)
        local done = asking (of, NOW, nil, SOONER)

        of:sweep (NOW + SOONER - 1)
        Expect.equal (#done, 0)

        of:sweep (NOW + SOONER)
        Expect.equal (#done, 1)
        Expect.equal (done[1].code, "timeout")
    end),

    --[[
        A machine leaving, and the requests owed to it. Only what that machine was waiting on ends,
        and it ends as a leave rather than a timeout, since a caller told it timed out would ask
        again and there is nobody left to ask.
    ]]
    Harness.case ("pending.a-leave-takes-one-machine", function ()
        local of = Pending.new (SPACE)
        local one = Instance.new ("Player") :: any
        local two = Instance.new ("Player") :: any

        local mine = asking (of, NOW, one, nil)
        local theirs = asking (of, NOW, two, nil)

        of:rejectFor (one, NOW)

        Expect.equal (#mine, 1)
        Expect.equal (mine[1].code, "leave")
        Expect.equal (#theirs, 0)
        Expect.equal ((of :: any).count, 1)
    end),

    --[[
        A namespace closing, which ends every request at once and leaves the machine waiting on
        none. Each is told it was a shutdown rather than anything a caller could retry past.
    ]]
    Harness.case ("pending.a-shutdown-takes-everything", function ()
        local of = Pending.new (SPACE)

        local mine = asking (of, NOW, nil, nil)
        local theirs = asking (of, NOW, nil, nil)

        of:rejectAll (LATER)

        Expect.equal (#mine, 1)
        Expect.equal (#theirs, 1)
        Expect.equal (mine[1].code, "shutdown")
        Expect.equal ((mine[1].data :: any).elapsed, LATER - NOW)
        Expect.equal ((of :: any).count, 0)
    end),
}
