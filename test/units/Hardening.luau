--!strict
--!optimize 2
-- What a hostile client can make the server spend: records for its drops, threads for its
-- requests, and the instant its stamps claim.

local Boundary = require("@src/runtime/Boundary")
local Catalog = require("@src/kernel/Catalog")
local Clock = require("@src/wire/Clock")
local Codecs = require("@src/codec")
local Compile = require("@src/shape/Compile")
local Dispatch = require("@src/runtime/Dispatch")
local Pending = require("@src/runtime/Pending")
local Protocol = require("@src/wire/Protocol")
local Router = require("@src/runtime/Router")
local Session = require("@src/runtime/Session")

local Doubles = require("@fixtures/Doubles")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")
local Records = require("@test/harness/Records")

local SPACE = "Arena"
local ROOM = 256
local NOW = 50
local FLOOD = 30
local BURST = Protocol.DROP_BURST
local AT = table.freeze({ file = "Game.Net", line = 1 })

type Rig = {
    roster: Doubles.Roster,
    wire: Doubles.Wire,
    server: Session.Session,
    clients: { [Player]: Session.Session },
    def: (name: string) -> any,
}

type Routed = {
    space: Compile.Compiled,
    of: Router.Wiring,
    heard: Dispatch.Wiring,
    alice: Player,
    bob: Player,
}

local function packet(of: any, stamped: boolean?): any
    return {
        kind = "packet",
        of = of,
        isUnreliable = stamped == true,
        isNewest = false,
        isTimestamped = stamped == true,
        at = AT,
    }
end

-- Every value over fifty is turned away by a check, which the frame resumes past, so one frame
-- can carry as many drops as it has payloads.
local function definitions(): any
    local checked = Codecs.int(0, 100):validate(function(value: number): string?
        return if value > 50 then "too high" else nil
    end)
    return {
        Hit = packet(checked),
        Shot = packet(Codecs.int(0, 100), true),
        Ping = { kind = "query", of = Codecs.int(0, 100), reply = Codecs.str(0, 8), at = AT },
    }
end

local function rigged(labels: { string }): Rig
    local roster = Doubles.roster()
    local wire = Doubles.wire()
    local server = Session.new(SPACE, definitions(), wire:server(), roster, "server")
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

local function routed(): Routed
    local space = Compile.build(SPACE, definitions())
    local heard = Dispatch.wiring()
    local of = Router.wiring(space, Boundary.new(SPACE), heard, Pending.new(SPACE))
    of.epoch = 10
    local roster = Doubles.roster()
    return {
        space = space,
        of = of,
        heard = heard,
        alice = roster:join("alice"),
        bob = roster:join("bob"),
    }
end

local function pumped(rig: Rig)
    rig.server:flush(4096)
    for _, client in rig.clients do
        client:flush(4096)
    end
    rig.wire:settle()
end

-- A frame of one running block of `count` copies of `value`.
local function running(def: Compile.Packet, value: number, count: number): buffer
    local b = buffer.create(ROOM)
    def.head.write(b, 0, { def.id, count - 1 })
    local at = def.head.bytes
    for _ = 1, count do
        at = def.built.write(b, at, value)
    end
    local out = buffer.create(at)
    buffer.copy(out, 0, b, 0, at)
    return out
end

-- A stamped block claiming to have been sent at `sent`.
local function claimed(rig: Routed, sent: number): buffer
    local shot = rig.space.byName.Shot :: Compile.Packet
    local b = buffer.create(shot.head.bytes + 1)
    shot.head.write(b, 0, { shot.id, Clock.stamp(Clock.elapsed(sent, rig.of.epoch)) })
    shot.built.write(b, shot.head.bytes, 3)
    return b
end

local function coded(held: { Records.Held }, code: string): number
    local count = 0
    for _, one in held do
        if one.data.code == code and one.data.suppressed == nil then
            count += 1
        end
    end
    return count
end

local function summaries(held: { Records.Held }): { Records.Held }
    local out = {}
    for _, one in held do
        if one.data.suppressed ~= nil then table.insert(out, one) end
    end
    return out
