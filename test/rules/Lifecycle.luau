--!strict
--!optimize 2
--[[
    A namespace's phases: what a listener attached early hears, what nothing leaves without, and
    what is left after it closes.
]]

local Lync = require ("@src")
local Session = require ("@src/runtime/Session")
local Types = require ("@src/Types")

local Doubles = require ("@fixtures/Doubles")

local Expect = require ("@test/harness/Expect")
local Harness = require ("@test/harness")
local Replica = require ("@test/harness/Replica")

-- Constants -----------------------------------------------------------

const SPACE = "lifecycle"

-- The one client, because every phase here is one machine's and the other end only has to exist.
const SENDER = "alice"

-- A packet both sides listen for, and a query the client answers.
const HEARD = "heard"
const ASKS = "asks"

-- A packet legal to declare and illegal to compile, which is what asks when the compiling happens.
const MARKED = "marked"

const CARRIED = true

--[[
    Flushes a check makes when it is asking what a flush does with nothing to do.

    More than one, because a machine that spoke on every eighth flush rather than on every one would
    answer a single reading correctly and cost a place a frame a second anyway.
]]
const ROUNDS = 8

-- Types ---------------------------------------------------------------

--[[
    One machine: the session that owns the lane, the handles a caller reads through, and what its
    listener has been handed since it was attached.
]]
type Machine = {
    read session: Session.Session,
    read defs: any,
    read heard: { boolean },
}

-- The pair, with each side's own listener beside it.
type Run = {
    read wire: Doubles.Wire,
    read player: Player,
    read server: Machine,
    read client: Machine,
}

-- Private -------------------------------------------------------------

--[[
    One packet and one query, which is the smallest pair that reaches both of the things a phase
    decides: whether a fire leaves, and whether a request finds anybody to answer it.
]]
local function defined (): any
    return {
        [HEARD] = Lync.packet (Lync.bool ()),
        [ASKS] = Lync.query (Lync.bool (), Lync.bool ()),
    }
end

-- Two machines on one lane, each with its listener attached before it starts.
local function opened (): Run
    local inbound: { boolean } = {}
    local outbound: { boolean } = {}

    local pair = Replica.paired ({
        space = SPACE,
        defined = defined,
        label = SENDER,
        wires = function (defs: any, side: string)
            if side == "server" then
                defs[HEARD]:onServer (function () table.insert (inbound, true) end)
                return
            end

            defs[HEARD]:onClient (function () table.insert (outbound, true) end)
            defs[ASKS]:onClient (function (value: boolean): boolean return value end)
        end,
    })

    return {
        wire = pair.wire,
        player = pair.player,
        server = { session = pair.server.session, defs = pair.server.defs, heard = inbound },
        client = { session = pair.client.session, defs = pair.client.defs, heard = outbound },
    }
end

-- A fire from the client, flushed and carried, which is what most of these need.
local function sent (of: Run)
    of.client.defs[HEARD]:fireServer (CARRIED)
    of.client.session:flush ()
    of.wire:settle ()
end

local moved = Replica.crossed

--[[
    A request the server makes and does not wait for, and what the completion was handed. Never
    yields, so the close that follows it happens while the request is still in flight, which is the
    arrangement two checks want.
]]
local function asking (of: Run): { { ok: boolean, code: unknown, data: Types.OutcomeData? } }
    local done = {}

    of.server.defs[ASKS]:request (
        of.player,
        CARRIED,
        function (ok: boolean, code: unknown, data: Types.OutcomeData?)
            table.insert (done, { ok = ok, code = code, data = data })
        end
    )
    return done
end

-- Public --------------------------------------------------------------

