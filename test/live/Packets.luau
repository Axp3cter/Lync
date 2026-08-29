--!strict
--!optimize 2
-- Fires in both directions: who hears one, in what order, and what rides along with it.

local Players = game:GetService ("Players")
local Workspace = game:GetService ("Workspace")

local Lync = require ("@src")
local Types = require ("@src/Types")

local Expect = require ("@test/harness/Expect")
local Harness = require ("@test/harness")

-- Constants -----------------------------------------------------------

const NAMESPACE = "packets"

--[[
    How long a check holds the floor, and how long a half waits inside one for something the other
    machine owes. Every check here fits a round trip and a little watching afterwards, because
    nothing a packet does has a deadline of its own the way a request does.
]]
const SPAN = 3
const PATIENCE = 2

--[[
    A moment a half waits before it sends. Both halves enter a span together and a listener is
    attached in the first resume of one, so this is slack rather than a handshake, and it is short
    because the span pays for it either way.
]]
const SETTLED = 0.5

-- The rate a paced packet is capped at, and how long a check fires at it.
const RATE = 2
const WINDOW = 1.5

-- What a fire carries, and the value that replaces it.
const CARRIED = 7
const LATER = 9

-- Fires sent in one frame, which is the run an order claim is about.
const BEATS = 3

--[[
    One packet per claim. A `newest` packet remembers what it last sent, so a check firing the value
    another check left behind would be a check whose answer depends on the order the two ran in, and
    two of them are separate for exactly that reason.
]]
const DEFINITIONS = table.freeze ({
    beat = Lync.packet (Lync.int (0, 100)),
    pulse = Lync.packet (Lync.int (0, 100)),
    latest = Lync.packet (Lync.int (0, 100)):newest (),
    steady = Lync.packet (Lync.int (0, 100)):newest (),
    paced = Lync.packet (Lync.int (0, 1000)):newest (RATE),
    stamped = Lync.packet (Lync.int (0, 100)):timestamped (),
})

-- Private -------------------------------------------------------------

-- Any number of takes on one definition, held for a check the way `Harness` holds a connection.
local function hearing (of: any, on: string, takes: { (...any) -> () }, run: () -> ())
    local links: { Types.Connection } = {}
    for _, take in takes do
        --[[
            Parenthesised, because a call through an `any` handle expands to as many values as it
            likes and `table.insert` takes a different call for two of them.
        ]]
        table.insert (links, (of[on] (of, take)))
    end

    Harness.attached (links, run)
end

-- A take that writes down everything it was handed, and the list it writes to.
local function recording (): ({ any }, (...any) -> ())
    local held = {}
    return held, function (...) table.insert (held, table.pack (...)) end
end

