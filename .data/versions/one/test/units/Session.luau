--!strict
--!optimize 2
-- One namespace on two machines over the wire double: the handshake, packets on every lane,
-- questions and answers, a set, departures and the close.

local Codecs = require("@src/codec")
local Handshake = require("@src/runtime/Handshake")
local Log = require("@src/kernel/Log")
local Protocol = require("@src/wire/Protocol")
local Recipients = require("@src/channel/Recipients")
local Session = require("@src/runtime/Session")
local Sync = require("@src/state/Sync")
local Varint = require("@src/wire/Varint")

local Doubles = require("@fixtures/Doubles")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")

local SPACE = "Arena"

-- How long two fires are held apart to tell their stamps apart, and the slack a millisecond
-- stamp and a scheduler are allowed under it.
local PAUSE = 0.03
local SLACK = 0.005
local AT = table.freeze({ file = "Game.Net", line = 1 })

type Rig = {
    roster: Doubles.Roster,
    wire: Doubles.Wire,
    server: Session.Session,
    clients: { [Player]: Session.Session },
    def: (name: string) -> any,
}

local function packet(of: any, unreliable: boolean?, newest: boolean?, stamped: boolean?): any
    return {
        kind = "packet",
        of = of,
        isUnreliable = unreliable == true,
        isNewest = newest == true,
        hz = if newest then 60 else nil,
        isTimestamped = stamped == true,
        at = AT,
    }
end

local function definitions(): any
    return {
        Hit = packet(Codecs.int(0, 100)),
        Look = packet(Codecs.int(0, 100), false, true),
        Shot = packet(Codecs.int(0, 100), true, false, true),
        Both = packet(Codecs.int(0, 100), false, true, true),
        Ping = { kind = "query", of = Codecs.int(0, 100), reply = Codecs.str(0, 8), at = AT },
        Team = {
            kind = "set",
            of = Codecs.struct({ hp = Codecs.int(0, 100), name = Codecs.str(0, 8) }),
            at = AT,
        },
    }
end

-- A server and one client per named player, all started and past the handshake.
local function rigged(labels: { string }): Rig
    local roster = Doubles.roster()
    local wire = Doubles.wire()
    local defs = definitions()
    local server = Session.new(SPACE, defs, wire:server(), roster, "server")
    server:start()
    local clients: { [Player]: Session.Session } = {}
    for _, label in labels do
        local who = roster:join(label)
        local client = Session.new(SPACE, definitions(), wire:client(who), roster, "client")
        client:start()
        clients[who] = client
    end
    wire:settle()
    return {
        roster = roster,
        wire = wire,
        server = server,
        clients = clients,
        def = function(name: string): any
            return server.space.byName[name]
        end,
    }
end

local function heard(session: Session.Session, def: any): { any }
    local out = {}
    session:listen(def.id, function(...)
        table.insert(out, { ... })
    end)
    return out
end

local function pumped(rig: Rig)
    rig.server:flush(4096)
    for _, client in rig.clients do
        client:flush(4096)
    end
    rig.wire:settle()
end