end

return {
    -- A client's frame of thirty refused payloads leaves a burst of records rather than thirty,
    -- another frame inside the window leaves none, and its leaving says how many were counted.
    Harness.case("hardening.flood-bounded", function()
        local rig = rigged({ "alice" })
        local alice = rig.roster:named("alice") :: Player
        local flood = running(rig.def("Hit"), 70, FLOOD)
        local first = Records.made(function()
            rig.wire:hands({ at = "reliable", from = alice, bytes = flood })
        end)
        Expect.equal(coded(first, Catalog.VALIDATE), BURST)
        Expect.equal(#first, BURST)

        local again = Records.made(function()
            rig.wire:hands({ at = "reliable", from = alice, bytes = flood })
        end)
        Expect.equal(#again, 0)

        local gone = Records.made(function()
            rig.roster:leave(alice)
        end)
        local said = summaries(gone)
        Expect.equal(#said, 1)
        Expect.equal(said[1].kind, "warn")
        Expect.equal(said[1].data.code, Catalog.VALIDATE)
        Expect.equal(said[1].data.player, alice)
        Expect.equal(said[1].data.suppressed, FLOOD * 2 - BURST)
        Expect.equal(rig.server.boundary.quiet[alice], nil)
    end),

    -- A flood of junk hellos is a flood of drops like any other, held to the same burst.
    Harness.case("hardening.hellos-throttled", function()
        local rig = rigged({ "alice" })
        local alice = rig.roster:named("alice") :: Player
        local held = Records.made(function()
            for _ = 1, FLOOD do
                rig.wire:hands({ at = "handshake", from = alice, bytes = buffer.create(3) })
            end
        end)
        Expect.equal(coded(held, Catalog.HELLO), BURST)
    end),

    -- The window reopening says how many it counted before the next record, and each sender and
    -- each code has a window of its own.
    Harness.case("hardening.summary-when-window-reopens", function()
        local rig = routed()
        local hit = rig.space.byName.Hit :: Compile.Packet
        local flood = running(hit, 70, FLOOD)
        Router.frame(rig.of, rig.alice, false, flood, nil, NOW)
        local bob = Records.made(function()
            Router.frame(rig.of, rig.bob, false, flood, nil, NOW)
        end)
        Expect.equal(#bob, BURST)

        local short = buffer.create(1)
        hit.head.write(short, 0, { hit.id, 3 })
        local other = Records.made(function()
            Router.frame(rig.of, rig.alice, false, short, nil, NOW)
        end)
        Expect.equal(coded(other, Catalog.BOUNDS), 1)

        local reopened = Records.made(function()
            Router.frame(rig.of, rig.alice, false, flood, nil, NOW + Protocol.DROP_WINDOW)
        end)
        Expect.equal(#reopened, BURST + 1)
        Expect.equal(reopened[1].data.suppressed, FLOOD - BURST)
        Expect.equal(reopened[1].data.player, rig.alice)
        Expect.equal(coded(reopened, Catalog.VALIDATE), BURST)
    end),

    -- What the server sends is the library's own, so every drop of it is recorded as an error.
    Harness.case("hardening.trusted-never-throttled", function()
        local rig = routed()
        local flood = running(rig.space.byName.Hit :: Compile.Packet, 70, FLOOD)
        local held = Records.made(function()
            for _ = 1, 3 do
                Router.frame(rig.of, nil, false, flood, nil, NOW)
            end
        end)
        Expect.equal(#held, FLOOD * 3)
        Expect.equal(#summaries(held), 0)
        for _, one in held do
            Expect.equal(one.kind, "error")
        end
    end),

    -- A packet clients send to nobody is said once until something listens again. One the server
    -- sends to nobody is said every time.
    Harness.case("hardening.unheard-once", function()
        local rig = routed()
        local hit = rig.space.byName.Hit :: Compile.Packet
        local one = running(hit, 7, 3)
        local held = Records.made(function()
            for _ = 1, 3 do
                Router.frame(rig.of, rig.alice, false, one, nil, NOW)
                Router.frame(rig.of, rig.bob, false, one, nil, NOW)
            end
        end)
        Expect.equal(#held, 1)
        Expect.equal(held[1].data.definition, "Hit")

        local trusted = Records.made(function()
            Router.frame(rig.of, nil, false, one, nil, NOW)
            Router.frame(rig.of, nil, false, one, nil, NOW)
        end)
        Expect.equal(#trusted, 2)

        Dispatch.listen(rig.heard, hit.id, function() end):disconnect()
        local relapsed = Records.made(function()
            Router.frame(rig.of, rig.alice, false, one, nil, NOW)
            Router.frame(rig.of, rig.alice, false, one, nil, NOW)
        end)
        Expect.equal(#relapsed, 1)
    end),

    -- A client may hold only so many responders at once. One past it is unanswered at once, and
    -- room comes back as responders return, throw, or the client leaves.
    Harness.case("hardening.responder-cap", function()
        local rig = rigged({ "alice" })
        local alice = rig.roster:named("alice") :: Player
        local client = rig.clients[alice]
        local ping = rig.def("Ping")
        local parked: { thread } = {}
        rig.server:respond(ping.id, "Ping", function(value: number): string
            if value == 0 then error("zero") end
            table.insert(parked, coroutine.running())
            return coroutine.yield()
        end)
        local told: { any } = {}
        local function ask(value: number, times: number)
            for _ = 1, times do
                client:ask(ping, nil, value, nil, function(ok, result)
                    table.insert(told, { ok, result })
                end)
            end
        end

        local cap = Protocol.RESPONDER_CAP
        ask(1, cap + 5)
        pumped(rig)
        pumped(rig)
        Expect.equal(#parked, cap)
        Expect.equal(rig.server.boundary.running[alice], cap)
        Expect.equal(#told, 5)
        for _, one in told do
            Expect.equal(one, { false, "unanswered" })
        end

        table.clear(told)
        for index = 1, 10 do
            task.spawn(parked[index], "ok")
        end
        Expect.equal(rig.server.boundary.running[alice], cap - 10)
        ask(1, 10)
        pumped(rig)
        pumped(rig)
        Expect.equal(#parked, cap + 10)
        Expect.equal(rig.server.boundary.running[alice], cap)
        Expect.equal(#told, 10)
        for _, one in told do
            Expect.equal(one, { true, "ok" })
        end

        -- A responder that throws hands its room back too.
        table.clear(told)
        task.spawn(parked[11], "ok")
        ask(0, 1)
        pumped(rig)
        pumped(rig)
        Expect.equal(rig.server.boundary.running[alice], cap - 1)

        rig.roster:leave(alice)
        Expect.equal(rig.server.boundary.running[alice], nil)
        for index = 12, #parked do
            task.spawn(parked[index], "late")
        end
        Expect.equal(rig.server.boundary.running[alice], nil)
    end),

    -- A client's stamp is held between the window before its arrival and the arrival itself. The
    -- server's is read as it says.
    Harness.case("hardening.stamps-clamped", function()
        local rig = routed()
        local shot = rig.space.byName.Shot :: Compile.Packet
        local stamps: { number } = {}
        Dispatch.listen(rig.heard, shot.id, function(_value: any, a: any, b: any)
            table.insert(stamps, if typeof(a) == "number" then a else b)
        end)
        Router.frame(rig.of, rig.alice, true, claimed(rig, NOW + 100), nil, NOW)
        Router.frame(rig.of, rig.alice, true, claimed(rig, NOW - 3600), nil, NOW)
        Router.frame(rig.of, rig.alice, true, claimed(rig, NOW - 0.25), nil, NOW)
        Router.frame(rig.of, nil, true, claimed(rig, NOW + 100), nil, NOW)
        Expect.equal(#stamps, 4)
        Expect.equal(stamps[1], NOW)
        Expect.equal(stamps[2], NOW - Protocol.STAMP_WINDOW)
        Expect.near(stamps[3], NOW - 0.25, 0.002)
        Expect.near(stamps[4], NOW + 100, 0.002)
    end),
}
