--!strict
--!optimize 2
-- The membership set alone: what a mutation does to it, and what is left after it is released.

local Group = require("@src/channel/Group")

local Doubles = require("@fixtures/Doubles")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")

local LABELS = table.freeze({ "alice", "bob", "carol", "dave" })
local GONE = "this group was destroyed"

type Cast = { [string]: Player }

local function cast(): Cast
    local roster = Doubles.roster()
    local by: Cast = {}
    for _, label in LABELS do
        by[label] = roster:join(label)
    end
    return by
end

local function held(of: Cast, names: { string }): any
    local group: any = Group.new()
    for _, name in names do
        group:add(of[name])
    end
    return group
end

-- The members a group holds as the set of their names, since the order it holds them in is none.
local function inside(group: any): { [string]: boolean }
    local out: { [string]: boolean } = {}
    for _, player in group do
        out[player.Name] = true
    end
    return out
end

-- The call form walks the same members in the same order as the syntax, and ends where it ends.
local function called(group: any): { string }
    local out: { string } = {}
    for player in group:players() do
        table.insert(out, player.Name)
    end
    return out
end

local function same(group: any, wanted: { string })
    local names: { [string]: boolean } = {}
    for _, name in wanted do
        names[name] = true
    end
    Expect.equal(inside(group), names)
    Expect.equal(#group, #wanted)
    Expect.equal(group:size(), #wanted)
    local walked: { string } = {}
    for _, player in group do
        table.insert(walked, player.Name)
    end
    Expect.equal(called(group), walked)
end

return {
    -- A member added twice is one member, and removing somebody absent is nothing.
    Harness.case("group.add-and-remove", function()
        local of = cast()
        local group = held(of, { "alice", "bob" })
        group:add(of.alice)
        Expect.equal(#group, 2)
        Expect.equal(group:has(of.alice), true)

        group:remove(of.carol)
        Expect.equal(#group, 2)
        group:remove(of.alice)
        group:remove(of.alice)
        Expect.equal(#group, 1)
        Expect.equal(group:has(of.alice), false)
    end),

    -- A removal drops the last member into the hole, and the index follows the one that moved.
    -- Removing the member at the end is the one case where the mover is the one removed.
    Harness.case("group.remove-swaps", function()
        local of = cast()
        local group = held(of, { "alice", "bob", "carol" })
        group:remove(of.alice)
        same(group, { "bob", "carol" })
        group:remove(of.carol)
        same(group, { "bob" })

        local pair = held(of, { "alice", "bob" })
        pair:remove(of.bob)
        same(pair, { "alice" })
        pair:remove(of.alice)
        same(pair, {})
    end),

    -- The count, the walk and the membership test never disagree, whatever a mutation did.
    Harness.case("group.count-and-walk", function()
        local of = cast()
        local group = held(of, LABELS)
        same(group, LABELS)
        for _, name in LABELS do
            Expect.equal(group:has(of[name]), true)
        end
        group:remove(of.bob)
        group:remove(of.dave)
        same(group, { "alice", "carol" })
    end),

    -- The test a recipient makes before it walks a group, and what a destroyed one answers.
    Harness.case("group.is", function()
        local of = cast()
        local group = held(of, { "alice" })
        Expect.equal(Group.is(group), true)
        Expect.equal(Group.is({ of.alice }), false)
        Expect.equal(Group.is(of.alice), false)
        Expect.equal(Group.is({}), false)
        Expect.equal(Group.is(nil), false)
        group:destroy()
        Expect.equal(Group.is(group), false)
    end),

    -- Every way into a destroyed group raises, a second release the same way.
    Harness.case("group.destroyed-raises", function()
        local of = cast()
        local group = held(of, { "alice", "bob" })
        group:destroy()
        Expect.throws(function()
            group:has(of.alice)
        end, GONE)
        Expect.throws(function()
            group:add(of.carol)
        end, GONE)
        Expect.throws(function()
            group:remove(of.alice)
        end, GONE)
        Expect.throws(function()
            inside(group)
        end, GONE)
        Expect.throws(function()
            called(group)
        end, GONE)
        Expect.throws(function()
            Expect.equal(#group, 0)
        end, GONE)
        Expect.throws(function()
            group:destroy()
        end, GONE)
    end),

    -- A departed player is thinned out of every live group, an unknown one out of none, and a
    -- group released before the leave is reached by nothing.
    Harness.case("group.dropped-sweeps", function()
        local of = cast()
        local one = held(of, { "alice", "bob" })
        local two = held(of, { "bob", "carol" })
        local none = held(of, { "carol" })
        local gone = held(of, { "bob" })
        gone:destroy()

        Group.dropped(of.bob)
        same(one, { "alice" })
        same(two, { "carol" })
        same(none, { "carol" })

        Group.dropped(of.dave)
        same(one, { "alice" })
    end),
}
