--!strict
--!optimize 2
--[[
    The membership set alone: what a mutation does to it, and what is left after it is released.
]]

local Group = require ("@src/channel/Group")

local Doubles = require ("@fixtures/Doubles")

local Expect = require ("@test/harness/Expect")
local Harness = require ("@test/harness")

-- Constants -----------------------------------------------------------

-- Four stand-ins, enough that a full group can lose two members and still hold two.
const LABELS = table.freeze ({ "alice", "bob", "carol", "dave" })

-- Types ---------------------------------------------------------------

type Cast = { [string]: Player }

-- Private -------------------------------------------------------------

--[[
    Players made the way a double makes them, since standing in for one is the fixture's business
    and a unit spelling out the class would be a second answer to what a player is here.
]]
local function cast (): Cast
    local roster = Doubles.roster ()

    local by: Cast = {}
    for _, label in LABELS do
        by[label] = roster:join (label)
    end
    return by
end

-- A group holding the named players, which is what every case here opens with.
local function held (of: Cast, names: { string }): any
    local group: any = Group.new ()
    for _, name in names do
        group:add (of[name])
    end
    return group
end

-- The members a group holds, as the set of their names, since the order it holds them in is none.
local function inside (group: any): { [string]: boolean }
    local out: { [string]: boolean } = {}
    for _, player in group do
        out[player.Name] = true
    end
    return out
end

