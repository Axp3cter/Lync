--!strict
--!optimize 2
-- The wire double every channel suite drives: rounds, audiences, faults and the watch.

local Doubles = require("@fixtures/Doubles")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")

type Heard = { { from: Player?, text: string } }

local function bytes(text: string): buffer
    return buffer.fromstring(text)
end

-- An endpoint listening on one lane, and everything it heard there.
local function listening(of: Doubles.Transport, at: Doubles.Channel): Heard
    local heard: Heard = {}
    of:open()
    of:onReceive(at, function(from: Player?, b: buffer)
        table.insert(heard, { from = from, text = buffer.tostring(b) })
    end)
    return heard
end

return {
    -- A fire queues and lands in the next round, a client's at the server and the server's at the
    -- client it named or at everyone still in the game.
    Harness.case("wire.rounds", function()
        local roster = Doubles.roster()
        local alice, bob = roster:join("alice"), roster:join("bob")
        local wire = Doubles.wire()
        local server = listening(wire:server(), "reliable")
        local toAlice = listening(wire:client(alice), "reliable")
        local toBob = listening(wire:client(bob), "reliable")

        wire:client(alice):fire("reliable", nil, bytes("hi"))
        Expect.equal(#server, 0)
        Expect.equal(wire:deliver(), 1)
        Expect.equal(server, { { from = alice, text = "hi" } })

        wire:server():fire("reliable", bob, bytes("just bob"))
        wire:server():fire("reliable", nil, bytes("all"))
        Expect.equal(wire:deliver(), 2)
        Expect.equal(toAlice, { { text = "all" } })
        Expect.equal(toBob, { { text = "just bob" }, { text = "all" } })

        wire:gone(alice)
        wire:server():fire("reliable", nil, bytes("later"))
        wire:deliver()
        Expect.equal(#toAlice, 1)
        Expect.equal(#toBob, 3)
        Expect.equal(wire:moved().frames, 4)
        Expect.equal(wire:moved().bytes, 2 + 8 + 3 + 5)
    end),

    -- The bytes are copied when fired, a handler's own fire waits for the next round, and a
    -- closed transport hears nothing and may not fire.
    Harness.case("wire.copies-and-closes", function()
        local roster = Doubles.roster()
        local alice = roster:join("alice")
        local wire = Doubles.wire()
        local scratch = bytes("one")
        local client = wire:client(alice)
        client:open()
        client:fire("reliable", nil, scratch)
        buffer.writestring(scratch, 0, "two")

        local server = wire:server()
        local heard: { string } = {}
        server:open()
        server:onReceive("reliable", function(_from: Player?, b: buffer)
            table.insert(heard, buffer.tostring(b))
            if #heard == 1 then server:fire("reliable", alice, bytes("back")) end
        end)
        Expect.equal(wire:deliver(), 1)
        Expect.equal(heard, { "one" })
        Expect.equal(wire:settle(), 1)

        client:close()
        Expect.throws(function()
            client:fire("reliable", nil, scratch)
        end, "a closed transport fired")
        Expect.throws(function()
            client:open()
            client:fire("reliable", alice, scratch)
        end, "a client fired at a recipient")
    end),

    -- Only the unreliable lane draws, and a scripted draw loses, doubles, holds or delivers the
    -- frame it names.
    Harness.case("wire.faults", function()
        local roster = Doubles.roster()
        local alice = roster:join("alice")
        local rolls = Doubles.scripted({ 0.1, 0.4, 0.7, 0.95 })
        local wire = Doubles.wire({ lose = 0.25, double = 0.25, hold = 0.25 }, rolls)
        local heard = listening(wire:server(), "unreliable")
        local sure = listening(wire:server(), "reliable")
        local client = wire:client(alice)
        client:open()
        for _, text in { "lost", "doubled", "held", "clean" } do
            client:fire("unreliable", nil, bytes(text))
        end
        client:fire("reliable", nil, bytes("sure"))

        Expect.equal(wire:deliver(), 4)
        local texts = {}
        for _, one in heard do
            table.insert(texts, one.text)
        end
        Expect.equal(texts, { "doubled", "doubled", "clean" })
        Expect.equal(sure, { { from = alice, text = "sure" } })
        Expect.equal(wire:deliver(), 1)
        Expect.equal(heard[4].text, "held")
        local moved = wire:moved()
        Expect.equal({ moved.lost, moved.doubled, moved.held }, { 1, 1, 1 })

        Expect.throws(function()
            Doubles.wire({ lose = 0.5, double = 0.5, hold = 0.5 }, rolls)
        end, "more than every frame")
    end),

    -- A watcher sees every frame the lane hands over, a frame can be handed without a sender, and
    -- a dump names the lane and the bytes.
    Harness.case("wire.watch-and-hands", function()
        local roster = Doubles.roster()
        local alice = roster:join("alice")
        local wire = Doubles.wire()
        local heard = listening(wire:client(alice), "handshake")
        local seen: { string } = {}
        local stop = wire:watch(function(frame: Doubles.Carried)
            table.insert(seen, Doubles.dumped(frame))
        end)
        wire:hands({ at = "handshake", to = alice, bytes = bytes("\1\255") })
        Expect.equal(seen, { "handshake 01ff" })
        Expect.equal(heard, { { text = "\1\255" } })
        stop()
        wire:hands({ at = "handshake", to = alice, bytes = bytes("\2") })
        Expect.equal(#seen, 1)
        Expect.equal(#heard, 2)
    end),
}
