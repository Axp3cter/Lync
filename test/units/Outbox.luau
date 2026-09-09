--!strict
--!optimize 2
-- Everything queued as the frames it becomes: merged by class and sequence on the reliable lane,
-- split under the cap on the lossy one, and every block let go after.

local Blocks = require("@src/channel/Blocks")
local Link = require("@src/channel/Link")
local Outbox = require("@src/channel/Outbox")
local Protocol = require("@src/wire/Protocol")

local Doubles = require("@fixtures/Doubles")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")

local ROOM = 2048

type Seen = { { at: string, to: Player?, text: string, refs: number? } }

-- A server endpoint on a wire, and everything the wire carried from it.
local function rigged(): (Link.Link, Doubles.Wire, Seen, Doubles.Roster)
    local roster = Doubles.roster()
    local wire = Doubles.wire()
    local link = Link.new("Arena", "server", ROOM, wire:server())
    Link.open(link)
    local seen: Seen = {}
    wire:watch(function(frame: Doubles.Carried)
        table.insert(seen, {
            at = frame.at,
            to = frame.to,
            text = buffer.tostring(frame.bytes),
            refs = if frame.refs == nil then nil else #frame.refs,
        })
    end)
    return link, wire, seen, roster
end

local function block(
    link: Link.Link,
    text: string,
    class: number,
    refs: { Instance }?
): Blocks.Block
    buffer.writestring(link.scratch, 0, text)
    return Blocks.sealed(link.scratch, #text, class, Link.next(link), refs)
end

return {
    -- With nothing of anyone's own queued, one frame goes to everybody, its blocks in class order
    -- and in sequence within a class, and every bucket is empty after.
    Harness.case("outbox.shared", function()
        local link, wire, seen = rigged()
        local late = block(link, "delta", Blocks.DELTA)
        local packet = block(link, "packet", Blocks.PACKET)
        local reply = block(link, "reply", Blocks.RESPONSE)
        Outbox.shared(link, late)
        Outbox.shared(link, packet)
        Outbox.shared(link, reply)
        Outbox.fire(link)
        wire:deliver()
        Expect.equal(seen, { { at = "reliable", text = "replypacketdelta" } })
        Expect.equal({ late.rc, packet.rc, reply.rc }, { 0, 0, 0 })
        Expect.equal(#link.shared[Blocks.PACKET], 0)
        Expect.equal(Link.next(link), 0)

        Outbox.fire(link)
        wire:deliver()
        Expect.equal(#seen, 1)
    end),

    -- Once any client has blocks of their own, every ready client gets a frame of their own, the
    -- shared blocks merged in by sequence, and a block for many is held once per recipient.
    Harness.case("outbox.targeted", function()
        local link, wire, seen, roster = rigged()
        local alice, bob = roster:join("alice"), roster:join("bob")
        Link.admit(link, alice)
        Link.admit(link, bob)
        local first = block(link, "A", Blocks.PACKET)
        local mine = block(link, "b", Blocks.PACKET)
        local second = block(link, "C", Blocks.PACKET)
        local both = block(link, "d", Blocks.PACKET)
        Outbox.shared(link, first)
        Outbox.targeted(link, { alice }, 1, mine)
        Outbox.shared(link, second)
        Outbox.targeted(link, { alice, bob }, 2, both)
        Expect.equal(both.rc, 2)

        Outbox.fire(link)
        wire:deliver()
        local texts = {}
        for _, frame in seen do
            texts[(frame.to :: Player).Name] = frame.text
        end
        Expect.equal(texts, { alice = "AbCd", bob = "ACd" })
        Expect.equal({ first.rc, mine.rc, second.rc, both.rc }, { 0, 0, 0, 0 })
        Expect.equal(#link.divergent[alice][Blocks.PACKET], 0)

        -- No block carried an instance, so neither frame carries a sidecar, empty or otherwise.
        for _, frame in seen do
            Expect.equal(frame.refs, nil)
        end

        -- One client's own block carrying an instance puts a sidecar beside that client's frame
        -- alone, and the shared blocks beside it add nothing to it.
        table.clear(seen)
        local held: { Instance } = { Instance.new("Folder") }
        Outbox.shared(link, block(link, "E", Blocks.PACKET))
        Outbox.targeted(link, { alice }, 1, block(link, "f", Blocks.PACKET, held))
        Outbox.fire(link)
        wire:deliver()
        local carried = {}
        for _, frame in seen do
            carried[(frame.to :: Player).Name] = { text = frame.text, refs = frame.refs }
        end
        Expect.equal(carried, { alice = { text = "Ef", refs = 1 }, bob = { text = "E" } })

        -- A block for nobody is released on the spot.
        local nobody = block(link, "x", Blocks.PACKET)
        Outbox.targeted(link, {}, 0, nobody)
        Expect.equal(nobody.rc, 0)
    end),

    -- The lossy lane splits a queue into fires under the cap, shared and per client apart, and a
    -- frame with an instance carries its refs beside it.
    Harness.case("outbox.lossy", function()
        local link, wire, seen, roster = rigged()
        local alice = roster:join("alice")
        Link.admit(link, alice)
        -- The first two blocks land exactly on the cap, which one fire may carry, and the third
        -- is what tips the next fire open.
        local cap = Protocol.UNRELIABLE_CAP
        local wide = string.rep("w", cap - 1)
        Outbox.loose(link, block(link, wide, Blocks.LOOSE))
        Outbox.loose(link, block(link, "c", Blocks.LOOSE))
        Outbox.loose(link, block(link, "ab", Blocks.LOOSE))
        local refs: { Instance } = { Instance.new("Folder") }
        Outbox.looseTo(link, { alice }, 1, block(link, "mine", Blocks.LOOSE, refs))

        Outbox.fire(link)
        wire:deliver()
        Expect.equal(#seen, 3)
        Expect.equal(seen[1], { at = "unreliable", text = wide .. "c" })
        Expect.equal(seen[2], { at = "unreliable", text = "ab" })
        Expect.equal(seen[3], { at = "unreliable", to = alice, text = "mine", refs = 1 })
        Expect.equal(#link.sharedLossy, 0)
        Expect.equal(#link.divergentLossy[alice], 0)
    end),

    -- An endpoint not sending fires nothing, and a frame past the ceiling is a raise naming it.
    Harness.case("outbox.guards", function()
        local link, wire, seen = rigged()
        Outbox.shared(link, block(link, "held", Blocks.PACKET))
        link.sending = false
        Outbox.fire(link)
        wire:deliver()
        Expect.equal(#seen, 0)
        Expect.equal(#link.shared[Blocks.PACKET], 1)
        link.sending = true

        local huge = buffer.create(Protocol.MAX_FIRE + 1)
        Outbox.shared(link, Blocks.sealed(huge, buffer.len(huge), Blocks.PACKET, 1, nil))
        Expect.throws(function()
            Outbox.fire(link)
        end, `past the {Protocol.MAX_FIRE}`)
    end),

    -- A run of blocks past the ceiling goes out as several frames, cut between blocks, each
    -- under the ceiling and all in order, and the queue is empty after.
    Harness.case("outbox.splits-past-the-ceiling", function()
        local link, wire, seen = rigged()
        local each = ROOM - 48
        local count = Protocol.MAX_FIRE // each + 3
        for index = 1, count do
            local text = string.format("%05d", index) .. string.rep("b", each - 5)
            Outbox.shared(link, block(link, text, Blocks.PACKET))
        end
        Outbox.fire(link)
        wire:deliver()

        Expect.holds(#seen > 1, `a run of {count * each} bytes went out as one frame`)
        local carried, expected = 0, 1
        for _, frame in seen do
            Expect.equal(frame.at, "reliable")
            Expect.holds(#frame.text <= Protocol.MAX_FIRE, `a frame of {#frame.text} bytes`)
            Expect.equal(#frame.text % each, 0)
            for at = 1, #frame.text, each do
                Expect.equal(tonumber(string.sub(frame.text, at, at + 4)), expected)
                expected += 1
            end
            carried += #frame.text
        end
        Expect.equal(carried, count * each)
        Expect.equal(#link.shared[Blocks.PACKET], 0)
    end),
}