-- Held against the names it should hold, in both directions, so neither half stands alone.
local function same (group: any, wanted: { string })
    local got = inside (group)

    local names: { [string]: boolean } = {}
    for _, name in wanted do
        names[name] = true
        Expect.holds (got[name] == true, `{name} is not in the group`)
    end

    for name in got do
        Expect.holds (names[name] == true, `{name} is in the group and should not be`)
    end
    Expect.equal (#group, #wanted)
end

-- Public --------------------------------------------------------------

return {
    --[[
        A member added twice is one member, by the count as well as by the walk. A duplicate is
        tolerated rather than refused, so what matters is that both readings agree about it.
    ]]
    Harness.case ("group.add-twice", function ()
        local of = cast ()
        local group = held (of, { "alice" })

        group:add (of.alice)
        group:add (of.alice)

        Expect.equal (#group, 1)
        Expect.equal (group:has (of.alice), true)
    end),

    --[[
        Removing somebody who is not there is nothing, and leaves the rest where they were. The
        other half of what a membership set tolerates, asked from the side that would notice.
    ]]
    Harness.case ("group.remove-absent", function ()
        local of = cast ()
        local group = held (of, { "alice", "bob" })

        group:remove (of.carol)
        Expect.equal (#group, 2)

        group:remove (of.alice)
        group:remove (of.alice)

        Expect.equal (#group, 1)
        Expect.equal (group:has (of.alice), false)
    end),

    --[[
        A removal drops the last member into the hole rather than closing it, so the array stays
        packed and the index map follows. What that gives up is order, which a group does not
        promise: a member is written to on its own lane, so the only order it has is an accident.
    ]]
    Harness.case ("group.remove-swaps", function ()
        local of = cast ()
        local group = held (of, { "alice", "bob", "carol" })

        group:remove (of.alice)

        Expect.equal (#group, 2)
        Expect.equal (group:has (of.alice), false)
        Expect.equal (group:has (of.bob), true)
        Expect.equal (group:has (of.carol), true)

        -- And the one that moved is still removable, which says its index moved with it.
        group:remove (of.carol)

        Expect.equal (#group, 1)
        Expect.equal (group:has (of.bob), true)
    end),

    --[[
        Removing the member at the end, which is the one arrangement where the member dropped into
        the hole is the member being removed. A swap that wrote the index back after clearing it
        would leave a group holding a place for somebody who had gone.
    ]]
    Harness.case ("group.remove-last", function ()
        local of = cast ()
        local group = held (of, { "alice", "bob" })

        group:remove (of.bob)

        Expect.equal (#group, 1)
        Expect.equal (group:has (of.bob), false)
        Expect.equal (group:has (of.alice), true)

        group:remove (of.alice)

        Expect.equal (#group, 0)
        Expect.equal (next (inside (group)), nil)
    end),

    --[[
        The count and the walk against the membership test. These are kept apart in the
        implementation, so what this asks is that they never disagree, whatever a mutation did.
    ]]
    Harness.case ("group.count-and-walk", function ()
        local of = cast ()
        local group = held (of, LABELS)

        Expect.equal (#group, #LABELS)

        local seen = inside (group)
        for _, name in LABELS do
            Expect.holds (seen[name] == true, `{name} was not reached by a walk`)
            Expect.equal (group:has (of[name]), true)
        end

        group:remove (of.bob)
        group:remove (of.dave)

        same (group, { "alice", "carol" })
    end),

    --[[
        The test a recipient makes before it walks a group, asked of a player, a table with
        members and one without, and nothing at all. A walk that took any of these for a group
        would read a member off something that has none.
    ]]
    Harness.case ("group.is", function ()
        local of = cast ()

        Expect.equal (Group.is (held (of, { "alice" })), true)
        Expect.equal (Group.is ({ of.alice }), false)
        Expect.equal (Group.is (of.alice), false)
        Expect.equal (Group.is ({}), false)
        Expect.equal (Group.is (nil), false)
    end),

    --[[
        Every way into a destroyed group raises, which is what makes a stale reference loud. The
        failure it rules out is a caller firing into a group that answers as an empty one, which
        reads to them as a quiet network and never as a mistake.
    ]]
    Harness.case ("group.destroyed-raises", function ()
        local of = cast ()
        local group = held (of, { "alice", "bob" })

        group:destroy ()

        local gone = "this group was destroyed"
        Expect.throws (function () group:has (of.alice) end, gone)
        Expect.throws (function () group:add (of.carol) end, gone)
        Expect.throws (function () group:remove (of.alice) end, gone)
        Expect.throws (function () inside (group) end, gone)
        Expect.throws (function () Expect.equal (#group, 0) end, gone)
    end),

    --[[
        One metatable stands in front of every way into a group rather than a guard at each, so a
        release has one table to swap and no door it can miss.
    ]]
    Harness.case ("group.destroyed-is-not-a-group", function ()
        local of = cast ()
        local group = held (of, { "alice" })

        Expect.equal (Group.is (group), true)
        group:destroy ()

        --[[
            False rather than a raise, which is the one way in that answers. It reads the
            metatable rather than a field, so it is the one door the dead table is not in
            front of.
        ]]
        Expect.equal (Group.is (group), false)
    end),

    --[[
        A departed player, thinned out of every group that has not been destroyed. A group does not
        listen for a leave of its own, since that would be a subscription per group and a teardown
        order nobody wrote down, so the sweep comes from where the removal is heard.
    ]]
    Harness.case ("group.dropped-sweeps", function ()
        local of = cast ()
        local one = held (of, { "alice", "bob" })
        local two = held (of, { "bob", "carol" })
        local none = held (of, { "carol" })

        Group.dropped (of.bob)

        same (one, { "alice" })
        same (two, { "carol" })
        same (none, { "carol" })
    end),

    --[[
        A player no group holds, which is every leave from a place that keeps none. Nothing happens
        and nothing raises, because the sweep runs once per leave from a site that has no idea which
        groups exist.
    ]]
    Harness.case ("group.dropped-unknown", function ()
        local of = cast ()
        local group = held (of, { "alice" })

        Group.dropped (of.dave)
        same (group, { "alice" })
    end),

    --[[
        A group released before the player leaves. The leave that follows finds nothing to thin
        and reaches nothing that would raise, which is the order a caller tearing down at the end
        of a round writes without thinking about it.
    ]]
    Harness.case ("group.dropped-after-destroy", function ()
        local of = cast ()
        local gone = held (of, { "alice" })
        local kept = held (of, { "alice", "bob" })

        gone:destroy ()
        Group.dropped (of.alice)

        same (kept, { "bob" })
    end),

    --[[
        A release read through the only door left. There is nothing to see of an emptied group
        from outside it, so what this holds is that the release happened at all and that a second
        one says so the same way rather than more quietly.
    ]]
    Harness.case ("group.destroy-empties", function ()
        local of = cast ()
        local group = held (of, LABELS)

        group:destroy ()

        -- A second release is the same raise rather than a quieter one, since the door is the same.
        Expect.throws (function () group:destroy () end, "this group was destroyed")
    end),
}
