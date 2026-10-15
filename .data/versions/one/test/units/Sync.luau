--!strict
--!optimize 2
-- One set coordinated between two machines: what a caller does to it, what a flush turns that
-- into on the wire, and what the other side holds and is told afterwards.

local Codecs = require("@src/codec")
local Compile = require("@src/shape/Compile")
local Link = require("@src/channel/Link")
local Outbox = require("@src/channel/Outbox")
local Plan = require("@src/state/Plan")
local Recipients = require("@src/channel/Recipients")
local Sync = require("@src/state/Sync")
local Types = require("@src/Types")

local Doubles = require("@fixtures/Doubles")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")

local ROOM = 4096
local CTX: Types.ValidateContext = table.freeze({ player = nil, now = 0, last = nil })
local AT = table.freeze({ file = "Game.Net", line = 1 })

type Rig = {
    server: Sync.Sync,
    client: Sync.Sync,
    link: Link.Link,
    wire: Doubles.Wire,
    ready: Recipients.Ready,
    alice: Player,
    bob: Player,
    now: number,
}

local function compiled(key: string?): any
    local fields = {
        team = Codecs.int(0, 3),
        hp = Codecs.int(0, 100000),
        name = Codecs.optional(Codecs.str(0, 8)),
        pos = Codecs.vec3():newest(),
    }
    local set = { kind = "set", of = Codecs.struct(fields), keyField = key, at = AT }
    return Compile.build("sync", { roster = set :: any }).byName.roster
end

-- A server set flushing to alice's client set over the wire double, bob ready but silent.
local function rigged(key: string?): Rig
    local def = compiled(key)
    local roster = Doubles.roster()
    local alice, bob = roster:join("alice"), roster:join("bob")
    local wire = Doubles.wire()
    local link = Link.new("sync", "server", ROOM, wire:server())
    Link.open(link)
    Link.admit(link, alice)
    Link.admit(link, bob)
    local rig: Rig = {
        server = Sync.new(def),
        client = Sync.new(def),
        link = link,
        wire = wire,
        ready = link.ready,
        alice = alice,
        bob = bob,
        now = 0,
    }
    local receiver = wire:client(alice)
    receiver:open()
    receiver:onReceive("reliable", function(_from: Player?, b: buffer)
        local pos = 0
        while pos < buffer.len(b) do
            pos = Sync.taken(rig.client, b, pos, CTX)
        end
        Sync.settle(rig.client)
    end)
    receiver:onReceive("unreliable", function(_from: Player?, b: buffer)
        local pos = 0
        while pos < buffer.len(b) do
            pos = Sync.stream(rig.client, b, pos, CTX)
        end
        Sync.settle(rig.client)
    end)
    return rig
end

-- One flush of the server set, carried to alice.
local function flushed(rig: Rig)
    rig.now += 1
    Sync.resolved(rig.server, rig.link, rig.ready)
    Sync.shared(rig.server, rig.link, Plan.budget(ROOM), nil, rig.ready, rig.now)
    Sync.settle(rig.server)
    Outbox.fire(rig.link)
    rig.wire:deliver()
end

local function rows(of: Sync.Sync): { [number]: any }
    local out = {}
    for id, row in Sync.walk(of) do
        out[id] = table.clone(row)
    end
    return out
end