local function arrived (what: string, held: { any }, count: number)
    Harness.awaits (what, function () return #held >= count end, PATIENCE)
end

--[[
    Whether this client is the one that speaks for the others. A client half runs on every client,
    so a check wanting exactly one fire to reach the server would otherwise get one from each. The
    lowest id sends and the rest hold their span in silence, which is an order every machine agrees
    on without anyone being told it.
]]
local function alone (): boolean
    local me = Players.LocalPlayer
    for _, player in Players:GetPlayers () do
        if player.UserId < me.UserId then return false end
    end
    return true
end

-- Public --------------------------------------------------------------

return {
    Harness.opens (NAMESPACE, DEFINITIONS :: any),

    --[[
        A fire from a client, and what the server is handed for it. Three things arrive rather than
        one: the value, the player it authenticates to, and a send time that is absent because this
        packet does not carry one.
    ]]
    Harness.pair ("packet.fire-server", function ()
        Harness.together (SPAN, NAMESPACE, function ()
            local held, take = recording ()

            hearing (DEFINITIONS.beat, "onServer", { take }, function ()
                arrived ("the fire", held, 1)

                Expect.equal (held[1][1], CARRIED)
                Expect.holds (
                    typeof (held[1][2]) == "Instance",
                    `the sender is {typeof (held[1][2])}`
                )
                Expect.equal (held[1][3], nil)
            end)
        end)
    end, function ()
        Harness.together (SPAN, NAMESPACE, function ()
            if not alone () then return end

            task.wait (SETTLED)
            DEFINITIONS.beat:fireServer (CARRIED)
        end)
    end),

    --[[
        A fire from the server, and what a client is handed for it. The same claim from the other
        direction, minus the player: a client already knows who sent it, and the send time is absent
        for the same reason it was.
    ]]
    Harness.pair ("packet.fire-client", function ()
        Harness.together (SPAN, NAMESPACE, function ()
            task.wait (SETTLED)
            DEFINITIONS.pulse:fireClient (Lync.all, CARRIED)
        end)
    end, function ()
        Harness.together (SPAN, NAMESPACE, function ()
            local held, take = recording ()

            hearing (DEFINITIONS.pulse, "onClient", { take }, function ()
                arrived ("the fire", held, 1)

                Expect.equal (held[1][1], CARRIED)
                Expect.equal (held[1][2], nil)
            end)
        end)
    end),

    --[[
        A send in the direction it cannot go. `fireServer` on the server has nowhere to send to and
        no sender to authenticate, and a library answering it with silence would leave a caller
        reading their own code for an hour looking for the listener that never ran.
    ]]
    Harness.pair ("packet.wrong-side-server", function ()
        Expect.throws (
            function () DEFINITIONS.beat:fireServer (CARRIED) end,
            "is a client's call, and this is the server"
        )
    end, function () end),

    Harness.pair ("packet.wrong-side-client", function () end, function ()
        Expect.throws (
            function () DEFINITIONS.pulse:fireClient (Lync.all, CARRIED) end,
            "is the server's call, and this is a client"
        )
    end),

    --[[
        Two listeners on one definition, both run, in the order they were registered. Registration
        order is the only order a caller can reason about: a table of listeners walked by hash would
        deliver in an order that changed between runs of the same build.
    ]]
    Harness.pair ("packet.many-listeners", function ()
        Harness.together (SPAN, NAMESPACE, function ()
            local order = {}

            hearing (DEFINITIONS.beat, "onServer", {
                function () table.insert (order, "first") end,
                function () table.insert (order, "second") end,
            }, function ()
                Harness.awaits ("both listeners", function () return #order >= 2 end, PATIENCE)

                Expect.equal (order[1], "first")
                Expect.equal (order[2], "second")
            end)
        end)
    end, function ()
        Harness.together (SPAN, NAMESPACE, function ()
            if not alone () then return end

            task.wait (SETTLED)
            DEFINITIONS.beat:fireServer (CARRIED)
        end)
    end),

    --[[
        A listener dropped through the connection its registration answered, and the traffic it no
        longer hears. Every check in this file leans on it: a listener attached for one check and
        left behind would hear the next check's fires, so a library where `disconnect` only flipped
        a flag would turn one wrong answer into a file of them.
    ]]
    Harness.pair ("packet.listener-disconnects", function ()
        Harness.together (SPAN, NAMESPACE, function ()
            task.wait (SETTLED)
            DEFINITIONS.pulse:fireClient (Lync.all, CARRIED)
        end)
    end, function ()
        Harness.together (SPAN, NAMESPACE, function ()
            local order = {}
            local dropped = DEFINITIONS.pulse:onClient (
                function () table.insert (order, "dropped") end
            )

            hearing (DEFINITIONS.pulse, "onClient", {
                function () table.insert (order, "kept") end,
            }, function ()
                dropped:disconnect ()
                Expect.equal (dropped.connected, false)

                Harness.awaits ("the fire", function () return #order >= 1 end, PATIENCE)
                task.wait (SETTLED)

                Expect.equal (#order, 1)
                Expect.equal (order[1], "kept")
            end)
        end)
    end),

    --[[
        One listener yields and its siblings run before it comes back. A fan that awaited each
        listener before starting the next would let one caller's `task.wait` hold up every other
        listener on the definition, which is a coupling between two pieces of code that never
        agreed to know about each other.
    ]]
    Harness.pair ("packet.listener-yields", function ()
        Harness.together (SPAN, NAMESPACE, function ()
            local order = {}

            hearing (DEFINITIONS.beat, "onServer", {
                function ()
                    table.insert (order, "yields")
                    task.wait (SETTLED)
                    table.insert (order, "returns")
                end,
                function () table.insert (order, "sibling") end,
            }, function ()
                Harness.awaits (
                    "the yielding listener",
                    function () return #order >= 3 end,
                    PATIENCE
                )

                Expect.equal (order[1], "yields")
                Expect.equal (order[2], "sibling")
                Expect.equal (order[3], "returns")
            end)
        end)
    end, function ()
        Harness.together (SPAN, NAMESPACE, function ()
            if not alone () then return end

            task.wait (SETTLED)
            DEFINITIONS.beat:fireServer (CARRIED)
        end)
    end),

    --[[
        A run of fires in one frame, delivered in the order they were made. The platform keeps one
        order per client across the fire forms, and what this asks is that the library keeps it too,
        through a queue, a flush, a frame and a decode.
    ]]
    Harness.pair ("packet.ordered-default", function ()
        Harness.together (SPAN, NAMESPACE, function ()
            task.wait (SETTLED)
            for index = 1, BEATS do
                DEFINITIONS.pulse:fireClient (Lync.all, index)
            end
        end)
    end, function ()
        Harness.together (SPAN, NAMESPACE, function ()
            local held, take = recording ()

            hearing (DEFINITIONS.pulse, "onClient", { take }, function ()
                arrived ("the run", held, BEATS)

                for index = 1, BEATS do
                    Expect.equal (held[index][1], index)
                end
            end)
        end)
    end),

    --[[
        Two fires of a `newest` packet in one flush, and only the later one goes. A stream where
        only the current value matters is the case this exists for, and a flush shipping both would
        be spending a frame's bandwidth on a value the receiver replaces before it can read it.
    ]]
    Harness.pair ("packet.newest-latest-wins", function ()
        Harness.together (SPAN, NAMESPACE, function ()
            task.wait (SETTLED)
            DEFINITIONS.latest:fireClient (Lync.all, CARRIED)
            DEFINITIONS.latest:fireClient (Lync.all, LATER)
        end)
    end, function ()
        Harness.together (SPAN, NAMESPACE, function ()
            local held, take = recording ()

            hearing (DEFINITIONS.latest, "onClient", { take }, function ()
                arrived ("the newest fire", held, 1)
                task.wait (SETTLED)

                Expect.equal (#held, 1)
                Expect.equal (held[1][1], LATER)
            end)
        end)
    end),

    --[[
        A `newest` packet fired again with the value it already sent, and nothing leaves. This is
        the idle stream: a client holding still still fires every frame, and the bytes for that
        belong to nobody.
    ]]
    Harness.pair ("packet.newest-unchanged", function ()
        Harness.together (SPAN, NAMESPACE, function ()
            task.wait (SETTLED)
            DEFINITIONS.steady:fireClient (Lync.all, CARRIED)

            task.wait (SETTLED)
            DEFINITIONS.steady:fireClient (Lync.all, CARRIED)
        end)
    end, function ()
        Harness.together (SPAN, NAMESPACE, function ()
            local held, take = recording ()

            hearing (DEFINITIONS.steady, "onClient", { take }, function ()
                arrived ("the first fire", held, 1)
                task.wait (SETTLED * 2)

                Expect.equal (#held, 1)
                Expect.equal (held[1][1], CARRIED)
            end)
        end)
    end),

    --[[
        A `newest` packet fired every frame and capped at its rate. A caller firing from a render
        step is the ordinary case rather than the abusive one, and the rate is what turns sixty
        fires a second into the two the definition asked for.
    ]]
    Harness.pair ("packet.newest-rate", function ()
        Harness.together (SPAN, NAMESPACE, function ()
            task.wait (SETTLED)

            local until_ = os.clock () + WINDOW
            local value = 0
            while os.clock () < until_ do
                value += 1
                DEFINITIONS.paced:fireClient (Lync.all, value)
                task.wait ()
            end
        end)
    end, function ()
        Harness.together (SPAN, NAMESPACE, function ()
            local held, take = recording ()

            hearing (DEFINITIONS.paced, "onClient", { take }, function ()
                arrived ("the paced fire", held, 1)
                task.wait (WINDOW)

                local most = RATE * WINDOW + RATE
                Expect.holds (#held <= most, `{#held} arrived, and the rate allows {most}`)
            end)
        end)
    end),

    --[[
        A `timestamped` packet, and the moment it was sent. The stamp is a reading of the clock both
        machines keep rather than of the sender's own, which is the whole of what makes it useful: a
        client comparing it to its own `os.clock` would be comparing two numbers that share no
        origin.
    ]]
    Harness.pair ("packet.timestamped", function ()
        Harness.together (SPAN, NAMESPACE, function ()
            task.wait (SETTLED)
            DEFINITIONS.stamped:fireClient (Lync.all, CARRIED)
        end)
    end, function ()
        Harness.together (SPAN, NAMESPACE, function ()
            local held, take = recording ()

            hearing (DEFINITIONS.stamped, "onClient", { take }, function ()
                arrived ("the stamped fire", held, 1)

                local sent = held[1][2]
                Expect.holds (typeof (sent) == "number", `the stamp is {typeof (sent)}`)

                local apart = math.abs (Workspace:GetServerTimeNow () - sent)
                Expect.holds (apart < PATIENCE, `the stamp reads {apart} s from the shared clock`)
            end)
        end)
    end),
}
