--!strict
--!optimize 2
-- What a delivery modifier changes about a frame, asked on a lane that can lose and reorder.

local Lync = require ("@src")
local Session = require ("@src/runtime/Session")

local Doubles = require ("@fixtures/Doubles")

local Expect = require ("@test/harness/Expect")
local Harness = require ("@test/harness")
local Replica = require ("@test/harness/Replica")

-- Constants -----------------------------------------------------------

const SPACE = "delivery"

-- The one client, because every claim here is about a frame rather than an audience.
const SENDER = "alice"

--[[
    Five packets over one codec, so the only thing that differs between any two of them is what a
    caller chained onto the definition.
]]
const SURE = "sure"
const LOSSY = "lossy"
const LATEST = "latest"
const STAMPED = "stamped"
const BOTH = "both"

const EVERY = table.freeze ({ SURE, LOSSY, LATEST, STAMPED, BOTH })

--[[
    The two ends of a draw, bound short because every check here hands the lane one of them. One
    falls under every fault band and the other sits past all of them, so a lane handed the second
    carries the frame over once and does nothing else to it.
]]
const FAULTED = Doubles.FAULTED
const CLEAN = Doubles.CLEAN

-- The two patterns a check hands it: this frame and not the next, or every one of them.
const ALTERNATING = table.freeze ({ FAULTED, CLEAN })
const EVERY_FRAME = table.freeze ({ FAULTED })

-- The fraction each check hands the one band it opens.
const HALF = 0.5
const ALWAYS = 1

-- The clients a broadcast is counted over, which is more than one so that one encode can be fewer.
const AUDIENCE = table.freeze ({ "alice", "bob", "carol" })

-- Fires a lossy run makes, even so the pattern lands on the same half every time.
const RUN = 6

-- What a fire carries, and the two values a latest-wins stream carries in order.
const CARRIED = 7
const EARLIER = 11
const LATER = 12

-- Types ---------------------------------------------------------------

-- A payload as a listener was handed it, with the send time a stamped definition adds.
type Held = { read value: number, read sent: number? }

type Run = {
    read wire: Doubles.Wire,
    read player: Player,
    read server: Session.Session,
    read defs: any,
    read heard: { [string]: { Held } },
}

-- Private -------------------------------------------------------------

--[[
    Every delivery a packet can declare and the one pair of them that combines: a plain fire, the
    lane that may lose, the one that coalesces, the one that carries a stamp, and a stamp on the
    losing lane.
]]
local function defined (): any
    return {
        [SURE] = Lync.packet (Lync.int (0, 100)),
        [LOSSY] = Lync.packet (Lync.int (0, 100)):unreliable (),
        [LATEST] = Lync.packet (Lync.int (0, 100)):newest (),
        [STAMPED] = Lync.packet (Lync.int (0, 100)):timestamped (),
        [BOTH] = Lync.packet (Lync.int (0, 100)):timestamped ():unreliable (),
    }
end

--[[
    Two machines on one lane, the client listening to everything before it starts, which is both
    where a caller writes a listener and the order that decides what a fresh one is told.
]]
local function opened (chance: Doubles.Faults?, draw: (() -> number)?): Run
    local wire = Doubles.wire (chance, draw)
    local roster = Doubles.roster ()

    local serverDefs = defined ()
    local server = Session.new (SPACE, serverDefs, wire:server (), roster, "server")
    server:start ()

    local player = roster:join (SENDER)
    local clientDefs = defined ()
    local client = Session.new (SPACE, clientDefs, wire:client (player), roster, "client")

    local heard: { [string]: { Held } } = {}
    for _, name in EVERY do
        local into: { Held } = {}
        heard[name] = into

        local function take (value: number, sent: number?)
            table.insert (into, { value = value, sent = sent })
        end

        clientDefs[name]:onClient (take)
    end

    client:start ()
    wire:settle ()

    return { wire = wire, player = player, server = server, defs = serverDefs, heard = heard }
end

-- One fire, flushed, and carried as far as the lane will carry it.
local function fires (of: Run, name: string, value: number)
    of.defs[name]:fireClient (of.player, value)
    of.server:flush ()
    of.wire:settle ()
end

-- Public --------------------------------------------------------------

