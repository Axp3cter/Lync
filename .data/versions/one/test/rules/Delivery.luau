--!strict
--!optimize 2
-- What a delivery modifier changes about a frame, asked on a lane that can lose and reorder.

local Codecs = require("@src/codec")
local Log = require("@src/kernel/Log")
local Packet = require("@src/api/Packet")
local Recipients = require("@src/channel/Recipients")
local Session = require("@src/runtime/Session")
local Types = require("@src/Types")

local Doubles = require("@fixtures/Doubles")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")
local Replica = require("@test/harness/Replica")

local SPACE = "delivery"

-- The one client, because every claim here is about a frame rather than an audience.
local SENDER = "alice"
local RUN_PACKET = "run"

-- Six packets, five of them over one codec, so the only thing that differs between any two of
-- those is what a caller chained onto the definition. The sixth carries nothing at all.
local SURE = "sure"
local LOSSY = "lossy"
local LATEST = "latest"
local STAMPED = "stamped"
local BOTH = "both"
local BARE = "bare"
local EVERY = table.freeze({ SURE, LOSSY, LATEST, STAMPED, BOTH, BARE })

-- The two patterns a check hands the lane: this frame and not the next, or every one of them.
local ALTERNATING = table.freeze({ Doubles.FAULTED, Doubles.CLEAN })
local EVERY_FRAME = table.freeze({ Doubles.FAULTED })

-- The fraction each check hands the one band it opens.
local HALF = 0.5
local ALWAYS = 1

-- The clients a broadcast is counted over, which is more than one so that one encode can be fewer.
local AUDIENCE = table.freeze({ "alice", "bob", "carol" })

-- Fires a lossy run makes, an even count so the pattern lands on the same half every time.
local RUN = 6

-- What a fire carries, and the two values a latest-wins stream carries in order.
local CARRIED = 7
local EARLIER = 11
local LATER = 12

-- Fires enough that the first sender's place on the ring is well past where a new one starts.
local TALKED = 8
local LOUD = 99

-- Past any cap a block of this namespace could have, a burst of stamped fires, and a run of fires
-- with the one a listener comes apart on.
local MANY = 200
local BURST = 4
local FEW = 5
local BREAKS = 3

-- The value a validator turns away, and why.
local TURNED = 0
local REFUSED = "this value is not welcome"

-- A payload as a listener was handed it, with the send time a stamped definition adds.
type Held = { read value: number, read sent: number? }

type Run = {
    read wire: Doubles.Wire,
    read player: Player,
    read server: Session.Session,
    read defs: any,
    read heard: { [string]: { Held } },
}

-- Two machines on one lane over one definition, with whatever the client attached before start.
type Pair = {
    read wire: Doubles.Wire,
    read player: Player,
    read server: Session.Session,
    read ours: any,
}

-- Private -------------------------------------------------------------

local function count(): Types.Codec<number>
    return Codecs.int(0, 100)
end

-- Every delivery a packet can declare, and the one pair of them that combines.
local function defined(): any
    return {
        [SURE] = Packet.new(count()),
        [LOSSY] = Packet.new(count()):unreliable(),
        [LATEST] = Packet.new(count()):newest(),
        [STAMPED] = Packet.new(count()):timestamped(),
        [BOTH] = Packet.new(count()):timestamped():unreliable(),
        [BARE] = Packet.new(Codecs.empty()),
    }
end

-- Two machines on one lane, the client listening to everything before it starts, which is both
-- where a caller writes a listener and the order that decides what a fresh one is told.
local function opened(chance: Doubles.Faults?, draw: (() -> number)?): Run
    local wire = Doubles.wire(chance, draw)
    local roster = Doubles.roster()
    local serverDefs = defined()
    local server = Session.new(SPACE, serverDefs, wire:server(), roster, "server")
    server:start()

    local player = roster:join(SENDER)
    local clientDefs = defined()
    local client = Session.new(SPACE, clientDefs, wire:client(player), roster, "client")
    local heard: { [string]: { Held } } = {}
    for _, name in EVERY do
        local into: { Held } = {}
        heard[name] = into
        clientDefs[name]:onClient(function(value: number, sent: number?)
            table.insert(into, { value = value, sent = sent })
        end)
    end
    client:start()
    wire:settle()
    return { wire = wire, player = player, server = server, defs = serverDefs, heard = heard }
end

-- One fire, flushed, and carried as far as the lane will carry it.
local function fires(of: Run, name: string, value: number)
    of.defs[name]:fireClient(of.player, value)
    of.server:flush()
    of.wire:settle()
end

