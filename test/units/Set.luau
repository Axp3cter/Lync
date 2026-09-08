--!strict
--!optimize 2
-- The set handle from both machines over the wire double, and the root binding every name is
-- reached through.

local Codecs = require("@src/codec")
local Define = require("@src/api/Define")
local Lync = require("@src")
local Recipients = require("@src/channel/Recipients")
local Session = require("@src/runtime/Session")
local Set = require("@src/api/Set")

local Doubles = require("@fixtures/Doubles")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")

type Rig = {
    mine: any,
    theirs: any,
    server: Session.Session,
    client: Session.Session,
    wire: Doubles.Wire,
    alice: Player,
}

local function declared(key: string?): any
    local of = Codecs.struct({
        team = Codecs.int(0, 3),
        hp = Codecs.int(0, 100),
        name = Codecs.optional(Codecs.str(0, 8)),
    })
    local set = Set.new(of)
    if key ~= nil then set = set:keyBy(key) end
    return { Team = set }
end

local function rigged(space: string, key: string?): Rig
    local roster = Doubles.roster()
    local wire = Doubles.wire()
    local alice = roster:join("alice")
    local mine = Define.define(space, declared(key))
    local theirs = declared(key)
    local server = Session.new(space, mine, wire:server(), roster, "server")
    local client = Session.new(space, theirs, wire:client(alice), roster, "client")
    server:start()
    client:start()
    wire:settle()
    return {
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
    -- Before start a set describes itself, reads as empty, walks nothing, and refuses every
    -- mutation. Once started, mutation is the server's and a client's view refuses it.
    Harness.case("set.declares", function()
        local set: any = Set.new(Codecs.struct({ hp = Codecs.int(0, 9) }))
        Expect.equal(set:describe(), 'set[](struct(){"hp"=int(0,9);})')
        Expect.equal(#set, 0)
        Expect.equal(set:get(1), nil)
        for _ in set do
            Expect.holds(false, "a set before start walked something")
        end
        Expect.throws(function()
            set:add(1, { hp = 1 })
        end, "add before it was named")
        Expect.equal(set:keyBy("hp"):describe(), 'set["hp"](struct(){"hp"=int(0,9);})')

        local rig = rigged("SetDeclares")
        Expect.throws(function()
            rig.mine.Team:keyBy("team")
        end, "after SetDeclares started")
        Expect.throws(function()
            rig.theirs.Team:add(1, { team = 1, hp = 1 })
        end, "add is the server's call, and this is a client")
        Expect.throws(function()
            rig.mine.Team:audience(1, Recipients.ALL)
        end, "goes to everybody")
    end),

    -- Records added, updated, cleared of a field and removed on the server arrive at the client,
    -- whose view counts, walks and reads them, and whose callbacks are told once each.
    Harness.case("set.replicates", function()
        local rig = rigged("SetReplicates")
        local mine, theirs = rig.mine.Team, rig.theirs.Team
        local told: { any } = {}
        theirs:onAdded(function(id: number, record: any)
            table.insert(told, { "added", id, record.hp })
        end)
        theirs:onChanged(function(id: number, record: any, old: any)
            table.insert(told, { "changed", id, record.hp, old.hp })
        end)
        theirs:onRemoved(function(id: number, why: string)
            table.insert(told, { "removed", id, why })
        end)

        mine:add(1, { team = 1, hp = 50, name = "one" })
        mine:add(2, { team = 2, hp = 60 })
        pumped(rig)
        Expect.equal(#theirs, 2)
        Expect.equal(theirs:get(1), { team = 1, hp = 50, name = "one" })
        local walked = {}
        for id, record in theirs do
            walked[id] = record.hp
        end
        Expect.equal(walked, { 50, 60 })
        local called = {}
        for id, record in theirs:entries() do
            called[id] = record.hp
        end
        Expect.equal(called, walked)
        Expect.equal(theirs:size(), 2)

        mine:update(1, { hp = 55, name = Lync.none })
        pumped(rig)
        Expect.equal(theirs:get(1), { team = 1, hp = 55 })
        mine:remove(2)
        pumped(rig)
        Expect.equal(theirs:get(2), nil)
        mine:clear()
        pumped(rig)
        Expect.equal(#theirs, 0)
        Expect.equal(told, {
            { "added", 1, 50 },
            { "added", 2, 60 },
            { "changed", 1, 55, 50 },
            { "removed", 2, "removed" },
            { "removed", 1, "cleared" },
        })
    end),

    -- A keyed set assigns an audience per key, and a client outside it never holds the record.
    Harness.case("set.audiences", function()
        local rig = rigged("SetAudiences", "team")
        local mine, theirs = rig.mine.Team, rig.theirs.Team
        mine:add(1, { team = 1, hp = 1 })
        mine:add(2, { team = 2, hp = 2 })
        mine:audience(2, Recipients.except(rig.alice))
        pumped(rig)
        Expect.equal(theirs:get(1).hp, 1)
        Expect.equal(theirs:get(2), nil)
        mine:audience(2, Recipients.ALL)
        pumped(rig)
        pumped(rig)
        Expect.equal(theirs:get(2).hp, 2)
    end),

    -- The root binding offers every name, frozen, and nothing the old surface dropped.
    Harness.case("lync.binding", function()
        Expect.equal(table.isfrozen(Lync :: any), true)
        for _, name in
            {
                "define",
                "start",
                "flush",
                "close",
                "packet",
                "query",
                "replicate",
                "group",
                "all",
                "except",
                "none",
                "onLog",
                "console",
                "empty",
                "bool",
                "int",
                "quant",
                "angle",
                "f32",
                "f64",
                "vlq",
                "vli",
                "str",
                "buffer",
                "struct",
                "array",
                "map",
                "optional",
                "tagged",
                "enum",
                "bitfield",
                "vec2",
                "vec3",
                "cframe",
                "rotation",
                "color3",
                "inst",
            }
        do
            Expect.holds((Lync :: any)[name] ~= nil, `the binding offers no {name}`)
        end
        Expect.equal((Lync :: any).stats, nil)
        Expect.equal((Lync :: any).unknown, nil)
        Expect.equal(Lync.none, Set.NONE)
        Expect.equal(Lync.all, Recipients.ALL)
    end),
}
