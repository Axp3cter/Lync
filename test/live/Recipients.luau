--!strict
--!optimize 2
-- Who a fire reaches, asked of each recipient form beside the complement of that form.

local Players = game:GetService ("Players")

local Lync = require ("@src")
local Types = require ("@src/Types")

local Expect = require ("@test/harness/Expect")
local Harness = require ("@test/harness")

-- Constants -----------------------------------------------------------

const NAMESPACE = "recipients"

--[[
    How long a check holds the floor, how long a half waits inside one for the other machine, and
    the pause a sender takes before it sends.
]]
const SPAN = 3
const PATIENCE = 2
const SETTLED = 0.5

-- What a fire carries, and what the second fire of one check carries instead.
const CARRIED = 7
const LATER = 9

--[[
    Two packets, so a check can fire at the recipient under test and at the complement of it in one
    span, and a client answers which of the two it was handed.
]]
const DEFINITIONS = table.freeze ({
    here = Lync.packet (Lync.int (0, 100)),
    there = Lync.packet (Lync.int (0, 100)),
})

-- Private -------------------------------------------------------------

--[[
    The connected set in an order both machines work out for themselves. By id rather than by the
    engine's own order, which is a list neither side promises the other anything about, and every
    recipient this file builds is a slice of this one.
]]
local function roster (): { Player }
    local here = Players:GetPlayers ()
    Expect.holds (#here > 0, "no client is here to fire at")

    table.sort (here, function (a: Player, b: Player): boolean return a.UserId < b.UserId end)
    return here
end

-- Whether this client is the one the single-player forms below address.
local function first (): boolean return Players.LocalPlayer == roster ()[1] end

--[[
    Every other client, from the first. Never empty, so the form under test always has somebody
    behind it. A proper subset from two clients up, so its complement has somebody too. More than
    one name from three, so a list is a list rather than a player written the long way.
]]
local function alternating (): { Player }
    local held = {}
    for index, who in roster () do
        if index % 2 == 1 then table.insert (held, who) end
    end
    return held
end

-- Both fires, heard for the length of a check, with each list handed to whatever reads them.
local function listening (run: ({ number }, { number }) -> ())
    local inside: { number } = {}
    local outside: { number } = {}

    local links: { Types.Connection } = {
        DEFINITIONS.here:onClient (function (value: number) table.insert (inside, value) end),
        DEFINITIONS.there:onClient (function (value: number) table.insert (outside, value) end),
    }

    Harness.attached (links, function () run (inside, outside) end)
end

--[[
    The claim every check here makes of a client: it was handed the one fire addressed to it, and
    not the other one.
]]
local function only (mine: boolean)
    listening (function (inside: { number }, outside: { number })
        local owed = if mine then inside else outside
        Harness.awaits ("the fire", function (): boolean return #owed >= 1 end, PATIENCE)
        task.wait (SETTLED)

        Expect.equal (#inside, if mine then 1 else 0)
        Expect.equal (#outside, if mine then 0 else 1)
    end)
end

-- One fire at the form under test, and one at everyone the form left out.
local function sends (inside: Types.Recipient, outside: Types.Recipient)
    task.wait (SETTLED)
    DEFINITIONS.here:fireClient (inside, CARRIED)
    DEFINITIONS.there:fireClient (outside, CARRIED)
end

-- Public --------------------------------------------------------------

return {
    Harness.opens (NAMESPACE, DEFINITIONS :: any),

    --[[
        `Lync.all`, and the one form with no complement to fire beside it: its audience is every
        client there is, so the set it leaves out is empty and there is nothing to name.
    ]]
    Harness.pair ("recip.all", function ()
        Harness.together (SPAN, NAMESPACE, function ()
            task.wait (SETTLED)
            DEFINITIONS.here:fireClient (Lync.all, CARRIED)
        end)
    end, function ()
        Harness.together (SPAN, NAMESPACE, function () only (true) end)
    end),

    --[[
        One `Player`, and everyone else. The lowest id is the one addressed, because it is an order
        every machine reaches on its own and neither half has to be told which client the other
        picked.
    ]]
    Harness.pair ("recip.player", function ()
        Harness.together (SPAN, NAMESPACE, function ()
            local one = roster ()[1]
            sends (one, Lync.except (one))
        end)
    end, function ()
        Harness.together (SPAN, NAMESPACE, function () only (first ()) end)
    end),

    -- A list, and everyone off it.
    Harness.pair ("recip.list", function ()
        Harness.together (SPAN, NAMESPACE, function ()
            local held = alternating ()
            sends (held, Lync.except (held))
        end)
    end, function ()
        Harness.together (SPAN, NAMESPACE, function ()
            local listed = alternating ()
            only (table.find (listed, Players.LocalPlayer) ~= nil)
        end)
    end),

    --[[
        A group, and everyone outside it. One member, because what a group holds is not the
        question here, and what this asks is that a fire named at one reaches the players in it and
        stops there.
    ]]
    Harness.pair ("recip.group", function ()
        Harness.together (SPAN, NAMESPACE, function ()
            local of = Lync.group ()
            of:add (roster ()[1])

            sends (of, Lync.except (of))
        end)
    end, function ()
        Harness.together (SPAN, NAMESPACE, function () only (first ()) end)
    end),

    -- `Lync.except`, subtracting nothing and subtracting everything.
    Harness.pair ("recip.except", function ()
        Harness.together (SPAN, NAMESPACE, function ()
            local nobody = Lync.group ()
            sends (Lync.except (nobody), Lync.except (roster ()))
        end)
    end, function ()
        Harness.together (SPAN, NAMESPACE, function () only (true) end)
    end),

    --[[
        A group grown after a fire already named it, and the members who were not in it for that
        one. A recipient resolves when the fire goes out rather than when it was written down, so a
        caller adding a player to a party group mid-round has the next send reach them and touches
        nothing else.
    ]]
    Harness.pair ("recip.late-mutation", function ()
        Harness.together (SPAN, NAMESPACE, function ()
            local of = Lync.group ()

            task.wait (SETTLED)
            DEFINITIONS.here:fireClient (of, CARRIED)

            task.wait (SETTLED)
            for _, who in roster () do
                of:add (who)
            end
            DEFINITIONS.here:fireClient (of, LATER)
        end)
    end, function ()
        Harness.together (SPAN, NAMESPACE, function ()
            listening (function (inside: { number })
                Harness.awaits (
                    "the fire after the group grew",
                    function (): boolean return #inside >= 1 end,
                    PATIENCE
                )
                task.wait (SETTLED)

                Expect.equal (#inside, 1)
                Expect.equal (inside[1], LATER)
            end)
        end)
    end),
}
