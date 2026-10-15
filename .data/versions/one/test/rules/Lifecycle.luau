--!strict
--!optimize 2
-- A namespace's phases: what a listener attached early hears, what nothing leaves without, and
-- what is left after it closes.

local Codecs = require("@src/codec")
local Lifecycle = require("@src/api/Lifecycle")
local Packet = require("@src/api/Packet")
local Query = require("@src/api/Query")
local Session = require("@src/runtime/Session")
local Set = require("@src/api/Set")
local Types = require("@src/Types")

local Doubles = require("@fixtures/Doubles")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")
local Records = require("@test/harness/Records")
local Replica = require("@test/harness/Replica")

local SPACE = "lifecycle"

-- The one client, because every phase here is one machine's and the other end only has to exist.
local SENDER = "alice"

-- A packet both sides listen for, a query the client answers, and a set for the readings one
-- answers before there is a session under it.
local HEARD = "heard"
local ASKS = "asks"
local ROSTER = "roster"

-- A packet legal to declare and illegal to compile, which is what asks when the compiling happens.
local MARKED = "marked"

local CARRIED = true

-- Flushes a check makes when it is asking what a flush does with nothing to do. More than one,
-- because a machine that spoke on every eighth flush would answer a single reading correctly.
local ROUNDS = 8

-- One machine: the session that owns the lane, the handles a caller reads through, and what its
-- listener has been handed since it was attached.
type Machine = {
    read session: Session.Session,
    read defs: any,
    read heard: { boolean },
}

type Run = {
    read wire: Doubles.Wire,
    read player: Player,
    read server: Machine,
    read client: Machine,
}

type Done = { read ok: boolean, read code: unknown, read data: Types.OutcomeData? }

-- Private -------------------------------------------------------------

-- A packet, a query and a set: the smallest schema that reaches both of the things a phase
-- decides, whether a fire leaves and whether a request finds anybody to answer it.
local function defined(): any
    return {
        [HEARD] = Packet.new(Codecs.bool()),
        [ASKS] = Query.new(Codecs.bool(), Codecs.bool()),
        [ROSTER] = Set.new(Codecs.struct({ [MARKED] = Codecs.bool() })),
    }
end

