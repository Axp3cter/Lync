--!strict
--!optimize 2
-- One frame taken apart: every kind of block to where its definition sends it, and every way a
-- frame stops being read.

local Boundary = require("@src/runtime/Boundary")
local Catalog = require("@src/kernel/Catalog")
local Clock = require("@src/wire/Clock")
local Codecs = require("@src/codec")
local Compile = require("@src/shape/Compile")
local Dispatch = require("@src/runtime/Dispatch")
local Log = require("@src/kernel/Log")
local Pending = require("@src/runtime/Pending")
local Router = require("@src/runtime/Router")
local Varint = require("@src/wire/Varint")

local Doubles = require("@fixtures/Doubles")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")

local ROOM = 256
local NOW = 50
local AT = table.freeze({ file = "Game.Net", line = 1 })

type Rig = {
    space: Compile.Compiled,
    of: Router.Wiring,
    heard: Dispatch.Wiring,
    pending: Pending.Pending,
    alice: Player,
}

local function packet(of: any, unreliable: boolean?, newest: boolean?, stamped: boolean?): any
    return {
        kind = "packet",
        of = of,
        isUnreliable = unreliable == true,
        isNewest = newest == true,
        hz = if newest then 20 else nil,
        isTimestamped = stamped == true,
        at = AT,
    }
end

local function rigged(): Rig
    local space = Compile.build(
        "route",
        {
            Hit = packet(Codecs.int(0, 100)),
            Look = packet(Codecs.int(0, 100), false, true),
            Shot = packet(Codecs.int(0, 100), true, false, true),
            Who = packet(Codecs.inst()),
            Ping = { kind = "query", of = Codecs.int(0, 100), reply = Codecs.str(0, 8), at = AT },
            Team = { kind = "set", of = Codecs.struct({ hp = Codecs.int(0, 9) }), at = AT },
        } :: any
    )
    local heard = Dispatch.wiring()
    local pending = Pending.new("route")
    local of = Router.wiring(space, Boundary.new("route"), heard, pending)
    of.epoch = 10
    return {
        space = space,
        of = of,
        heard = heard,
        pending = pending,
        alice = Doubles.roster():join("alice"),
    }
end

local function drops(call: () -> ()): { string }
    local codes: { string } = {}
    local link = Log.onLog(function(_kind, _message, data)
        table.insert(codes, tostring(data.code))
    end)
    call()
    link:disconnect()
    return codes
end

-- The composed messages a run recorded, so a drop is held to naming what went wrong rather than
-- to its code alone.
local function said(call: () -> ()): { string }
    local lines: { string } = {}
    local link = Log.onLog(function(_kind, message)
        table.insert(lines, message)
    end)
    call()
    link:disconnect()
    return lines
end