return {
    -- An `:unreliable()` stream over a lane that drops every other frame.
    Harness.case ("packet.unreliable-lossy", function ()
        local of = opened ({ lose = HALF, double = 0, hold = 0 }, Doubles.scripted (ALTERNATING))

        for index = 1, RUN do
            of.defs[LOSSY]:fireClient (of.player, index)
            of.defs[SURE]:fireClient (of.player, index)

            of.server:flush ()
            of.wire:settle ()
        end

        Expect.holds (of.wire:moved ().lost > 0, "the lane was asked to lose and lost nothing")

        local ordered = of.heard[SURE]
        Expect.equal (#ordered, RUN)
        for index = 1, RUN do
            Expect.equal (ordered[index].value, index)
        end

        local survived = of.heard[LOSSY]
        Expect.equal (#survived, RUN // 2)
        for at, one in survived do
            Expect.equal (one.value, at * 2)
        end
    end),

    --[[
        A `:newest()` stream with nothing new in it, flushed over and over. It is the one definition
        here with a reason to speak when nobody asked, since it holds a value between fires and a
        library reading that as something owed to the receiver would resend it forever.
    ]]
    Harness.case ("packet.newest-idle", function ()
        local of = opened ()

        fires (of, LATEST, CARRIED)
        Expect.equal (#of.heard[LATEST], 1)

        local before = of.wire:moved ()
        for _ = 1, RUN do
            of.server:flush ()
            of.wire:settle ()
        end

        local after = of.wire:moved ()
        Expect.equal (after.frames, before.frames)
        Expect.equal (after.bytes, before.bytes)
        Expect.equal (#of.heard[LATEST], 1)
    end),

    --[[
        A `:newest()` frame that arrives after the one that replaced it. Latest wins is the whole of
        what the modifier promises and the lane is unordered, so applying it would walk a position
        or an aim backwards, which is a visible stutter.
    ]]
    Harness.case ("packet.newest-stale", function ()
        local of = opened ({ lose = 0, double = 0, hold = HALF }, Doubles.scripted (ALTERNATING))

        of.defs[LATEST]:fireClient (of.player, EARLIER)
        of.server:flush ()

        of.defs[LATEST]:fireClient (of.player, LATER)
        of.server:flush ()

        of.wire:deliver ()
        Expect.holds (of.wire:moved ().held > 0, "the lane was asked to hold and held nothing")

        local held = of.heard[LATEST]
        Expect.equal (#held, 1)
        Expect.equal (held[1].value, LATER)

        of.wire:settle ()
        Expect.equal (#held, 1)
    end),

    --[[
        A `:newest()` frame the lane hands over twice, which is the other thing an unordered lane
        does and the one nothing here had asked for. A stream ordered by a ring reads the second
        copy as a sequence it has already seen, so a listener is told about the value rather than
        about the arrival.
    ]]
    Harness.case ("packet.newest-doubled", function ()
        local of = opened ({ lose = 0, double = ALWAYS, hold = 0 }, Doubles.scripted (EVERY_FRAME))

        of.defs[LATEST]:fireClient (of.player, CARRIED)
        of.defs[SURE]:fireClient (of.player, CARRIED)
        of.server:flush ()
        of.wire:settle ()

        local doubled = of.wire:moved ().doubled
        Expect.holds (doubled > 0, "the lane was asked to double and doubled nothing")

        local latest = of.heard[LATEST]
        Expect.equal (#latest, 1)
        Expect.equal (latest[1].value, CARRIED)
        Expect.equal (#of.heard[SURE], 1)
    end),

    --[[
        `:timestamped()` beside a delivery modifier, and both applying. They are different kinds of
        declaration: one says how a frame travels and the other what rides with the payload, so a
        library treating the stamp as a third delivery mode would make the pair illegal.
    ]]
    Harness.case ("packet.timestamped-stacks", function ()
        local kept = opened ()

        fires (kept, STAMPED, CARRIED)
        fires (kept, BOTH, CARRIED)

        for _, name in { STAMPED, BOTH } do
            local one = kept.heard[name][1]
            Expect.holds (one ~= nil, `{name} did not arrive at all`)
            Expect.holds (typeof (one.sent) == "number", `{name} arrived with no stamp`)
        end

        local always = { lose = ALWAYS, double = 0, hold = 0 }
        local gone = opened (always, Doubles.scripted (EVERY_FRAME))

        fires (gone, STAMPED, CARRIED)
        fires (gone, BOTH, CARRIED)

        Expect.equal (#gone.heard[STAMPED], 1)
        Expect.equal (#gone.heard[BOTH], 0)
    end),

    -- One fire at everybody, and how many times the value is turned into bytes.
    Harness.case ("packet.encode-once", function ()
        local encodes, decodes = 0, 0

        local function counted (): any
            local held = Lync.int (0, 100):as (function (value: number): number
                decodes += 1
                return value
            end, function (value: number): number
                encodes += 1
                return value
            end)

            return { [SURE] = Lync.packet (held) }
        end

        local of = Replica.open ({ space = SPACE, defined = counted }, AUDIENCE[1])
        local heard = {}

        for at = 2, #AUDIENCE do
            Replica.joins (of, AUDIENCE[at])
        end

        for _, held in of.viewers do
            held.machine.defs[SURE]:onClient (
                function (value: number) table.insert (heard, value) end
            )
        end

        encodes, decodes = 0, 0
        of.server.defs[SURE]:fireClient (Lync.all, CARRIED)
        Replica.ships (of)

        Expect.equal (encodes, 1)
        Expect.equal (decodes, #AUDIENCE)
        Expect.equal (#heard, #AUDIENCE)
        for _, value in heard do
            Expect.equal (value, CARRIED)
        end
    end),

    --[[
        Two senders on the lane that reorders, each with a place on the ring of its own. One ring
        held for everybody would read one machine's sequence as another's, so the first frame from
        a machine that had sent nothing would arrive already behind whatever the talkative one had
        reached, and the quiet machine would be silenced by a number it never wrote.
    ]]
    Harness.case ("packet.newest-per-sender", function ()
        local of = Replica.open ({ space = SPACE, defined = defined }, SENDER)
        local second = Replica.joins (of, "bob")

        local heard: { number } = {}
        local whose: { Player } = {}

        -- The value first and the machine that sent it after, which is what the surface states.
        of.server.defs[LATEST]:onServer (function (value: number, who: Player)
            table.insert (heard, value)
            table.insert (whose, who)
        end)

        -- The first machine talks until its place on the ring is well past where a new one starts.
        for step = 1, 8 do
            of.client.defs[LATEST]:fireServer (step)
            of.client.session:flush ()
            of.wire:settle ()
        end
        Expect.equal (#heard, 8)

        second.machine.defs[LATEST]:fireServer (99)
        second.machine.session:flush ()
        of.wire:settle ()

        Expect.equal (#heard, 9)
        Expect.equal (heard[9], 99)
        Expect.equal (whose[1], of.player)
        Expect.equal (whose[9], second.player)
    end),

    --[[
        The client's fire made on a server. A packet is one direction a call at a time and the two
        forms differ only in what they leave out, so a server calling the client's form is a caller
        who read the wrong half of their own schema. Refused by the name of the call rather than by
        whatever stopped making sense first, which is a player argument nobody passed.
    ]]
    Harness.case ("packet.wrong-side-fire", function ()
        local of = Replica.open ({ space = SPACE, defined = defined }, SENDER)

        Expect.throws (
            function () of.server.defs[SURE]:fireServer (CARRIED) end,
            "is a client's call, and this is the server"
        )
    end),
    --[[
        More fires of one definition in one flush than a block may hold. A run states its count in
        a field of fixed width, so what happens past that width is the whole question: the next
        block opens, and a caller who fired thirty-five times is a listener told thirty-five.
    ]]
    Harness.case ("packet.run-past-its-cap", function ()
        --[[
            Past any cap a block of this namespace could have. What the cap is comes off the width
            of the id the header already spends, so a check naming a number of its own would be a
            check about arithmetic somewhere else.
        ]]
        const MANY = 200

        local of = opened ()
        local many = MANY

        for index = 1, many do
            of.defs[SURE]:fireClient (of.player, index % 101)
        end
        of.server:flush ()
        of.wire:settle ()

        local held = of.heard[SURE]
        Expect.equal (#held, many)

        for index = 1, many do
            Expect.equal (held[index].value, index % 101)
        end
    end),

    --[[
        A burst of fires from a definition that declared an instant. The instant is a field of the
        header and a run carries one header between them, so these cannot share: each fire owes a
        listener the moment it was sent, and a run of them would hand every one the first.
    ]]
    Harness.case ("packet.stamped-burst-keeps-each", function ()
        const BURST = 4

        local of = opened ()

        for index = 1, BURST do
            of.defs[STAMPED]:fireClient (of.player, index)
        end
        of.server:flush ()
        of.wire:settle ()

        local held = of.heard[STAMPED]
        Expect.equal (#held, BURST)

        for index = 1, BURST do
            Expect.equal (held[index].value, index)
            Expect.holds (held[index].sent ~= nil, `the {index} of {BURST} carried no instant`)
        end
    end),
}