return {
    -- What a caller does to a set: ids it cannot hold, records it already holds or does not,
    -- fields it has not got, clearing an optional field and only that, and a write of what a
    -- field already holds owing nothing.
    Harness.case("sync.calls", function()
        local of = Sync.new(compiled())
        Sync.add(of, 1, { team = 1, hp = 50, name = "one", pos = Vector3.zero })
        Expect.equal(Sync.size(of), 1)
        Expect.equal(Sync.get(of, 1), { team = 1, hp = 50, name = "one", pos = Vector3.zero })
        Expect.equal(Sync.get(of, 2), nil)
        Expect.throws(function()
            Sync.add(of, 1, { team = 1, hp = 1, pos = Vector3.zero })
        end, "already holds record 1")
        Expect.throws(function()
            Sync.add(of, 1.5, { team = 1, hp = 1, pos = Vector3.zero })
        end, "cannot hold record 1.5")
        Expect.throws(function()
            Sync.update(of, 2, { hp = 1 })
        end, "does not hold record 2")
        Expect.throws(function()
            Sync.update(of, 1, { mana = 1 })
        end, "no field named mana")
        Expect.throws(function()
            Sync.update(of, 1, { hp = Sync.NONE })
        end, "not optional")

        local part = of.parts[next(of.parts) :: any]
        Expect.equal(part.dirt.ops[1], "add")
        Sync.update(of, 1, { hp = 50, name = "one" })
        Expect.equal(part.dirt.masks[1], nil)
        Sync.update(of, 1, { name = Sync.NONE, hp = 51 })
        Expect.equal(Sync.get(of, 1).name, nil)
        Expect.equal(Sync.get(of, 1).hp, 51)
        Expect.equal(part.dirt.ops[1], "add")

        Sync.remove(of, 1)
        Expect.equal(Sync.size(of), 0)
        Expect.equal(part.dirt.ops[1], nil)
        Expect.throws(function()
            Sync.remove(of, 1)
        end, "does not hold record 1")
        Expect.equal(tostring(Sync.NONE), "Lync.none")
    end),

    -- A keyed set partitions by the key, moves a record whose key changes, and walks every
    -- partition once each.
    Harness.case("sync.partitions", function()
        local of = Sync.new(compiled("team"))
        Sync.add(of, 1, { team = 1, hp = 1, pos = Vector3.zero })
        Sync.add(of, 2, { team = 2, hp = 2, pos = Vector3.zero })
        Sync.add(of, 3, { team = 1, hp = 3, pos = Vector3.zero })
        Expect.equal(#of.order, 2)
        Expect.equal(of.parts[1].store.count, 2)
        Expect.equal(of.partOf[2], 2)

        Sync.update(of, 3, { team = 2 })
        Expect.equal(of.partOf[3], 2)
        Expect.equal(of.parts[1].store.count, 1)
        Expect.equal(of.parts[2].store.count, 2)
        Expect.equal(of.parts[2].dirt.ops[3], "add")
        Expect.equal(Sync.size(of), 3)
        local seen = {}
        for id in Sync.walk(of) do
            seen[id] = true
        end
        Expect.equal(seen, { true, true, true })

        Sync.clear(of)
        Expect.equal(Sync.size(of), 0)
        Expect.equal(of.parts[1].dirt.cleared, true)
    end),

    -- A flush carries adds as keyframes, updates as deltas, removals and clears, and the client
    -- holds the same records and is told each thing once.
    Harness.case("sync.round-trip", function()
        local rig = rigged()
        local told: { added: { any }, changed: { any }, removed: { any } } =
            { added = {}, changed = {}, removed = {} }
        Sync.onAdded(rig.client, function(id: number, row: any)
            table.insert(told.added, { id, table.clone(row) })
        end)
        Sync.onChanged(rig.client, function(id: number, row: any, was: any)
            table.insert(told.changed, { id, row.hp, if was == nil then nil else was.hp })
        end)
        Sync.onRemoved(rig.client, function(id: number, why: Types.Cause)
            table.insert(told.removed, { id, why })
        end)

        Sync.add(rig.server, 1, { team = 1, hp = 500, name = "one", pos = Vector3.new(1, 0, 0) })
        Sync.add(rig.server, 2, { team = 2, hp = 600, pos = Vector3.new(2, 0, 0) })
        flushed(rig)
        Expect.equal(rows(rig.client), rows(rig.server))
        Expect.equal(#told.added, 2)
        Expect.equal(told.added[1][2].name, "one")

        Sync.update(rig.server, 1, { hp = 510 })
        Sync.update(rig.server, 2, { name = "two" })
        flushed(rig)
        Expect.equal(rows(rig.client), rows(rig.server))
        Expect.equal(told.changed, { { 1, 510, 500 }, { 2, 600, 600 } })

        Sync.update(rig.server, 1, { pos = Vector3.new(9, 0, 0) })
        flushed(rig)
        Expect.equal(Sync.get(rig.client, 1).pos, Vector3.new(9, 0, 0))
        Expect.equal(rig.wire:moved().frames, 3)

        Sync.remove(rig.server, 2)
        flushed(rig)
        Expect.equal(Sync.get(rig.client, 2), nil)
        Expect.equal(told.removed, { { 2, "removed" } })

        Sync.clear(rig.server)
        flushed(rig)
        Expect.equal(Sync.size(rig.client), 0)
        Expect.equal(told.removed[2], { 1, "cleared" })

        -- A flush with nothing to say fires nothing.
        local before = rig.wire:moved().frames
        flushed(rig)
        Expect.equal(rig.wire:moved().frames, before)
    end),

    -- A partition assigned an audience goes to its members alone, a member losing it is told
    -- its records are gone, and a client owed a partition is paid its backlog in chunks.
    Harness.case("sync.audience-and-catchup", function()
        local rig = rigged("team")
        Sync.add(rig.server, 1, { team = 1, hp = 1, pos = Vector3.zero })
        Sync.add(rig.server, 2, { team = 2, hp = 2, pos = Vector3.zero })
        Sync.audience(rig.server, 1, Recipients.ALL)
        Sync.audience(rig.server, 2, rig.bob)
        flushed(rig)
        Expect.equal(Sync.get(rig.client, 1) ~= nil, true)
        Expect.equal(Sync.get(rig.client, 2), nil)

        Sync.audience(rig.server, 2, Recipients.ALL)
        flushed(rig)
        Expect.equal(Sync.owing(rig.server), true)
        Expect.holds(
            Sync.behind(rig.server, rig.link, rig.alice, ROOM) > 0,
            "alice was owed nothing"
        )
        Outbox.fire(rig.link)
        rig.wire:deliver()
        Expect.equal(Sync.get(rig.client, 2).hp, 2)
        Expect.equal(Sync.owing(rig.server), false)

        Sync.audience(rig.server, 2, rig.bob)
        flushed(rig)
        Expect.equal(Sync.get(rig.client, 2), nil)
        Expect.equal(Sync.get(rig.client, 1).hp, 1)

        Sync.joined(rig.server, rig.alice)
        Expect.equal(Sync.owing(rig.server), true)
        Sync.left(rig.server, rig.alice)
        Expect.equal(Sync.owing(rig.server), false)
    end),
}
