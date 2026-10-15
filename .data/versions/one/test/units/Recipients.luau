--!strict
--!optimize 2
-- What the recipient walk answers for each of the five forms, and what it leaves behind.

local Group = require("@src/channel/Group")
local Recipients = require("@src/channel/Recipients")
local Types = require("@src/Types")

local Doubles = require("@fixtures/Doubles")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")

local LABELS = table.freeze({ "alice", "bob", "carol", "dave" })

-- The one on the roster never told they may receive, which is what `ready` is about.
local ABSENT = "dave"

type Cast = { by: { [string]: Player }, ready: Recipients.Ready }

local function cast(): Cast
    local roster = Doubles.roster()
    local by: { [string]: Player } = {}
    local ready: Recipients.Ready = {}
    for _, label in LABELS do
        local player = roster:join(label)
        by[label] = player
        ready[player] = label ~= ABSENT
    end
    return { by = by, ready = ready }
end

-- The players a recipient comes to, as the set of their names.
local function reached(of: Cast, who: Types.Recipient): { [string]: boolean }
    local into: { Player } = {}
    Recipients.resolve(into, who, of.ready)
    local out: { [string]: boolean } = {}
    for _, player in into do
        out[player.Name] = true
    end
    return out
end

local function same(got: { [string]: boolean }, wanted: { string })
    local names: { [string]: boolean } = {}
    for _, name in wanted do
        names[name] = true
    end
    Expect.equal(got, names)
end

local function grouped(of: Cast, names: { string }): Types.Group
    local group = Group.new()
    for _, name in names do
        (group :: any):add(of.by[name])
    end
    return group
end

return {
    -- Everybody a fire is allowed to reach, one player, and the same player before they listen.
    Harness.case("recipients.all-and-player", function()
        local of = cast()
        same(reached(of, Recipients.ALL), { "alice", "bob", "carol" })
        same(reached(of, of.by.alice), { "alice" })
        same(reached(of, of.by[ABSENT]), {})
    end),

    -- A list is read back as a set: a player named three times reaches the answer once.
    Harness.case("recipients.list", function()
        local of = cast()
        same(reached(of, { of.by.alice, of.by.carol }), { "alice", "carol" })
        same(reached(of, { of.by.bob, of.by[ABSENT] }), { "bob" })
        same(reached(of, {}), {})

        local twice = { of.by.alice, of.by.bob, of.by.alice, of.by.alice, of.by.bob }
        local into: { Player } = {}
        Recipients.resolve(into, twice, of.ready)
        Expect.equal(#into, 2)
        same(reached(of, twice), { "alice", "bob" })
    end),

    -- A group is walked in the order it holds, a member not listening skipped like anyone else.
    Harness.case("recipients.group", function()
        local of = cast()
        same(reached(of, grouped(of, { "alice", "carol" })), { "alice", "carol" })
        same(reached(of, grouped(of, { "bob", ABSENT })), { "bob" })
        same(reached(of, grouped(of, {})), {})
    end),

    -- Everyone but one in every form, resolved through a ready set the exclusion never saw. Both
    -- ends: excluding everybody is nobody, excluding nobody or somebody not listening is everybody
    -- listening, and an exclusion of an exclusion is everyone the inner one named.
    Harness.case("recipients.except", function()
        local of = cast()
        same(reached(of, Recipients.except(of.by.alice)), { "bob", "carol" })
        same(reached(of, Recipients.except({ of.by.alice, of.by.bob })), { "carol" })
        same(reached(of, Recipients.except(grouped(of, { "carol" }))), { "alice", "bob" })

        same(reached(of, Recipients.except(Recipients.ALL)), {})
        same(reached(of, Recipients.except(of.by[ABSENT])), { "alice", "bob", "carol" })
        same(reached(of, Recipients.except({})), { "alice", "bob", "carol" })

        local inner = Recipients.except(Recipients.except(of.by.alice))
        same(reached(of, inner), { "alice" })
        Expect.equal(Recipients.holds(inner, of.by.alice), true)
        Expect.equal(Recipients.holds(inner, of.by.bob), false)
    end),

    -- Whether a recipient names one player, asked of every form and never of readiness.
    Harness.case("recipients.holds", function()
        local of = cast()
        local alice, bob = of.by.alice, of.by.bob
        Expect.equal(Recipients.holds(Recipients.ALL, alice), true)
        Expect.equal(Recipients.holds(alice, alice), true)
        Expect.equal(Recipients.holds(alice, bob), false)
        Expect.equal(Recipients.holds({ alice, bob }, bob), true)
        Expect.equal(Recipients.holds({ alice }, bob), false)
        Expect.equal(Recipients.holds(grouped(of, { "bob" }), bob), true)
        Expect.equal(Recipients.holds(grouped(of, { "bob" }), alice), false)
        Expect.equal(Recipients.holds(Recipients.except(alice), alice), false)
        Expect.equal(Recipients.holds(Recipients.except(alice), bob), true)
        Expect.equal(Recipients.holds(Recipients.ALL, of.by[ABSENT]), true)
    end),

    -- The array handed back is cut to its count, so a departed player is not held behind it and a
    -- list naming somebody the old tail still holds is read against the count alone.
    Harness.case("recipients.resolve-cuts", function()
        local of = cast()
        local into: { Player } = {}
        Recipients.resolve(into, Recipients.ALL, of.ready)
        Expect.equal(#into, 3)
        Recipients.resolve(into, of.by.alice, of.ready)
        Expect.equal(into, { of.by.alice })
        Recipients.resolve(into, {}, of.ready)
        Expect.equal(next(into), nil)

        Recipients.resolve(into, Recipients.ALL, of.ready)
        of.ready[of.by.carol] = false
        Recipients.resolve(into, Recipients.ALL, of.ready)
        Expect.equal(#into, 2)
        Expect.equal(table.find(into, of.by.carol), nil)

        of.ready[of.by.carol] = true
        Recipients.resolve(into, { of.by.alice, of.by.bob, of.by.carol }, of.ready)
        Recipients.resolve(into, { of.by.carol }, of.ready)
        Expect.equal(into, { of.by.carol })
    end),

    -- Nobody listening, asked of all five forms: an empty array and no raise.
    Harness.case("recipients.nobody-ready", function()
        local of = cast()
        for _, player in of.by do
            of.ready[player] = false
        end
        local group = grouped(of, { "alice", "bob" })
        for _, who in { Recipients.ALL, of.by.alice, { of.by.alice }, group } do
            same(reached(of, who :: Types.Recipient), {})
        end
        same(reached(of, Recipients.except(of.by.alice)), {})
    end),

    -- The shared sentinel is frozen and tagged, and so is every exclusion.
    Harness.case("recipients.all-is-one-value", function()
        Expect.equal(table.isfrozen(Recipients.ALL :: any), true)
        Expect.equal((Recipients.ALL :: any)._all, true)
        Expect.equal(table.isfrozen(Recipients.except(Recipients.ALL) :: any), true)
    end),
}
