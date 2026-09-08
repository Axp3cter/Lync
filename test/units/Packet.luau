--!strict
--!optimize 2
-- The packet and query handles, driven from both machines over the wire double: what each
-- declares, what it refuses on the wrong side or at the wrong time, and what it carries.

local Codecs = require("@src/codec")
local Define = require("@src/api/Define")
local Packet = require("@src/api/Packet")
local Query = require("@src/api/Query")
local Recipients = require("@src/channel/Recipients")
local Session = require("@src/runtime/Session")

local Doubles = require("@fixtures/Doubles")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")

type Handles = { [string]: any }

type Rig = {
    space: string,
    mine: Handles,
    theirs: Handles,
    server: Session.Session,
    client: Session.Session,
    wire: Doubles.Wire,
    alice: Player,
}

-- One set of handles per machine, as two scripts on two machines each declare their own.
local function declared(): Handles
    return {
        Hit = Packet.new(Codecs.int(0, 100)),
        Look = Packet.new(Codecs.int(0, 100)):newest(30),
        Shot = Packet.new(Codecs.int(0, 100)):unreliable():timestamped(),
        Ping = Query.new(Codecs.int(0, 100), Codecs.str(0, 8)),
    }
end

-- The server's handles named under the space, the client's bound straight to its session, both
-- started and past the handshake.
local function rigged(space: string, before: ((Handles, Handles) -> ())?): Rig
    local roster = Doubles.roster()
    local wire = Doubles.wire()
    local alice = roster:join("alice")
    local mine = Define.define(space, declared() :: any) :: Handles
    local theirs = declared()
    local server = Session.new(space, mine :: any, wire:server(), roster, "server")
    local client = Session.new(space, theirs :: any, wire:client(alice), roster, "client")
    if before ~= nil then before(mine, theirs) end
    server:start()
    client:start()
    wire:settle()
    return {
        space = space,
        mine = mine,
        theirs = theirs,
        server = server,
        client = client,
        wire = wire,
        alice = alice,
    }
end

local function pumped(rig: Rig)
    rig.server:flush(4096)
    rig.client:flush(4096)
    rig.wire:settle()
end

return {
    -- A handle describes its declaration as the descriptor spells it, modifiers chain and are
    -- refused after start, and each fire and listener is refused on the other machine.
    Harness.case("packet.declares", function()
        local hit = Packet.new(Codecs.int(0, 100))
        Expect.equal(hit:describe(), "packet[reliable,0,false](int(0,100))")
        Expect.equal(hit:newest(20):describe(), "packet[newest,20,false](int(0,100))")
        local shot = Packet.new(Codecs.bool()):unreliable():timestamped()
        Expect.equal(shot:describe(), "packet[unreliable,0,true](bool())")
        local ping = Query.new(Codecs.int(0, 1), Codecs.str(0, 2))
        Expect.equal(ping:describe(), "query(int(0,1))(str(0,2))")

        Expect.throws(function()
            hit:fireClient(Recipients.ALL, 1)
        end, "fireClient before it was named")

        local rig = rigged("PacketDeclares")
        Expect.throws(function()
            rig.mine.Hit:unreliable()
        end, "after PacketDeclares started")
        Expect.throws(function()
            rig.mine.Hit:fireServer(1)
        end, "fireServer is a client's call, and this is the server")
        Expect.throws(function()
            rig.theirs.Hit:fireClient(Recipients.ALL, 1)
        end, "fireClient is the server's call, and this is a client")
        Expect.throws(function()
            rig.theirs.Ping:onServer(function()
                return "x"
            end)
        end, "start seals responders")
    end),

    -- Fires reach the listeners on the other machine, a listener attached before start hears,
    -- a stamped fire carries its instant, a newest fire carries its last value, and a
    -- disconnected listener hears nothing more.
    Harness.case("packet.fires", function()
        local early = declared()
        local heard: { any } = {}
        local link = early.Hit:onClient(function(value: number, sent: number?)
            table.insert(heard, { value, sent })
        end)
        local roster = Doubles.roster()
        local wire = Doubles.wire()
        local alice = roster:join("alice")
        local mine = Define.define("PacketFires", declared() :: any) :: Handles
        local server = Session.new("PacketFires", mine :: any, wire:server(), roster, "server")
        local client =
            Session.new("PacketFires", early :: any, wire:client(alice), roster, "client")
        server:start()
        client:start()
        wire:settle()

        local shots: { any } = {}
        early.Shot:onClient(function(value: number, sent: number?)
            table.insert(shots, { value, sent })
        end)
        local looks: { any } = {}
        early.Look:onClient(function(value: number)
            table.insert(looks, value)
        end)
        local heardServer: { any } = {}
        mine.Hit:onServer(function(value: number, who: Player)
            table.insert(heardServer, { value, who.Name })
        end)

        mine.Hit:fireClient(Recipients.ALL, 7)
        mine.Hit:fireClient(alice, 8)
        mine.Shot:fireClient(Recipients.ALL, 9)
        mine.Look:fireClient(Recipients.ALL, 1)
        mine.Look:fireClient(Recipients.ALL, 2)
        early.Hit:fireServer(3)
        server:flush(4096)
        client:flush(4096)
        wire:settle()
        Expect.equal(heard, { { 7 }, { 8 } })
        Expect.equal(shots[1][1], 9)
        Expect.holds(type(shots[1][2]) == "number", "a stamped fire carried no instant")
        Expect.equal(looks, { 2 })
        Expect.equal(heardServer, { { 3, "alice" } })

        link:disconnect()
        mine.Hit:fireClient(Recipients.ALL, 1)
        server:flush(4096)
        wire:settle()
        Expect.equal(#heard, 2)
    end),

    -- A client's request yields until the server's responder answers, a server's request takes a
    -- completion, and each form is refused on the other machine.
    Harness.case("query.requests", function()
        local rig = rigged("QueryRequests", function(mine: Handles, theirs: Handles)
            mine.Ping:onServer(function(value: number, who: Player)
                return `{who.Name}:{value}`
            end)
            theirs.Ping:onClient(function(value: number)
                return `client:{value}`
            end)
            Expect.throws(function()
                mine.Ping:onServer(function()
                    return ""
                end)
            end, "already has a responder")
        end)

        local answered: { any } = {}
        task.spawn(function()
            local ok, result = rig.theirs.Ping:request(5)
            table.insert(answered, { "client", ok, result })
        end)
        rig.mine.Ping:request(rig.alice, 6, function(ok, result)
            table.insert(answered, { "server", ok, result })
        end)
        pumped(rig)
        pumped(rig)
        Expect.equal(answered, { { "client", true, "alice:5" }, { "server", true, "client:6" } })

        Expect.throws(function()
            rig.mine.Ping:request(5)
        end, "without a completion is a client's call")
        Expect.throws(function()
            rig.theirs.Ping:request(5, nil, function() end)
        end, "with a completion is the server's call")
    end),
}
