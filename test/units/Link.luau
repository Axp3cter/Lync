--!strict
--!optimize 2
-- One namespace's endpoint: the clients it may reach, the queues each holds, and the release.

local Blocks = require("@src/channel/Blocks")
local Link = require("@src/channel/Link")

local Doubles = require("@fixtures/Doubles")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")

local ROOM = 64

local function queued(): Blocks.Block
    local b = buffer.create(4)
    return Blocks.sealed(b, 4, Blocks.PACKET, 0, nil)
end

return {
    -- A fresh endpoint: its own buffers of the room asked for, a server sending from the start and
    -- a client not until told, and one reliable bucket per class.
    Harness.case("link.new", function()
        local wire = Doubles.wire()
        local server = Link.new("Arena", "server", ROOM, wire:server())
        Expect.equal(server.isServer, true)
        Expect.equal(server.sending, true)
        Expect.equal(buffer.len(server.scratch), ROOM)
        Expect.equal(buffer.len(server.pending), ROOM)
        Expect.holds(server.scratch ~= server.pending, "the run shares the scratch")
        Expect.equal(#server.shared, Blocks.CLASSES)
        Expect.equal(next(server.ready), nil)

        local roster = Doubles.roster()
        local client = Link.new("Arena", "client", ROOM, wire:client(roster:join("alice")))
        Expect.equal(client.isServer, false)
        Expect.equal(client.sending, false)
    end),

    -- Admitting a client makes it ready and gives it queues. Dropping one releases everything
    -- queued for it and forgets it, and dropping a stranger is nothing.
    Harness.case("link.admit-and-drop", function()
        local roster = Doubles.roster()
        local alice, bob = roster:join("alice"), roster:join("bob")
        local link = Link.new("Arena", "server", ROOM, Doubles.wire():server())
        Link.admit(link, alice)
        Expect.equal(link.ready[alice], true)
        Expect.equal(#link.divergent[alice], Blocks.CLASSES)
        Expect.equal(link.divergentLossy[alice], {})

        local sure, loose = queued(), queued()
        table.insert(link.divergent[alice][Blocks.PACKET], sure)
        table.insert(link.divergentLossy[alice], loose)
        Link.drop(link, alice)
        Expect.equal(link.ready[alice], nil)
        Expect.equal(link.divergent[alice], nil)
        Expect.equal(link.divergentLossy[alice], nil)
        Expect.equal(sure.rc, 0)
        Expect.equal(loose.rc, 0)
        Link.drop(link, bob)
    end),

    -- The block sequence counts up until a flush rewinds it.
    Harness.case("link.next-and-rewind", function()
        local link = Link.new("Arena", "server", ROOM, Doubles.wire():server())
        Expect.equal({ Link.next(link), Link.next(link), Link.next(link) }, { 0, 1, 2 })
        Link.rewind(link)
        Expect.equal(Link.next(link), 0)
    end),

    -- Opening opens the transport. Closing drains every queue, drops everyone, empties the
    -- audience, stops sending and closes the transport.
    Harness.case("link.open-and-close", function()
        local roster = Doubles.roster()
        local alice = roster:join("alice")
        local wire = Doubles.wire()
        local link = Link.new("Arena", "server", ROOM, wire:server())
        Link.open(link)
        link.transport:fire("reliable", nil, buffer.create(1))
        Expect.equal(wire:deliver(), 1)

        Link.admit(link, alice)
        table.insert(link.audience, alice)
        local shared, lossy, mine = queued(), queued(), queued()
        table.insert(link.shared[Blocks.DELTA], shared)
        table.insert(link.sharedLossy, lossy)
        table.insert(link.divergent[alice][Blocks.REQUEST], mine)
        Link.close(link)
        Expect.equal(link.sending, false)
        Expect.equal({ shared.rc, lossy.rc, mine.rc }, { 0, 0, 0 })
        Expect.equal(#link.shared[Blocks.DELTA], 0)
        Expect.equal(#link.sharedLossy, 0)
        Expect.equal(next(link.ready), nil)
        Expect.equal(next(link.divergent), nil)
        Expect.equal(#link.audience, 0)
        Expect.throws(function()
            link.transport:fire("reliable", nil, buffer.create(1))
        end, "a closed transport fired")
    end),
}