-- Two machines over one packet of `codec`, the client's listeners attached by `listens` before it
-- starts.
local function paired(codec: Types.Codec<any>, listens: (packet: any) -> ()): Pair
    local wire = Doubles.wire()
    local roster = Doubles.roster()
    local ours: any = { [RUN_PACKET] = Packet.new(codec) }
    local server = Session.new(SPACE, ours, wire:server(), roster, "server")
    server:start()

    local player = roster:join(SENDER)
    local defs: any = { [RUN_PACKET] = Packet.new(codec) }
    listens(defs[RUN_PACKET])
    Session.new(SPACE, defs, wire:client(player), roster, "client"):start()
    wire:settle()
    return { wire = wire, player = player, server = server, ours = ours[RUN_PACKET] }
end

-- Every value fired at the client in one flush, and carried.
local function burst(of: Pair, values: { number })
    for _, value in values do
        of.ours:fireClient(of.player, value)
    end
    of.server:flush()
    of.wire:settle()
end

-- Public --------------------------------------------------------------

return {
    -- An `:unreliable()` stream over a lane that drops every other frame.
    Harness.case("packet.unreliable-lossy", function()
        local of = opened({ lose = HALF, double = 0, hold = 0 }, Doubles.scripted(ALTERNATING))
        for index = 1, RUN do
            of.defs[LOSSY]:fireClient(of.player, index)
            of.defs[SURE]:fireClient(of.player, index)
            of.server:flush()
            of.wire:settle()
        end
        Expect.holds(of.wire:moved().lost > 0, "the lane was asked to lose and lost nothing")

        local ordered = of.heard[SURE]
        Expect.equal(#ordered, RUN)
        for index = 1, RUN do
            Expect.equal(ordered[index].value, index)
        end
        local survived = of.heard[LOSSY]
        Expect.equal(#survived, RUN // 2)
        for at, one in survived do
            Expect.equal(one.value, at * 2)
        end
    end),

    -- A `:newest()` stream with nothing new in it, flushed over and over, sends nothing.
    Harness.case("packet.newest-idle", function()
        local of = opened()
        fires(of, LATEST, CARRIED)
        Expect.equal(#of.heard[LATEST], 1)

        local before = of.wire:moved()
        for _ = 1, RUN do
            of.server:flush()
            of.wire:settle()
        end
        local after = of.wire:moved()
        Expect.equal(after.frames, before.frames)
        Expect.equal(after.bytes, before.bytes)
        Expect.equal(#of.heard[LATEST], 1)
    end),

    -- A `:newest()` frame that arrives after the one that replaced it is not applied.
    Harness.case("packet.newest-stale", function()
        local of = opened({ lose = 0, double = 0, hold = HALF }, Doubles.scripted(ALTERNATING))
        of.defs[LATEST]:fireClient(of.player, EARLIER)
        of.server:flush()
        of.defs[LATEST]:fireClient(of.player, LATER)
        of.server:flush()

        of.wire:deliver()
        Expect.holds(of.wire:moved().held > 0, "the lane was asked to hold and held nothing")
        local held = of.heard[LATEST]
        Expect.equal(#held, 1)
        Expect.equal(held[1].value, LATER)

        of.wire:settle()
        Expect.equal(#held, 1)
    end),

    -- A `:newest()` frame the lane hands over twice: the ring reads the second copy as a sequence
    -- it has already seen.
    Harness.case("packet.newest-doubled", function()
        local of = opened({ lose = 0, double = ALWAYS, hold = 0 }, Doubles.scripted(EVERY_FRAME))
        of.defs[LATEST]:fireClient(of.player, CARRIED)
        of.defs[SURE]:fireClient(of.player, CARRIED)
        of.server:flush()
        of.wire:settle()

        Expect.holds(
            of.wire:moved().doubled > 0,
            "the lane was asked to double and doubled nothing"
        )
        local latest = of.heard[LATEST]
        Expect.equal(#latest, 1)
        Expect.equal(latest[1].value, CARRIED)
        Expect.equal(#of.heard[SURE], 1)
    end),

    -- `:timestamped()` beside a delivery modifier, and both applying: one says how a frame travels
    -- and the other what rides with the payload.
    Harness.case("packet.timestamped-stacks", function()
        local kept = opened()
        fires(kept, STAMPED, CARRIED)
        fires(kept, BOTH, CARRIED)
        for _, name in { STAMPED, BOTH } do
            local one = kept.heard[name][1]
            Expect.holds(one ~= nil, `{name} did not arrive at all`)
            Expect.holds(typeof(one.sent) == "number", `{name} arrived with no stamp`)
        end

        local gone = opened({ lose = ALWAYS, double = 0, hold = 0 }, Doubles.scripted(EVERY_FRAME))
        fires(gone, STAMPED, CARRIED)
        fires(gone, BOTH, CARRIED)
        Expect.equal(#gone.heard[STAMPED], 1)
        Expect.equal(#gone.heard[BOTH], 0)
    end),

    -- One fire at everybody, and how many times the value is turned into bytes.
    Harness.case("packet.encode-once", function()
        local encodes, decodes = 0, 0
        local function counted(): any
            local held = count():as(function(value: number): number
                decodes += 1
                return value
            end, function(value: number): number
                encodes += 1
                return value
            end)
            return { [SURE] = Packet.new(held) }
        end

        local of = Replica.open({ space = SPACE, defined = counted }, AUDIENCE[1])
        for at = 2, #AUDIENCE do
            Replica.joins(of, AUDIENCE[at])
        end
        local heard = {}
        for _, held in of.viewers do
            held.machine.defs[SURE]:onClient(function(value: number)
                table.insert(heard, value)
            end)
        end

        encodes, decodes = 0, 0
        of.server.defs[SURE]:fireClient(Recipients.ALL, CARRIED)
        Replica.ships(of)

        Expect.equal(encodes, 1)
        Expect.equal(decodes, #AUDIENCE)
        Expect.equal(#heard, #AUDIENCE)
        for _, value in heard do
            Expect.equal(value, CARRIED)
        end
    end),

    -- Two senders on the lane that reorders, each with a place on the ring of its own, so the
    -- first frame from a quiet machine is not read as behind the talkative one.
    Harness.case("packet.newest-per-sender", function()
        local of = Replica.open({ space = SPACE, defined = defined }, SENDER)
        local second = Replica.joins(of, "bob")
        local heard: { number } = {}
        local whose: { Player } = {}
        of.server.defs[LATEST]:onServer(function(value: number, who: Player)
            table.insert(heard, value)
            table.insert(whose, who)
        end)

        for step = 1, TALKED do
            of.client.defs[LATEST]:fireServer(step)
            of.client.session:flush()
            of.wire:settle()
        end
        Expect.equal(#heard, TALKED)

        second.machine.defs[LATEST]:fireServer(LOUD)
        second.machine.session:flush()
        of.wire:settle()

        Expect.equal(#heard, TALKED + 1)
        Expect.equal(heard[TALKED + 1], LOUD)
        Expect.equal(whose[1], of.player)
        Expect.equal(whose[TALKED + 1], second.player)
    end),

    -- The client's fire made on a server, refused by the name of the call.
    Harness.case("packet.wrong-side-fire", function()
        local of = Replica.open({ space = SPACE, defined = defined }, SENDER)
        Expect.throws(function()
            of.server.defs[SURE]:fireServer(CARRIED)
        end, "is a client's call, and this is the server")
    end),

    -- A packet carrying nothing, fired without a value and heard without one.
    Harness.case("packet.bare-carries-the-call-alone", function()
        local of = opened()
        for _ = 1, RUN do
            of.defs[BARE]:fireClient(of.player)
        end
        of.server:flush()
        of.wire:settle()

        local held = of.heard[BARE]
        Expect.equal(#held, RUN)
        for _, one in held do
            Expect.equal(one.value, nil)
        end
    end),

    -- A block of nothings and a block carrying a value in one frame: a payload of nothing moves
    -- the offset by nothing.
    Harness.case("packet.bare-leaves-what-follows-it-alone", function()
        local of = opened()
        for _ = 1, RUN do
            of.defs[BARE]:fireClient(of.player)
        end
        of.defs[SURE]:fireClient(of.player, CARRIED)
        of.server:flush()
        of.wire:settle()

        Expect.equal(#of.heard[BARE], RUN)
        local after = of.heard[SURE]
        Expect.equal(#after, 1)
        Expect.equal(after[1].value, CARRIED)
    end),

    -- Fired with a value anyway, which changes nothing: what reaches the other machine is the call.
    Harness.case("packet.bare-drops-what-it-is-handed", function()
        local of = opened()
        of.defs[BARE]:fireClient(of.player, CARRIED)
        of.server:flush()
        of.wire:settle()

        local held = of.heard[BARE]
        Expect.equal(#held, 1)
        Expect.equal(held[1].value, nil)
    end),

    -- More fires of one definition in one flush than a block may hold: the next block opens.
    Harness.case("packet.run-past-its-cap", function()
        local of = opened()
        for index = 1, MANY do
            of.defs[SURE]:fireClient(of.player, index % 101)
        end
        of.server:flush()
        of.wire:settle()

        local held = of.heard[SURE]
        Expect.equal(#held, MANY)
        for index = 1, MANY do
            Expect.equal(held[index].value, index % 101)
        end
    end),

    -- A burst of fires from a definition that declared an instant: each fire owes its listener
    -- the moment it was sent, so these cannot share a header.
    Harness.case("packet.stamped-burst-keeps-each", function()
        local of = opened()
        for index = 1, BURST do
            of.defs[STAMPED]:fireClient(of.player, index)
        end
        of.server:flush()
        of.wire:settle()

        local held = of.heard[STAMPED]
        Expect.equal(#held, BURST)
        for index = 1, BURST do
            Expect.equal(held[index].value, index)
            Expect.holds(held[index].sent ~= nil, `the {index} of {BURST} carried no instant`)
        end
    end),

    -- A newest fire and a plain one in the one flush: a newest block spells a sequence where a
    -- running block spells a count, and neither eats the other.
    Harness.case("packet.newest-does-not-eat-the-frame", function()
        local of = opened()
        of.defs[LATEST]:fireClient(of.player, CARRIED)
        of.defs[SURE]:fireClient(of.player, CARRIED)
        of.server:flush()
        of.wire:settle()

        Expect.equal(#of.heard[LATEST], 1)
        Expect.equal(of.heard[LATEST][1].value, CARRIED)
        Expect.equal(#of.heard[SURE], 1)
        Expect.equal(of.heard[SURE][1].value, CARRIED)
    end),

    -- A run of fires reaching two listeners, one of which comes apart partway along. Every
    -- listener is walked, one that raises on the third is still handed the fourth, and the raise
    -- is reported rather than swallowed.
    Harness.case("packet.run-reaches-every-listener", function()
        local mine: { number } = {}
        local theirs: { number } = {}
        local of = paired(count(), function(packet: any)
            packet:onClient(function(value: number)
                table.insert(mine, value)
                if value == BREAKS then error("this one came apart", 0) end
            end)
            packet:onClient(function(value: number)
                table.insert(theirs, value)
            end)
        end)

        local said: { string } = {}
        local watching = Log.onLog(function(kind: string, message: string)
            if kind == "error" then table.insert(said, message) end
        end)
        local values = {}
        for index = 1, FEW do
            table.insert(values, index)
        end
        burst(of, values)
        watching:disconnect()

        Expect.equal(#said, 1)
        Expect.equal(#mine, FEW)
        Expect.equal(#theirs, FEW)
        Expect.equal(mine[FEW], FEW)
        Expect.equal(theirs[FEW], FEW)
    end),

    -- A run one of whose payloads the far side turns away is handed over without it.
    Harness.case("packet.run-leaves-out-what-was-turned-away", function()
        local codec = count():validate(function(value: number): string?
            return if value == TURNED then REFUSED else nil
        end)
        -- Counted rather than gathered, because a payload handed over as nothing is a call that
        -- `table.insert` would decline to record.
        local seen: { number } = {}
        local calls = 0
        local of = paired(codec, function(packet: any)
            packet:onClient(function(value: number)
                calls += 1
                seen[calls] = value
            end)
        end)

        burst(of, { 1, TURNED, 2 })
        Expect.equal(calls, 2)
        Expect.equal(seen[1], 1)
        Expect.equal(seen[2], 2)
    end),

    -- What a validator is told about the arrival before this one: a first arrival has none, and
    -- every one after names when the one before it came.
    Harness.case("packet.a-block-leaves-behind-when-it-last-arrived", function()
        local seen: { number? } = {}
        local calls = 0
        local codec = count():validate(function(_value: number, ctx: Types.ValidateContext): string?
            calls += 1
            seen[calls] = ctx.last
            return nil
        end)
        local of = paired(codec, function(packet: any)
            packet:onClient(function() end)
        end)

        for round = 1, 3 do
            burst(of, { round })
        end
        Expect.equal(calls, 3)
        Expect.equal(seen[1], nil)
        Expect.holds(seen[2] ~= nil, "the second arrival was told of no first one")
        Expect.holds(seen[3] ~= nil, "the third arrival was told of no second one")
    end),

    -- A run whose listener parks partway along, and a second run read while it sleeps. A listener
    -- waking up owes the payloads of the block it was called for and not whatever arrived since.
    Harness.case("packet.run-outlives-a-listener-that-parks", function()
        local seen: { number } = {}
        local parked: thread? = nil
        local of = paired(count(), function(packet: any)
            packet:onClient(function(value: number)
                table.insert(seen, value)
                if #seen > 1 then return end
                parked = coroutine.running()
                coroutine.yield()
            end)
        end)

        burst(of, { 1, 2 })
        -- Parked on the first, so the second of that block is still owed.
        Expect.equal(#seen, 1)

        burst(of, { 3, 4 })
        local held = parked
        Expect.holds(held ~= nil, "the listener never parked")
        coroutine.resume(held :: thread)
        -- What it wakes to is its own block's second payload, and never the later block's.
        Expect.equal(seen[#seen], 2)
    end),
}
