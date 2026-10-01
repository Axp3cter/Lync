--!strict
--!optimize 2
-- Who sees a partition, and who gained or lost it between one flush and the next.

local Audience = require("@src/state/Audience")
local Recipients = require("@src/channel/Recipients")

local Doubles = require("@fixtures/Doubles")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")

local KEY = "red"

type Cast = { by: { [string]: Player }, ready: Recipients.Ready }

local function cast(): Cast
    local roster = Doubles.roster()
    local by, ready = {}, {}
    for _, label in { "alice", "bob", "carol" } do
        local player = roster:join(label)
        by[label] = player
        ready[player] = true
    end
    return { by = by, ready = ready }
end

local function names(players: { Player }): { [string]: boolean }
    local out = {}
    for _, player in players do
        out[player.Name] = true
    end
    return out
end

local function set(...: string): { [string]: boolean }
    local out = {}
    for _, name in { ... } do
        out[name] = true
    end
    return out
end

return {
    -- A key nobody assigned is nobody's: its diff holds no one and reports no change.
    Harness.case("audience.open", function()
        local of = Audience.new()
        local who = cast()
        Expect.equal(Audience.everyone(of, KEY), false)
        Audience.diff(of, KEY, who.ready)
        Expect.equal(#Audience.members(of, KEY), 0)
        Expect.equal(#of.gained, 0)
        Expect.equal(#of.lost, 0)
    end),

    -- A key nobody held yet gains whoever it is first assigned to and loses nobody. Diffing again
    -- with nothing moved changes nothing, and a member no longer ready drops out without being
    -- reported lost.
    Harness.case("audience.narrows", function()
        local of = Audience.new()
        local who = cast()
        Audience.assign(of, KEY, { who.by.alice, who.by.bob })
        Expect.equal(Audience.everyone(of, KEY), false)
        Audience.diff(of, KEY, who.ready)
        Expect.equal(names(Audience.members(of, KEY)), set("alice", "bob"))
        Expect.equal(names(of.gained), set("alice", "bob"))
        Expect.equal(#of.lost, 0)

        Audience.diff(of, KEY, who.ready)
        Expect.equal(#of.gained, 0)
        Expect.equal(#of.lost, 0)

        who.ready[who.by.bob] = nil
        Audience.diff(of, KEY, who.ready)
        Expect.equal(names(Audience.members(of, KEY)), set("alice"))
        Expect.equal(#of.lost, 0)
    end),

    -- Reassigning reports who gained and who lost, and a key assigned to everybody before its
    -- first diff is gained by everybody, since nobody held it.
    Harness.case("audience.moves", function()
        local of = Audience.new()
        local who = cast()
        Audience.assign(of, KEY, who.by.alice)
        Audience.diff(of, KEY, who.ready)
        Expect.equal(names(of.gained), set("alice"))
        Expect.equal(#of.lost, 0)
        Audience.assign(of, KEY, { who.by.bob, who.by.carol })
        Audience.diff(of, KEY, who.ready)
        Expect.equal(names(of.gained), set("bob", "carol"))
        Expect.equal(names(of.lost), set("alice"))

        local fresh = Audience.new()
        Audience.assign(fresh, KEY, Recipients.ALL)
        Audience.diff(fresh, KEY, who.ready)
        Expect.equal(names(fresh.gained), set("alice", "bob", "carol"))
        Expect.equal(#fresh.lost, 0)
        Audience.assign(fresh, KEY, who.by.carol)
        Audience.diff(fresh, KEY, who.ready)
        Expect.equal(names(fresh.lost), set("alice", "bob"))
        Expect.equal(#fresh.gained, 0)
    end),

    -- Widening back to everybody gains whoever was not holding it, and the key keeps no list
    -- after, so a later narrowing seeds everybody ready again.
    Harness.case("audience.widens", function()
        local of = Audience.new()
        local who = cast()
        Audience.assign(of, KEY, who.by.alice)
        Audience.diff(of, KEY, who.ready)
        Audience.assign(of, KEY, Recipients.ALL)
        Audience.diff(of, KEY, who.ready)
        Expect.equal(names(of.gained), set("bob", "carol"))
        Expect.equal(#of.lost, 0)
        Expect.equal(next(of.held[KEY]), nil)
        Expect.equal(Audience.everyone(of, KEY), true)

        Audience.diff(of, KEY, who.ready)
        Expect.equal(#Audience.members(of, KEY), 0)
        Audience.assign(of, KEY, who.by.bob)
        Audience.diff(of, KEY, who.ready)
        Expect.equal(names(of.lost), set("alice", "carol"))
        Expect.equal(#of.gained, 0)
    end),
}