-- A frame of one running packet block carrying the listed values.
local function running(rig: Rig, name: string, values: { number }): buffer
    local def = rig.space.byName[name] :: Compile.Packet
    local b = buffer.create(ROOM)
    def.head.write(b, 0, { def.id, #values - 1 })
    local at = def.head.bytes
    for _, value in values do
        at = def.built.write(b, at, value)
    end
    local out = buffer.create(at)
    buffer.copy(out, 0, b, 0, at)
    return out
end

return {
    -- A running block hands every payload to the listeners in order, two blocks in one frame both
    -- arrive, and a block from a player carries the player.
    Harness.case("router.packets", function()
        local rig = rigged()
        local heard = {}
        Dispatch.listen(rig.heard, rig.space.byName.Hit.id, function(value: any, who: any)
            table.insert(heard, { value, who })
        end)
        local one = running(rig, "Hit", { 7, 8, 9 })
        local two = running(rig, "Hit", { 1 })
        local both = buffer.create(buffer.len(one) + buffer.len(two))
        buffer.copy(both, 0, one)
        buffer.copy(both, buffer.len(one), two)
        Router.frame(rig.of, nil, false, both, nil, NOW)
        Expect.equal(heard, { { 7 }, { 8 }, { 9 }, { 1 } })

        table.clear(heard)
        Router.frame(rig.of, rig.alice, false, one, nil, NOW)
        Expect.equal(heard, { { 7, rig.alice }, { 8, rig.alice }, { 9, rig.alice } })
    end),

    -- A newest block behind one already heard from the same sender is dropped whole, and a
    -- stamped block hands the send instant on the shared clock beside the value.
    Harness.case("router.newest-and-stamped", function()
        local rig = rigged()
        local look = rig.space.byName.Look :: Compile.Packet
        local seqs = {}
        Dispatch.listen(rig.heard, look.id, function(value: any)
            table.insert(seqs, value)
        end)
        local function newest(seq: number, value: number): buffer
            local b = buffer.create(look.head.bytes + 1)
            look.head.write(b, 0, { look.id, seq })
            look.built.write(b, look.head.bytes, value)
            return b
        end
        Router.frame(rig.of, nil, true, newest(5, 1), nil, NOW)
        Router.frame(rig.of, nil, true, newest(4, 2), nil, NOW)
        Router.frame(rig.of, nil, true, newest(6, 3), nil, NOW)
        Router.frame(rig.of, rig.alice, true, newest(4, 4), nil, NOW)
        Expect.equal(seqs, { 1, 3, 4 })

        local shot = rig.space.byName.Shot :: Compile.Packet
        local stamps = {}
        Dispatch.listen(rig.heard, shot.id, function(_value: any, sent: any)
            table.insert(stamps, sent)
        end)
        local b = buffer.create(shot.head.bytes + 1)
        local elapsed = Clock.elapsed(NOW - 0.25, rig.of.epoch)
        shot.head.write(b, 0, { shot.id, Clock.stamp(elapsed) })
        shot.built.write(b, shot.head.bytes, 3)
        Router.frame(rig.of, nil, true, b, nil, NOW)
        Expect.equal(#stamps, 1)
        Expect.holds(math.abs(stamps[1] - (NOW - 0.25)) < 0.002, `the stamp read {stamps[1]}`)
    end),

    -- A request block runs the responder for each question and hands every answer on, and a
    -- response block answers or fails the pending request each names.
    Harness.case("router.queries", function()
        local rig = rigged()
        local ping = rig.space.byName.Ping :: Compile.Query
        Dispatch.respond(rig.heard, ping.id, "Ping", function(value: number, who: any)
            if value == 0 then error("zero") end
            return `{value}:{if who == nil then "server" else who.Name}`
        end)
        local answers = {}
        rig.of.answered = function(_def, asked, player, ok, value)
            table.insert(answers, { asked, player, ok, value })
        end

        local b = buffer.create(ROOM)
        ping.asks.write(b, 0, { ping.id, 2 })
        local at = ping.asks.bytes
        ping.asking.write(b, at, { 40 })
        at = ping.request.write(b, at + ping.asking.bytes, 5)
        at = Varint.write(b, at, 1)
        at = ping.request.write(b, at, 0)
        at = Varint.write(b, at, 3)
        at = ping.request.write(b, at, 6)
        local frame = buffer.create(at)
        buffer.copy(frame, 0, b, 0, at)
        Router.frame(rig.of, rig.alice, false, frame, nil, NOW)
        Expect.equal(answers, {
            { 40, rig.alice, true, "5:alice" },
            { 41, rig.alice, false, nil },
            { 44, rig.alice, true, "6:alice" },
        })

        local done = {}
        local one = rig.pending:open(NOW, "Ping", nil, nil, function(ok, result)
            table.insert(done, { "one", ok, result })
        end)
        local two = rig.pending:open(NOW, "Ping", nil, nil, function(ok, result)
            table.insert(done, { "two", ok, result })
        end)
        local reply = buffer.create(ROOM)
        ping.answers.write(reply, 0, { ping.id + 1, 1 })
        at = ping.answers.bytes
        ping.answering.write(reply, at, { one, 0 })
        at = ping.response.write(reply, at + ping.answering.bytes, "pong")
        at = Varint.writeFlagged(reply, at, two - one, 1)
        local answered = buffer.create(at)
        buffer.copy(answered, 0, reply, 0, at)
        Router.frame(rig.of, nil, false, answered, nil, NOW)
        Expect.equal(done, { { "one", true, "pong" }, { "two", false, "unanswered" } })
    end),

    -- A set block goes to the section or stream reader its lane names, and one this endpoint has
    -- no reader for is a drop.
    Harness.case("router.sets", function()
        local rig = rigged()
        local team = rig.space.byName.Team :: Compile.Set
        local took = {}
        rig.of.sections[team.id] = function(b: buffer, pos: number): (number, any)
            table.insert(took, "section")
            return buffer.len(b), nil
        end
        rig.of.streams[team.id] = function(b: buffer, pos: number): (number, any)
            table.insert(took, "stream")
            return buffer.len(b), nil
        end
        local b = buffer.create(team.head.bytes + 2)
        team.head.write(b, 0, { team.id, 0 })
        Router.frame(rig.of, nil, false, b, nil, NOW)
        Router.frame(rig.of, nil, true, b, nil, NOW)
        Expect.equal(took, { "section", "stream" })

        rig.of.streams[team.id] = nil
        local codes = drops(function()
            Router.frame(rig.of, nil, true, b, nil, NOW)
        end)
        Expect.equal(codes, { Catalog.DEFID })
    end),

    -- The instances riding beside a frame are paired with the blocks whose schema can name one,
    -- and the frame stops at a block too short for its header, an unknown id or a payload that
    -- cannot be read, with nothing after it reached.
    Harness.case("router.sidecar-and-losses", function()
        local rig = rigged()
        local who = rig.space.byName.Who :: Compile.Packet
        local seen = {}
        Dispatch.listen(rig.heard, who.id, function(value: any)
            table.insert(seen, value)
        end)
        local part = Instance.new("Folder")
        local b = buffer.create(ROOM)
        who.head.write(b, 0, { who.id, 0 })
        local side = who.built.sidecar
        table.clear(side.refs)
        table.clear(side.slotOf)
        local at = who.built.write(b, who.head.bytes, part)
        local frame = buffer.create(at)
        buffer.copy(frame, 0, b, 0, at)
        Router.frame(rig.of, nil, false, frame, { { part } }, NOW)
        Expect.equal(seen, { part })

        local hit = rig.space.byName.Hit :: Compile.Packet
        local heard = {}
        Dispatch.listen(rig.heard, hit.id, function(value: any)
            table.insert(heard, value)
        end)
        local short = buffer.create(1)
        hit.head.write(short, 0, { hit.id, 3 })
        Expect.equal(
            drops(function()
                Router.frame(rig.of, nil, false, short, nil, NOW)
            end),
            { Catalog.BOUNDS }
        )

        -- A block cut inside its own header, past the name, is refused by the header's bounds
        -- rather than read off the end of the frame.
        local shot = rig.space.byName.Shot :: Compile.Packet
        local inside = buffer.create(shot.head.bytes - 1)
        shot.head.write(b, 0, { shot.id, 0 })
        buffer.copy(inside, 0, b, 0, shot.head.bytes - 1)
        Expect.equal(
            drops(function()
                Router.frame(rig.of, nil, true, inside, nil, NOW)
            end),
            { Catalog.BOUNDS }
        )

        local unknown = buffer.create(1)
        buffer.writeu8(unknown, 0, 7)
        Expect.equal(
            drops(function()
                Router.frame(rig.of, nil, false, unknown, nil, NOW)
            end),
            { Catalog.DEFID }
        )

        -- An unknown id names itself and its namespace in the message, with no placeholder left
        -- standing, since a diagnostic that keeps its braces has told a reader nothing.
        local message = said(function()
            Router.frame(rig.of, nil, false, unknown, nil, NOW)
        end)[1]
        Expect.holds(string.find(message, "7", 1, true) ~= nil, `the id is missing: {message}`)
        Expect.holds(string.find(message, "{", 1, true) == nil, `a placeholder survived: {message}`)

        local bad = running(rig, "Hit", { 1, 2 })
        buffer.writeu8(bad, hit.head.bytes, 101)
        local good = running(rig, "Hit", { 3 })
        local both = buffer.create(buffer.len(bad) + buffer.len(good))
        buffer.copy(both, 0, bad)
        buffer.copy(both, buffer.len(bad), good)
        Expect.equal(
            drops(function()
                Router.frame(rig.of, rig.alice, false, both, nil, NOW)
            end),
            { Catalog.TAG }
        )
        Expect.equal(heard, {})
        Expect.equal(rig.of.boundary.live, false)
    end),
}