return {
    -- A client joining handshakes and is admitted, an unmatched build is refused, and a frame
    -- arriving before the handshake is recorded.
    Harness.case("session.handshake", function()
        local rig = rigged({ "alice" })
        local alice = rig.roster:named("alice") :: Player
        Expect.equal(rig.server.link.ready[alice], true)
        Expect.equal(rig.clients[alice].link.sending, true)
        Expect.equal(rig.clients[alice].router.epoch, rig.server.router.epoch)

        -- A second hello from a client already admitted is answered and seeds nothing again, since
        -- eight bytes must not buy a resend of every record the client can see.
        local team = rig.server:set(rig.def("Team").id)
        for id = 1, 20 do
            Sync.add(team, id, { hp = id, name = "n" })
        end
        pumped(rig)
        local before = rig.wire:moved().bytes
        rig.clients[alice].transport:fire("handshake", nil, Handshake.hello(rig.server.space.hash))
        pumped(rig)
        pumped(rig)
        -- The lane carried the hello and its verdict, and not one byte of state.
        local answered = Protocol.HELLO_BYTES + Protocol.VERDICT_BYTES
        Expect.equal(rig.wire:moved().bytes - before, answered)
        Expect.equal(rig.server.link.ready[alice], true)

        local other = Doubles.wire()
        local roster = Doubles.roster()
        local bob = roster:join("bob")
        local server = Session.new(SPACE, definitions(), other:server(), roster, "server")
        server:start()
        local mismatched = { Hit = packet(Codecs.int(0, 7)) }
        local client = Session.new(SPACE, mismatched, other:client(bob), roster, "client")
        client:start()
        Expect.throws(function()
            other:settle()
        end)
        Expect.equal(client.link.sending, false)
        Expect.equal(server.link.ready[bob], nil)

        -- A verdict of the wrong length is recorded and leaves the client where it was: silent,
        -- and stamping against the epoch it started with rather than one read off junk.
        local epoch = client.router.epoch
        server.transport:fire("handshake", bob, buffer.create(3))
        other:settle()
        Expect.equal(client.link.sending, false)
        Expect.equal(client.router.epoch, epoch)
    end),

    -- Packets fired in a run reach every client in order, one at a player reaches only them, a
    -- stamped packet carries its instant, and a newest packet coalesces to its last value.
    Harness.case("session.packets", function()
        local rig = rigged({ "alice", "bob" })
        local alice = rig.roster:named("alice") :: Player
        local bob = rig.roster:named("bob") :: Player
        local hit, shot, look = rig.def("Hit"), rig.def("Shot"), rig.def("Look")
        local ears = {
            alice = heard(rig.clients[alice], hit),
            bob = heard(rig.clients[bob], hit),
            server = heard(rig.server, hit),
        }
        for value = 1, 3 do
            rig.server:fire(hit, nil, value)
        end
        rig.server:fire(hit, bob, 9)
        rig.server:fire(hit, Recipients.except(bob), 8)
        rig.clients[alice]:fire(hit, nil, 42)
        pumped(rig)
        Expect.equal(ears.alice, { { 1 }, { 2 }, { 3 }, { 8 } })
        Expect.equal(ears.bob, { { 1 }, { 2 }, { 3 }, { 9 } })
        Expect.equal(ears.server, { { 42, alice } })

        local stamps = heard(rig.clients[alice], shot)
        rig.server:fire(shot, nil, 5)
        pumped(rig)
        Expect.equal(#stamps, 1)
        Expect.equal(stamps[1][1], 5)
        Expect.holds(type(stamps[1][2]) == "number", "a stamped packet carried no instant")

        -- The instant is the sender's own reading, so two fires a pause apart arrive that far
        -- apart, on the lossy lane and on a newest packet alike.
        local both = rig.def("Both")
        local paired = heard(rig.clients[alice], both)
        rig.server:fire(both, nil, 7)
        pumped(rig)
        local began = os.clock()
        while os.clock() - began < PAUSE do
        end
        rig.server:fire(shot, nil, 6)
        rig.server:fire(both, nil, 8)
        pumped(rig)
        Expect.equal(#stamps, 2)
        Expect.equal(#paired, 2)
        for _, arrived in { stamps, paired } do
            local moved = arrived[2][2] - arrived[1][2]
            Expect.holds(
                moved >= PAUSE - SLACK and moved < 1,
                `stamps moved {moved} s over a pause of {PAUSE} s`
            )
        end

        local looks = heard(rig.clients[alice], look)
        rig.server:fire(look, nil, 1)
        rig.server:fire(look, nil, 2)
        pumped(rig)
        rig.server:fire(look, nil, 2)
        pumped(rig)
        Expect.equal(looks, { { 2 } })
    end),

    -- A question reaches the responder with who asked and the answer comes back to whoever asked,
    -- a raising responder ends the request unanswered, and a client's own question reaches the
    -- server's responder.
    Harness.case("session.queries", function()
        local rig = rigged({ "alice" })
        local alice = rig.roster:named("alice") :: Player
        local client = rig.clients[alice]
        local ping = rig.def("Ping")
        rig.server:respond(ping.id, "Ping", function(value: number, who: Player)
            return `{who.Name}:{value}`
        end)
        client:respond(ping.id, "Ping", function(value: number)
            if value == 0 then error("zero") end
            return `client:{value}`
        end)

        local done = {}
        rig.server:ask(ping, alice, 5, nil, function(ok, result)
            table.insert(done, { "server", ok, result })
        end)
        rig.server:ask(ping, alice, 0, nil, function(ok, result)
            table.insert(done, { "server", ok, result })
        end)
        client:ask(ping, nil, 7, nil, function(ok, result)
            table.insert(done, { "client", ok, result })
        end)
        pumped(rig)
        pumped(rig)
        Expect.equal(done, {
            { "client", true, "alice:7" },
            { "server", true, "client:5" },
            { "server", false, "unanswered" },
        })
    end),

    -- A set replicated to a client that joined later is caught up, and a departure clears every
    -- place the player was held.
    Harness.case("session.sets-and-departures", function()
        local rig = rigged({ "alice" })
        local alice = rig.roster:named("alice") :: Player
        local team = rig.def("Team")
        local server = rig.server:set(team.id)
        Sync.add(server, 1, { hp = 50, name = "one" })
        pumped(rig)
        Expect.equal(Sync.get(rig.clients[alice]:set(team.id), 1), { hp = 50, name = "one" })

        local bob = rig.roster:join("bob")
        local late = Session.new(SPACE, definitions(), rig.wire:client(bob), rig.roster, "client")
        late:start()
        rig.wire:settle()
        rig.clients[bob] = late
        Sync.update(server, 1, { hp = 60 })
        pumped(rig)
        pumped(rig)
        Expect.equal(Sync.get(late:set(team.id), 1), { hp = 60, name = "one" })

        local done = {}
        rig.server:ask(rig.def("Ping"), bob, 1, nil, function(ok, result)
            table.insert(done, { ok, result })
        end)
        rig.roster:leave(bob)
        Expect.equal(done, { { false, "leave" } })
        Expect.equal(rig.server.link.ready[bob], nil)
        rig.wire:gone(bob)
        Sync.update(server, 1, { hp = 70 })
        pumped(rig)
        Expect.equal(Sync.get(rig.clients[alice]:set(team.id), 1).hp, 70)
    end),

    -- Closing flushes what is queued, ends every open request as a shutdown, and a second start
    -- or a flush under the floor is refused.
    Harness.case("session.close", function()
        local rig = rigged({ "alice" })
        local alice = rig.roster:named("alice") :: Player
        local hit = rig.def("Hit")
        local ears = heard(rig.clients[alice], hit)
        local done = {}
        rig.server:ask(rig.def("Ping"), alice, 1, nil, function(ok, result)
            table.insert(done, { ok, result })
        end)
        rig.server:fire(hit, nil, 3)
        rig.server:close()
        rig.wire:settle()
        Expect.equal(ears, { { 3 } })
        Expect.equal(done, { { false, "shutdown" } })
        Expect.equal(rig.server.closed, true)
        rig.server:close()

        Expect.throws(function()
            rig.clients[alice]:start()
        end, "already started")
        Expect.throws(function()
            rig.clients[alice]:flush(10)
        end, "under the floor")

        -- A frame time, which is what a RunService signal hands a flush connected to it straight,
        -- is refused with the cause named.
        Expect.throws(function()
            rig.clients[alice]:flush(1 / 60)
        end, "frame time")
        local quiet = 0
        local link = Log.onLog(function()
            quiet += 1
        end)
        rig.clients[alice]:flush()
        link:disconnect()
        Expect.equal(quiet, 0)
    end),

    -- Nothing aimed at a client that is not admitted reaches the outbox: a question to one still
    -- loading ends unanswered, and an answer to one who left is let go, neither breaking a flush.
    Harness.case("session.unadmitted-targets", function()
        local rig = rigged({ "alice" })
        local alice = rig.roster:named("alice") :: Player
        local ping, hit = rig.def("Ping"), rig.def("Hit")
        local carol = rig.roster:join("carol")
        local told: { any } = {}
        rig.server:ask(ping, carol, 1, nil, function(ok, code)
            table.insert(told, { ok, code })
        end)
        rig.server:flush(4096)
        Expect.equal(told, { { false, "unanswered" } })

        local parked: thread? = nil
        rig.server:respond(ping.id, "Ping", function(): string
            parked = coroutine.running()
            return coroutine.yield()
        end)
        rig.clients[alice]:ask(ping, nil, 3, nil, function() end)
        pumped(rig)
        rig.roster:leave(alice)
        task.spawn(parked :: thread, "late")
        rig.server:fire(hit, nil, 1)
        rig.server:flush(4096)
    end),

    -- Frames from a client that never handshook are ignored, a payload that is no buffer is
    -- ignored, and a hello handled after its sender left admits nobody.
    Harness.case("session.hostile-frames", function()
        local rig = rigged({ "alice" })
        local alice = rig.roster:named("alice") :: Player
        local hit = rig.def("Hit")
        local ears = heard(rig.server, hit)
        local captured: buffer? = nil
        rig.wire:watch(function(frame: Doubles.Carried)
            if frame.from == alice and frame.at == "reliable" then captured = frame.bytes end
        end)
        rig.clients[alice]:fire(hit, nil, 7)
        pumped(rig)
        Expect.equal(ears, { { 7, alice } })

        local mallory = rig.roster:join("mallory")
        rig.wire:hands({ at = "reliable", from = mallory, bytes = captured :: buffer })
        rig.wire:hands({ at = "reliable", from = alice, bytes = "junk" :: any })
        rig.wire:hands({ at = "handshake", from = alice, bytes = 5 :: any })
        Expect.equal(#ears, 1)

        local bob = rig.roster:join("bob")
        rig.roster:leave(bob)
        local hello = Handshake.hello(rig.server.space.hash)
        rig.wire:hands({ at = "handshake", from = bob, bytes = hello })
        Expect.equal(rig.server.link.ready[bob], nil)
    end),

    -- A server's sets are its own: a state frame sent up by a client is dropped, and a request
    -- block cut short or naming an id past the id space is dropped without raising.
    Harness.case("session.client-cannot-write", function()
        local rig = rigged({ "alice" })
        local alice = rig.roster:named("alice") :: Player
        local team = rig.server:set(rig.def("Team").id)
        local state: { buffer } = {}
        rig.wire:watch(function(frame: Doubles.Carried)
            if frame.from == nil and frame.at == "reliable" then
                table.insert(state, frame.bytes)
            end
        end)
        Sync.add(team, 99, { hp = 13, name = "evil" })
        rig.server:flush(4096)
        rig.wire:settle()
        Sync.remove(team, 99)
        rig.server:flush(4096)
        rig.wire:settle()
        rig.wire:hands({ at = "reliable", from = alice, bytes = state[1] })
        Expect.equal(Sync.get(team, 99), nil)

        local ping = rig.def("Ping")
        local short = buffer.create(ping.asks.bytes)
        ping.asks.write(short, 0, { ping.id, 0 })
        rig.wire:hands({ at = "reliable", from = alice, bytes = short })

        local far = buffer.create(ping.asks.bytes + 16)
        ping.asks.write(far, 0, { ping.id, 1 })
        local at = ping.asks.bytes
        ping.asking.write(far, at, { 0 })
        at += ping.asking.bytes
        buffer.writeu8(far, at, 1)
        at = Varint.write(far, at + 1, 2 ^ 52)
        rig.wire:hands({ at = "reliable", from = alice, bytes = far })
        pumped(rig)
    end),

    -- Every payload in a run is its own arrival, so a validate holding a sender to a rate sees the
    -- one before it as `last`, and a run of thirty in one frame delivers one.
    Harness.case("session.rate-per-payload", function()
        local roster = Doubles.roster()
        local wire = Doubles.wire()
        local function rated(): any
            local check = function(_: number, ctx: any): string?
                if ctx.last ~= nil and ctx.now - ctx.last < 0.1 then return "too fast" end
                return nil
            end
            return { Rated = packet(Codecs.int(0, 100):validate(check)) }
        end
        local server = Session.new(SPACE, rated(), wire:server(), roster, "server")
        server:start()
        local alice = roster:join("alice")
        local client = Session.new(SPACE, rated(), wire:client(alice), roster, "client")
        client:start()
        wire:settle()
        local def = server.space.byName.Rated :: any
        local ears = heard(server, def)
        for value = 1, 30 do
            client:fire(def, nil, value)
        end
        client:flush(4096)
        wire:settle()
        Expect.equal(#ears, 1)
    end),

    -- A value its codec refuses is refused at the call and leaves nothing half written: a request
    -- joining an open run keeps the run whole, and a newest packet does not wedge later flushes.
    Harness.case("session.refused-at-call", function()
        local rig = rigged({ "alice" })
        local alice = rig.roster:named("alice") :: Player
        local ping, look, hit = rig.def("Ping"), rig.def("Look"), rig.def("Hit")
        local client = rig.clients[alice]
        local asked: { number } = {}
        rig.server:respond(ping.id, "Ping", function(value: number): string
            table.insert(asked, value)
            return "ok"
        end)
        client:ask(ping, nil, 1, nil, function() end)
        Expect.throws(function()
            client:ask(ping, nil, 999, nil, function() end)
        end, "expected int(0,100)")
        client:ask(ping, nil, 3, nil, function() end)
        pumped(rig)
        Expect.equal(asked, { 1, 3 })

        Expect.throws(function()
            rig.server:fire(look, nil, 999)
        end, "expected int(0,100)")
        local ears = heard(client, hit)
        rig.server:fire(hit, nil, 4)
        pumped(rig)
        Expect.equal(ears, { { 4 } })
    end),

    -- A reliable frame that lands before the verdict, which rides a remote of its own, is kept and
    -- read once the verdict arrives rather than dropped.
    Harness.case("session.early-frame-kept", function()
        local rig = rigged({ "alice" })
        local alice = rig.roster:named("alice") :: Player
        local hit = rig.def("Hit")
        local captured: buffer? = nil
        rig.wire:watch(function(frame: Doubles.Carried)
            if frame.to == alice and frame.at == "reliable" then captured = frame.bytes end
        end)
        rig.server:fire(hit, alice, 6)
        pumped(rig)

        local carol = rig.roster:join("carol")
        local client =
            Session.new(SPACE, definitions(), rig.wire:client(carol), rig.roster, "client")
        local ears = heard(client, hit)
        local warned = 0
        local hook = Log.onLog(function(_, _, data)
            if data.code == "drop.unready" then
                warned += 1
            end
        end)
        client:start()
        rig.wire:hands({ at = "reliable", to = carol, bytes = captured :: buffer })
        Expect.equal(#ears, 0)
        rig.wire:settle()
        hook:disconnect()
        Expect.equal(ears, { { 6 } })
        Expect.equal(warned, 0)
    end),

    -- An answer counts only from the client that was asked.
    Harness.case("session.forged-answer", function()
        local rig = rigged({ "alice", "bob" })
        local alice = rig.roster:named("alice") :: Player
        local bob = rig.roster:named("bob") :: Player
        local ping = rig.def("Ping")
        rig.clients[bob]:respond(ping.id, "Ping", function(): string
            return "real"
        end)
        local told: { any } = {}
        rig.server:ask(ping, bob, 1, nil, function(ok, reply)
            table.insert(told, { ok, reply })
        end)
        rig.server:flush(4096)
        rig.clients[alice].router.answered(ping, 0, nil, true, "forged")
        rig.clients[alice]:flush(4096)
        rig.wire:settle()
        pumped(rig)
        Expect.equal(told, { { true, "real" } })
    end),

    -- A newest packet holds a value per recipient, so two players in one flush each get theirs,
    -- and a value one already got still reaches the other.
    Harness.case("session.newest-per-recipient", function()
        local rig = rigged({ "alice", "bob" })
        local alice = rig.roster:named("alice") :: Player
        local bob = rig.roster:named("bob") :: Player
        local look = rig.def("Look")
        local ears =
            { alice = heard(rig.clients[alice], look), bob = heard(rig.clients[bob], look) }
        rig.server:fire(look, alice, 1)
        rig.server:fire(look, bob, 2)
        pumped(rig)
        Expect.equal(ears, { alice = { { 1 } }, bob = { { 2 } } })

        rig.server:fire(look, alice, 5)
        pumped(rig)
        local began = os.clock()
        while os.clock() - began < PAUSE do
        end
        rig.server:fire(look, bob, 5)
        pumped(rig)
        Expect.equal(ears.bob, { { 2 }, { 5 } })
    end),
}