-- Two machines on one lane, each with its listener attached before it starts.
local function opened(): Run
    local inbound: { boolean } = {}
    local outbound: { boolean } = {}
    local pair = Replica.paired({
        space = SPACE,
        defined = defined,
        label = SENDER,
        wires = function(defs: any, side: string)
            if side == "server" then
                defs[HEARD]:onServer(function()
                    table.insert(inbound, true)
                end)
                return
            end
            defs[HEARD]:onClient(function()
                table.insert(outbound, true)
            end)
            defs[ASKS]:onClient(function(value: boolean): boolean
                return value
            end)
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
local function sent(of: Run)
    of.client.defs[HEARD]:fireServer(CARRIED)
    of.client.session:flush()
    of.wire:settle()
end

-- A request the server makes and does not wait for, so the close that follows it happens while
-- the request is still in flight.
local function asking(of: Run): { Done }
    local done: { Done } = {}
    local function completed(ok: boolean, code: unknown, data: Types.OutcomeData?)
        table.insert(done, { ok = ok, code = code, data = data })
    end
    of.server.defs[ASKS]:request(of.player, CARRIED, completed)
    return done
end

-- Public --------------------------------------------------------------

return {
    -- The calls a place makes on a library that has not started, which are refused rather than
    -- answered: a flush has no session to spend and a close has none to let go.
    Harness.case("life.surface-before-start", function()
        Expect.throws(function()
            Lifecycle.flush()
        end, "flush before start")
        Expect.throws(function()
            Lifecycle.close()
        end, "close before start")
    end),

    -- A set read before the machine started answers empty rather than refusing, since a place
    -- wires its interface against a handle before anything is bound.
    Harness.case("life.set-before-start", function()
        local set = defined()[ROSTER]
        Expect.equal(set:get(1), nil)
        Expect.equal(#set, 0)
        local walked = 0
        for _ in set do
            walked += 1
        end
        Expect.equal(walked, 0)
    end),

    -- A listener attached before the machine started, and the traffic it hears afterwards.
    Harness.case("life.listeners-before-start", function()
        local of = opened()
        sent(of)
        Expect.equal(#of.server.heard, 1)
    end),

    -- A registration for the other machine's side attaches nothing and says so: a shared module
    -- wiring both sides loads, the right side alone is heard or answers, and each wrong one is a
    -- warning naming the call, since its listener would be handed the other side's arguments.
    Harness.case("life.wrong-side-registrations", function()
        local right, wrong = {}, {}
        local links: { [string]: Types.Connection } = {}
        local heard = Records.made(function()
            local pair = Replica.paired({
                space = SPACE,
                defined = defined,
                label = SENDER,
                wires = function(defs: any, side: string)
                    if side == "server" then
                        links.serverWrong = defs[HEARD]:onClient(function(...)
                            table.insert(wrong, { ... })
                        end)
                        defs[ASKS]:onServer(function(): boolean
                            return true
                        end)
                        return
                    end
                    links.clientWrong = defs[HEARD]:onServer(function(...)
                        table.insert(wrong, { ... })
                    end)
                    links.clientRight = defs[HEARD]:onClient(function(...)
                        table.insert(right, { ... })
                    end)
                    defs[ASKS]:onServer(function(): boolean
                        return false
                    end)
                    defs[ASKS]:onClient(function(): boolean
                        return true
                    end)
                end,
            })
            pair.server.defs[HEARD]:fireClient(pair.player, CARRIED)
            pair.server.session:flush()
            pair.wire:settle()

            local done: { boolean } = {}
            pair.server.defs[ASKS]:request(pair.player, CARRIED, function(ok: boolean, value: any)
                table.insert(done, ok and value == true)
            end)
            pair.server.session:flush()
            pair.wire:settle()
            pair.client.session:flush()
            pair.wire:settle()
            Expect.equal(done, { true })
        end)

        Expect.equal(#right, 1)
        Expect.equal(#wrong, 0)
        Expect.equal(links.clientWrong.connected, false)
        Expect.equal(links.serverWrong.connected, false)
        Expect.equal(links.clientRight.connected, true)

        local warned = 0
        for _, one in heard do
            if one.kind ~= "warn" then continue end
            if string.find(one.message, "nothing is attached", 1, true) then
                warned += 1
            end
            if string.find(one.message, "nothing answers", 1, true) then
                warned += 1
            end
            Expect.holds(one.data.definition ~= nil, "a wrong-side warning named no definition")
        end
        Expect.equal(warned, 3)
    end),

    -- A listener attached after the machine started hears the fire that follows and not the one
    -- before.
    Harness.case("life.listeners-after-start", function()
        local of = opened()
        sent(of)
        local late = {}
        of.server.defs[HEARD]:onServer(function()
            table.insert(late, true)
        end)
        sent(of)
        Expect.equal(#of.server.heard, 2)
        Expect.equal(#late, 1)
    end),

    -- A flush with nothing behind it puts nothing on the wire.
    Harness.case("life.flush-empty-free", function()
        local of = opened()
        sent(of)
        local before = Replica.crossed(of)
        Expect.holds(before > 0, "the lane carried nothing, so it was never working")

        for _ = 1, ROUNDS do
            of.client.session:flush()
            of.server.session:flush()
            of.wire:settle()
        end
        Expect.equal(Replica.crossed(of), before)
        Expect.equal(#of.server.heard, 1)
    end),

    -- A fire with no flush behind it, which is nothing at all.
    Harness.case("life.flush-required", function()
        local of = opened()
        local before = Replica.crossed(of)
        of.client.defs[HEARD]:fireServer(CARRIED)
        of.wire:settle()
        Expect.equal(Replica.crossed(of), before)
        Expect.equal(#of.server.heard, 0)

        of.client.session:flush()
        of.wire:settle()
        Expect.holds(Replica.crossed(of) > before, "a flush carried nothing")
        Expect.equal(#of.server.heard, 1)
    end),

    -- Traffic queued when a machine closes goes out with the close.
    Harness.case("life.close-flushes", function()
        local of = opened()
        local before = Replica.crossed(of)
        of.client.defs[HEARD]:fireServer(CARRIED)
        of.client.session:close()
        of.wire:settle()
        Expect.holds(Replica.crossed(of) > before, "a close carried nothing")
        Expect.equal(#of.server.heard, 1)
    end),

    -- What a closed machine is still holding, which is nothing.
    Harness.case("life.close-releases", function()
        local of = opened()
        of.server.defs[HEARD]:fireClient(of.player, CARRIED)
        of.server.session:flush()
        of.client.session:close()
        of.wire:settle()
        Expect.equal(#of.client.heard, 0)
    end),

    -- A fire after the close, which is a mistake rather than a no-op.
    Harness.case("life.close-then-traffic", function()
        local of = opened()
        of.client.session:close()
        Expect.throws(function()
            of.client.defs[HEARD]:fireServer(CARRIED)
        end, "close lets its remotes go")
    end),

    -- A second start on a session that has one, which is the guard under the surface's own.
    Harness.case("life.session-starts-once", function()
        local of = opened()
        Expect.throws(function()
            of.client.session:start()
        end, "has already started")
    end),

    -- A handle that was never put in a namespace, used.
    Harness.case("life.never-defined", function()
        local stray: any = Packet.new(Codecs.bool())
        Expect.throws(function()
            stray:fireServer(CARRIED)
        end, "before it was named in a namespace")
    end),

    -- A request still in flight when its own machine closes, and the name that failure has.
    Harness.case("life.close-resolves", function()
        local of = opened()
        local done = asking(of)
        Expect.equal(#done, 0)

        of.server.session:close()
        Expect.equal(#done, 1)
        Expect.equal(done[1].ok, false)
        Expect.equal(done[1].code, "shutdown")
        Expect.equal((done[1].data :: Types.OutcomeData).definition, ASKS)
    end),

    -- When the compiling happens, which is at the start and not at the first use.
    Harness.case("life.start-compiles", function()
        local defs = defined()
        defs[MARKED] = Packet.new(Codecs.int(0, 100):newest())
        local thrown = Expect.throws(function()
            Session.new(SPACE, defs, Doubles.wire():server(), Doubles.roster(), "server")
        end)
        Expect.holds(string.find(thrown, MARKED, 1, true) ~= nil, `it said "{thrown}"`)

        local of = opened()
        for name in defined() do
            Expect.holds(#of.server.defs[name]:describe() > 0, `{name} describes as nothing`)
        end
    end),
}
