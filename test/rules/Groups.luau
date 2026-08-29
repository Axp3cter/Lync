--!strict
--!optimize 2
-- A group as the membership set it is, and the two recipients that reach nobody.

local Lync = require ("@src")
local Session = require ("@src/runtime/Session")

local Doubles = require ("@fixtures/Doubles")
local Expect = require ("@test/harness/Expect")
local Harness = require ("@test/harness")

-- Constants -----------------------------------------------------------

const NAMESPACE = "groups"

--[[
    One packet, which the two recipient checks need and nothing else does. A group is a value a
    caller builds and reads without the library being involved at all, so the namespace here exists
    only for the fires that go nowhere.
]]
const DEFINITIONS = { beat = Lync.packet (Lync.bool ()) }

--[[
    Players that are not players. An engine makes no Player on demand, and the stub is built in
    one place already, so a second home for the fake would be a second answer to what a member is.
]]
const ROSTER = Doubles.roster ()

--[[
    The namespace a leave check opens, and the labels its two members join under. A leave reaches a
    group through a roster the session listens to, and `hearing` builds a fresh one per call, so
    these are spent there rather than on `ROSTER`.
]]
const LEAVING = "leaving"
const LEAVER = "leaver"
const STAYER = "stayer"

-- The member of the released group, spent on a roster of its own for the same reason.
const RELEASED = "released"

-- Private -------------------------------------------------------------

-- A machine that hears a removal, which is what a leave needs in order to reach a group.
local function hearing (): Doubles.Roster
    local roster = Doubles.roster ()
    local defs = { pulse = Lync.packet (Lync.bool ()) }

    local of = Session.new (LEAVING, defs, Doubles.wire ():server (), roster, "server")
    of:start ()
    return roster
end

-- A member, joined once and shared, because a label is spent once on a roster.
local function member (label: string): Player
    local held = ROSTER:named (label)
    if held ~= nil then return held end

    return ROSTER:join (label)
end

--[[
    What the namespace has counted for its one definition: the fires a caller made, and the bytes
    that left because of them.
]]
local function counted (): (number, number)
    local of = Lync.stats (NAMESPACE).definitions.beat
    return of.sent, of.sentBytes
end

-- Public --------------------------------------------------------------

return {
    Harness.opens (NAMESPACE, DEFINITIONS),

    --[[
        Membership, which is what a group is. A set rather than a list: adding a member twice leaves
        one, and removing one who is not there is nothing rather than an error.
    ]]
    Harness.case ("group.membership", function ()
        local of = Lync.group ()
        local alice, bob = member ("alice"), member ("bob")

        Expect.equal (of:has (alice), false)

        of:add (alice)
        Expect.equal (of:has (alice), true)
        Expect.equal (of:has (bob), false)

        of:add (alice)
        Expect.equal (#of, 1)

        of:remove (alice)
        Expect.equal (of:has (alice), false)

        of:remove (alice)
        Expect.equal (#of, 0)
    end),

    --[[
        The count, which moves with the membership and not with the calls. A caller reads it to
        decide whether a fire is worth making, so a number that counted adds rather than members
        would grow forever on a group a join handler keeps topping up.
    ]]
    Harness.case ("group.len", function ()
        local of = Lync.group ()
        Expect.equal (#of, 0)

        for index, label in { "alice", "bob", "carol" } do
            of:add (member (label))
            Expect.equal (#of, index)
        end

        of:remove (member ("bob"))
        Expect.equal (#of, 2)
    end),

    --[[
        The walk, held from both ends: every member is reached, each once, and nobody else is. A
        walk that answered a member twice would send a caller two of whatever they were doing per
        player, and one that reached past its own group would reach players another group holds.
    ]]
    Harness.case ("group.iterate", function ()
        local of = Lync.group ()
        local want = { alice = true, carol = true }

        of:add (member ("alice"))
        of:add (member ("carol"))

        local seen, count = {}, 0
        for _, player in of do
            Expect.holds (seen[player] == nil, `{player.Name} was walked twice`)
            Expect.holds (want[player.Name] == true, `{player.Name} is in no group`)

            seen[player] = true
            count += 1
        end
        Expect.equal (count, 2)
    end),

    --[[
        A group released while a live one holds the same member. The release has to take it out of
        the sweep's set, since a destroyed group raises on every call and a sweep that reached one
        would stop there and leave every group behind it holding a player who left.
    ]]
    Harness.case ("group.destroy", function ()
        local roster = hearing ()
        local released, kept = Lync.group (), Lync.group ()

        local leaver = roster:join (RELEASED)
        released:add (leaver)
        kept:add (leaver)

        released:destroy ()
        roster:leave (leaver)

        Expect.equal (kept:has (leaver), false)
    end),

    --[[
        A group after it was released. Every later call throws rather than answering about a group
        that no longer exists, since a stale reference answering an empty membership lets a caller
        fire at nobody forever.
    ]]
    Harness.case ("group.use-after-destroy", function ()
        local of = Lync.group ()
        local alice = member ("alice")

        of:add (alice)
        of:destroy ()

        local destroyed = "this group was destroyed"
        Expect.throws (function () of:add (alice) end, destroyed)
        Expect.throws (function () of:remove (alice) end, destroyed)
        Expect.throws (function () of:has (alice) end, destroyed)
        Expect.throws (function () of:destroy () end, destroyed)
    end),

    --[[
        A fire at a group that holds nobody. Not an error, because a group empties as players leave
        and a caller firing at their party has no reason to check first, and nothing leaves the
        machine, because there is nowhere for it to go.
    ]]
    Harness.case ("recip.empty", function ()
        local of = Lync.group ()
        local fires, bytes = counted ()

        DEFINITIONS.beat:fireClient (of, true)
        Lync.flush (NAMESPACE)

        local made, left = counted ()
        Expect.equal (made, fires + 1)
        Expect.equal (left, bytes)
    end),

    -- A member who leaves the game.
    Harness.case ("group.auto-drop", function ()
        local roster = hearing ()
        local of = Lync.group ()

        local leaver, stayer = roster:join (LEAVER), roster:join (STAYER)
        of:add (leaver)
        of:add (stayer)
        Expect.equal (#of, 2)

        roster:leave (leaver)

        Expect.equal (of:has (leaver), false)
        Expect.equal (of:has (stayer), true)
        Expect.equal (#of, 1)

        local seen: { [Player]: boolean } = {}
        for _, player in of do
            seen[player] = true
        end

        Expect.equal (seen[leaver], nil)
        Expect.equal (seen[stayer], true)
    end),

    --[[
        A fire at a player the connected set does not hold, which earns what an empty group earns
        and for the same reason: a caller holding a `Player` from a moment ago is holding one who
        may have left since, and a throw there would make every fire a call they had to guard.
    ]]
    Harness.case ("recip.departed", function ()
        local gone = member ("gone")
        local fires, bytes = counted ()

        DEFINITIONS.beat:fireClient (gone, true)
        Lync.flush (NAMESPACE)

        local made, left = counted ()
        Expect.equal (made, fires + 1)
        Expect.equal (left, bytes)
    end),
}
