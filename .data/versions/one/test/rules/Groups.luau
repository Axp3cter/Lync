--!strict
--!optimize 2
-- A group as the membership set it is, and the two recipients that reach nobody.

local Codecs = require("@src/codec")
local Define = require("@src/api/Define")
local Group = require("@src/channel/Group")
local Packet = require("@src/api/Packet")
local Session = require("@src/runtime/Session")

local Doubles = require("@fixtures/Doubles")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")

local NAMESPACE = "groups"

-- The namespace a leave check opens, and the labels its members join under. A leave reaches a
-- group through a roster the session listens to, and `hearing` builds a fresh one per call.
local LEAVING = "leaving"
local LEAVER = "leaver"
local STAYER = "stayer"
local RELEASED = "released"

local DESTROYED = "this group was destroyed"

-- One packet, which the two recipient checks need and nothing else does, on a lane this file
-- reads to see that a fire at nobody leaves nothing.
local WIRE = Doubles.wire()
local DEFINITIONS = Define.define(NAMESPACE, { beat = Packet.new(Codecs.bool()) })
local SERVER = Session.new(NAMESPACE, DEFINITIONS, WIRE:server(), Doubles.roster(), "server")
SERVER:start()

-- Players that are not players, from the one place the stub is built.
local ROSTER = Doubles.roster()

-- Private -------------------------------------------------------------

-- A machine that hears a removal, which is what a leave needs in order to reach a group.
local function hearing(): Doubles.Roster
    local roster = Doubles.roster()
    local defs: any = { pulse = Packet.new(Codecs.bool()) }
    Session.new(LEAVING, defs, Doubles.wire():server(), roster, "server"):start()
    return roster
end

-- A member, joined once and shared, because a label is spent once on a roster.
local function member(label: string): Player
    return ROSTER:named(label) or ROSTER:join(label)
end

-- What a fire at `to` put on the lane, which for a recipient nobody stands behind is nothing.
local function carried(to: any): number
    local before = WIRE:moved().frames
    DEFINITIONS.beat:fireClient(to, true)
    SERVER:flush()
    return WIRE:moved().frames - before
end

-- Public --------------------------------------------------------------

return {
    -- Membership, which is what a group is: a set rather than a list.
    Harness.case("group.membership", function()
        local of = Group.new()
        local alice, bob = member("alice"), member("bob")
        Expect.equal(of:has(alice), false)

        of:add(alice)
        Expect.equal(of:has(alice), true)
        Expect.equal(of:has(bob), false)
        of:add(alice)
        Expect.equal(#of, 1)

        of:remove(alice)
        Expect.equal(of:has(alice), false)
        of:remove(alice)
        Expect.equal(#of, 0)
    end),

    -- The count, which moves with the membership and not with the calls.
    Harness.case("group.len", function()
        local of = Group.new()
        Expect.equal(#of, 0)
        for index, label in { "alice", "bob", "carol" } do
            of:add(member(label))
            Expect.equal(#of, index)
        end
        of:remove(member("bob"))
        Expect.equal(#of, 2)
        Expect.equal(of:size(), 2)
    end),

    -- The walk, held from both ends: every member is reached, each once, and nobody else is.
    Harness.case("group.iterate", function()
        local of = Group.new()
        local want = { alice = true, carol = true }
        of:add(member("alice"))
        of:add(member("carol"))

        local seen, count = {}, 0
        for _, player in of do
            Expect.holds(seen[player] == nil, `{player.Name} was walked twice`)
            Expect.holds(want[player.Name] == true, `{player.Name} is in no group`)
            seen[player] = true
            count += 1
        end
        Expect.equal(count, 2)
    end),

    -- A group released while a live one holds the same member: the release takes it out of the
    -- sweep's set, so the sweep still reaches every group behind it.
    Harness.case("group.destroy", function()
        local roster = hearing()
        local released, kept = Group.new(), Group.new()
        local leaver = roster:join(RELEASED)
        released:add(leaver)
        kept:add(leaver)

        released:destroy()
        roster:leave(leaver)
        Expect.equal(kept:has(leaver), false)
    end),

    -- A group after it was released: every later call throws rather than answering about a group
    -- that no longer exists.
    Harness.case("group.use-after-destroy", function()
        local of = Group.new()
        local alice = member("alice")
        of:add(alice)
        of:destroy()

        Expect.throws(function()
            of:add(alice)
        end, DESTROYED)
        Expect.throws(function()
            of:remove(alice)
        end, DESTROYED)
        Expect.throws(function()
            of:has(alice)
        end, DESTROYED)
        Expect.throws(function()
            of:destroy()
        end, DESTROYED)
    end),

    -- A fire at a group that holds nobody: not an error, and nothing leaves the machine.
    Harness.case("recip.empty", function()
        Expect.equal(carried(Group.new()), 0)
    end),

    -- A member who leaves the game.
    Harness.case("group.auto-drop", function()
        local roster = hearing()
        local of = Group.new()
        local leaver, stayer = roster:join(LEAVER), roster:join(STAYER)
        of:add(leaver)
        of:add(stayer)
        Expect.equal(#of, 2)

        roster:leave(leaver)
        Expect.equal(of:has(leaver), false)
        Expect.equal(of:has(stayer), true)
        Expect.equal(#of, 1)

        local seen: { [Player]: boolean } = {}
        for _, player in of do
            seen[player] = true
        end
        Expect.equal(seen[leaver], nil)
        Expect.equal(seen[stayer], true)
    end),

    -- A fire at a player the connected set does not hold, which earns what an empty group earns.
    Harness.case("recip.departed", function()
        Expect.equal(carried(member("gone")), 0)
    end),
}