return {
    --[[
        A listener attached before the machine started, and the traffic it hears afterwards, which
        is the ordinary way a caller wires one. A definitions module is required on both sides and
        its handles are where listeners go, all before anything is started.
    ]]
    Harness.case ("life.listeners-before-start", function ()
        local of = opened ()
        sent (of)

        Expect.equal (#of.server.heard, 1)
    end),

    --[[
        A listener attached after the machine started, and the traffic either side of the moment.
        From then on is the claim, so it hears the fire that follows and not the one before:
        replaying what a definition was already handed is a caller seeing the past as the present.
    ]]
    Harness.case ("life.listeners-after-start", function ()
        local of = opened ()
        sent (of)

        local late = {}
        of.server.defs[HEARD]:onServer (function () table.insert (late, true) end)

        sent (of)

        Expect.equal (#of.server.heard, 2)
        Expect.equal (#late, 1)
    end),

    --[[
        A flush with nothing behind it, which a place makes more of than any other call here. A
        namespace carrying occasional traffic is flushed at the rate of one carrying constant
        traffic, so a machine sending anyway puts a correct, empty, paid for frame on the wire every
        time.
    ]]
    Harness.case ("life.flush-empty-free", function ()
        local of = opened ()

        of.client.defs[HEARD]:fireServer (CARRIED)
        of.client.session:flush ()
        of.wire:settle ()

        local before = moved (of)
        Expect.holds (before > 0, "the lane carried nothing, so it was never working")

        for _ = 1, ROUNDS do
            of.client.session:flush ()
            of.server.session:flush ()
            of.wire:settle ()
        end

        Expect.equal (moved (of), before)
        Expect.equal (#of.server.heard, 1)
    end),

    -- A fire with no flush behind it, which is nothing at all.
    Harness.case ("life.flush-required", function ()
        local of = opened ()
        local before = moved (of)

        of.client.defs[HEARD]:fireServer (CARRIED)
        of.wire:settle ()

        Expect.equal (moved (of), before)
        Expect.equal (#of.server.heard, 0)

        of.client.session:flush ()
        of.wire:settle ()

        Expect.holds (moved (of) > before, "a flush carried nothing")
        Expect.equal (#of.server.heard, 1)
    end),

    -- Traffic queued when a machine closes, and where it goes.
    Harness.case ("life.close-flushes", function ()
        local of = opened ()
        local before = moved (of)

        of.client.defs[HEARD]:fireServer (CARRIED)
        of.client.session:close ()
        of.wire:settle ()

        Expect.holds (moved (of) > before, "a close carried nothing")
        Expect.equal (#of.server.heard, 1)
    end),

    -- What a closed machine is still holding, which is nothing.
    Harness.case ("life.close-releases", function ()
        local of = opened ()

        of.server.defs[HEARD]:fireClient (of.player, CARRIED)
        of.server.session:flush ()

        of.client.session:close ()
        of.wire:settle ()

        Expect.equal (#of.client.heard, 0)
    end),

    -- A fire after the close, which is a mistake rather than a no-op.
    Harness.case ("life.close-then-traffic", function ()
        local of = opened ()
        of.client.session:close ()

        Expect.throws (
            function () of.client.defs[HEARD]:fireServer (CARRIED) end,
            "close lets its remotes go"
        )
    end),

    --[[
        A second start on a session that has one. `Lync.start` refuses this at the surface and never
        reaches the session, so the guard underneath is the one a caller never meets and the one
        nothing was holding to anything. It is reachable here because a rules run opens its own
        sessions rather than the place's.
    ]]
    Harness.case ("life.session-starts-once", function ()
        local of = opened ()

        Expect.throws (function () of.client.session:start () end, "has already started")
    end),

    --[[
        A handle that was never put in a namespace, used. Every other refusal about phase is about a
        namespace that is not started or is closed, and this is the one before any of that: a caller
        who built a packet, forgot the `define`, and is holding something that looks finished.
    ]]
    Harness.case ("life.never-defined", function ()
        local stray = Lync.packet (Lync.bool ())

        Expect.throws (
            function () (stray :: any):fireServer (CARRIED) end,
            "before it was named in a namespace"
        )
    end),

    -- A request still in flight when its own machine closes.
    Harness.case ("life.close-resolves", function ()
        local of = opened ()
        local done = asking (of)

        Expect.equal (#done, 0)
        of.server.session:close ()

        Expect.equal (#done, 1)
        Expect.equal (done[1].ok, false)
    end),

    -- The name that failure has.
    Harness.case ("query.shutdown", function ()
        local of = opened ()
        local done = asking (of)

        of.server.session:close ()

        Expect.equal (done[1].code, "shutdown")
        Expect.equal ((done[1].data :: Types.OutcomeData).definition, ASKS)
    end),

    -- When the compiling happens, which is at the start and not at the first use.
    Harness.case ("life.start-compiles", function ()
        local wire = Doubles.wire ()
        local roster = Doubles.roster ()

        local defs = defined ()
        defs[MARKED] = Lync.packet (Lync.int (0, 100):monotonic ())

        local thrown = Expect.throws (
            function () Session.new (SPACE, defs, wire:server (), roster, "server") end
        )
        Expect.holds (string.find (thrown, MARKED, 1, true) ~= nil, `it said "{thrown}"`)

        local of = opened ()
        local stats = of.server.session:stats ()

        for name in defined () do
            Expect.holds (stats.definitions[name] ~= nil, `{name} has no counter row after start`)
            Expect.holds (#of.server.defs[name]:describe () > 0, `{name} describes as nothing`)
        end
    end),
}
