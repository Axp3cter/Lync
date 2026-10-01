--!strict
--!optimize 2
-- The set handle from both machines over the wire double, and the root binding every name is
-- reached through.

local Codecs = require("@src/codec")
local Define = require("@src/api/Define")
local Group = require("@src/channel/Group")
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

type Crowd = {
    mine: any,
    server: Session.Session,
    roster: Doubles.Roster,
    views: { [string]: any },
    join: (label: string, before: ((Player) -> ())?) -> Player,
    flush: (budget: number) -> (),
}

-- A started server, and clients that join whenever a case says, each declaring `make()` afresh.
local function crowded(space: string, make: () -> any): Crowd
    local roster = Doubles.roster()
    local wire = Doubles.wire()
    local mine = Define.define(space, make())
    local server = Session.new(space, mine, wire:server(), roster, "server")
    server:start()
    local clients: { Session.Session } = {}
    local views: { [string]: any } = {}
    local function join(label: string, before: ((Player) -> ())?): Player
        local view = make()
        local who = roster:join(label)
        if before ~= nil then before(who) end
        local client = Session.new(space, view, wire:client(who), roster, "client")
        client:start()
        table.insert(clients, client)
        views[label] = view
        wire:settle()
        return who
    end
    local function flush(budget: number)
        server:flush(budget)
        for _, client in clients do
            client:flush(budget)
        end
        wire:settle()
    end
    return {
        mine = mine,
        server = server,
        roster = roster,
        views = views,
        join = join,
        flush = flush,
    }
end

local TEAMED = Codecs.struct({ team = Codecs.int(0, 3), hp = Codecs.int(0, 100) })

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

    -- A keyed set assigns an audience per key, a client outside it never holds the record, and a
    -- key nobody assigned goes to nobody until it is.
    Harness.case("set.audiences", function()
        local rig = rigged("SetAudiences", "team")
        local mine, theirs = rig.mine.Team, rig.theirs.Team
        mine:add(1, { team = 1, hp = 1 })
        mine:add(2, { team = 2, hp = 2 })
        mine:audience(2, Recipients.except(rig.alice))
        pumped(rig)
        Expect.equal(theirs:get(1), nil)
        Expect.equal(theirs:get(2), nil)
        mine:audience(1, Recipients.ALL)
        pumped(rig)
        pumped(rig)
        Expect.equal(theirs:get(1).hp, 1)
        mine:audience(2, Recipients.ALL)
        pumped(rig)
        pumped(rig)
        Expect.equal(theirs:get(2).hp, 2)
    end),

    -- A table the caller changes and hands back is a change, and the store never aliases it.
    Harness.case("set.mutated-table", function()
        local roster = Doubles.roster()
        local wire = Doubles.wire()
        local alice = roster:join("alice")
        local function mapped(): any
            local of = Codecs.struct({
                mods = Codecs.map(Codecs.enum({ "a", "b" }), Codecs.int(0, 100), 1, 2),
            })
            return { Mods = Set.new(of) }
        end
        local mine, theirs = Define.define("SetMutated", mapped()), mapped()
        local server = Session.new("SetMutated", mine, wire:server(), roster, "server")
        local client = Session.new("SetMutated", theirs, wire:client(alice), roster, "client")
        server:start()
        client:start()
        wire:settle()

        local mods = { a = 5 }
        mine.Mods:add(1, { mods = mods })
        server:flush(4096)
        wire:settle()
        mods.a = 81
        Expect.equal(mine.Mods:get(1).mods.a, 5)
        mine.Mods:update(1, { mods = mods })
        server:flush(4096)
        wire:settle()
        Expect.equal(theirs.Mods:get(1).mods.a, 81)
    end),

    -- A client that starts after a record wider than a section was added still catches up on it,
    -- at the floor budget.
    Harness.case("set.wide-catchup", function()
        local roster = Doubles.roster()
        local wire = Doubles.wire()
        local alice = roster:join("alice")
        local function wide(): any
            local of = Codecs.struct({
                mods = Codecs.map(Codecs.str(1, 50), Codecs.int(0, 100), 1, 100),
            })
            return { Mods = Set.new(of) }
        end
        local mine, theirs = Define.define("SetWide", wide()), wide()
        local server = Session.new("SetWide", mine, wire:server(), roster, "server")
        local client = Session.new("SetWide", theirs, wire:client(alice), roster, "client")
        server:start()
        mine.Mods:add(1, { mods = { first = 1 } })
        server:flush(1024)
        wire:settle()

        client:start()
        for _ = 1, 3 do
            server:flush(1024)
            client:flush(1024)
            wire:settle()
        end
        Expect.equal(theirs.Mods:get(1).mods.first, 1)
    end),

    -- A set keyed by a vlq or a string splits per key like any other, and a record whose key
    -- changes moves out of one audience and into the next.
    Harness.case("set.loose-keys", function()
        local cases: { { any } } = {
            { Codecs.vlq(), 9000000001, 9000000002 },
            { Codecs.str(1, 16), "alice", "bob" },
        }
        for index, case in cases do
            local keyed, a, b = case[1], case[2], case[3]
            local roster = Doubles.roster()
            local wire = Doubles.wire()
            local alice, bob = roster:join("alice"), roster:join("bob")
            local function owned(): any
                local of = Codecs.struct({ owner = keyed, hp = Codecs.int(0, 100) })
                return { Owned = Set.new(of):keyBy("owner") }
            end
            local space = `SetLoose{index}`
            local mine = Define.define(space, owned())
            local server = Session.new(space, mine, wire:server(), roster, "server")
            local views = { [alice] = owned(), [bob] = owned() }
            local clients = {}
            for who, view in views do
                clients[who] = Session.new(space, view, wire:client(who), roster, "client")
            end
            server:start()
            for _, client in clients do
                client:start()
            end
            wire:settle()

            mine.Owned:audience(a, alice)
            mine.Owned:audience(b, bob)
            mine.Owned:add(1, { owner = a, hp = 10 })
            server:flush(4096)
            wire:settle()
            Expect.equal(views[alice].Owned:get(1).hp, 10)
            Expect.equal(views[bob].Owned:get(1), nil)

            mine.Owned:update(1, { owner = b })
            server:flush(4096)
            wire:settle()
            Expect.equal(views[alice].Owned:get(1), nil)
            Expect.equal(views[bob].Owned:get(1).hp, 10)
        end
    end),

    -- A section the budget refuses holds back the rest of the flush, so a record moved to a new
    -- key or replaced under its id is never removed after it arrived again.
    Harness.case("set.refusal-holds-order", function()
        for _, budget in { 1024, 1050, 1080, 1110 } do
            local crowd = crowded(`SetRefusal{budget}`, function(): any
                return { Bulk = Set.new(TEAMED), Keyed = Set.new(TEAMED):keyBy("team") }
            end)
            crowd.join("alice")
            local bulk, keyed = crowd.mine.Bulk, crowd.mine.Keyed
            for team = 1, 2 do
                keyed:audience(team, Recipients.ALL)
            end
            for id = 1, 400 do
                keyed:add(id, { team = 1, hp = 1 })
            end
            crowd.flush(100000)

            for id = 1, 2000 do
                bulk:add(id, { team = 0, hp = 1 })
            end
            for id = 1, 298, 3 do
                keyed:remove(id)
            end
            keyed:update(400, { team = 2 })
            keyed:remove(399)
            keyed:add(399, { team = 1, hp = 2 })
            crowd.flush(budget)
            for _ = 1, 10 do
                crowd.flush(100000)
            end
            local view = crowd.views.alice.Keyed
            Expect.equal(view:get(400).team, 2)
            Expect.equal(view:get(399).hp, 2)
            Expect.equal(#view, #keyed)
        end
    end),

    -- A client catching up while the shared stream is behind gets each change once, and a record
    -- whose add has not gone out yet is not sent ahead of it, so a later removal reaches them.
    Harness.case("set.catchup-waits-for-stream", function()
        local doubled = crowded("SetCatchupOnce", function(): any
            return { Plain = Set.new(Codecs.struct({ hp = Codecs.int(0, 10000) })) }
        end)
        local plain = doubled.mine.Plain
        doubled.join("alice")
        plain:add(1, { hp = 100 })
        doubled.flush(100000)
        doubled.join("bob")
        plain:update(1, { hp = 200 })
        for id = 2, 1000 do
            plain:add(id, { hp = 1 })
        end
        for _ = 1, 40 do
            doubled.flush(1024)
        end
        Expect.equal(doubled.views.bob.Plain:get(1).hp, 200)

        for _, budget in { 1024, 1051, 1080 } do
            local ghost = crowded(`SetCatchupGhost{budget}`, function(): any
                return { Keyed = Set.new(TEAMED):keyBy("team") }
            end)
            local keyed = ghost.mine.Keyed
            keyed:audience(0, Recipients.ALL)
            keyed:audience(1, Recipients.ALL)
            ghost.join("alice")
            keyed:add(1, { team = 1, hp = 1 })
            ghost.join("bob")
            for id = 2, 2000 do
                keyed:add(id, { team = 0, hp = 1 })
            end
            ghost.flush(budget)
            keyed:remove(1)
            for _ = 1, 30 do
                ghost.flush(100000)
            end
            Expect.equal(ghost.views.bob.Keyed:get(1), nil)
            Expect.equal(#ghost.views.bob.Keyed, #keyed)
        end
    end),

    -- A client that joins while in a narrowed audience and is taken out of it before the next
    -- flush is never sent what that audience sees.
    Harness.case("set.join-then-narrowed", function()
        local crowd = crowded("SetJoinNarrowed", function(): any
            return { Keyed = Set.new(TEAMED):keyBy("team") }
        end)
        local keyed = crowd.mine.Keyed
        local squad = Group.new()
        keyed:audience(1, squad)
        squad:add(crowd.join("alice"))
        keyed:add(1, { team = 1, hp = 1 })
        crowd.flush(4096)
        Expect.equal(crowd.views.alice.Keyed:get(1).hp, 1)

        local carol = crowd.join("carol", function(who: Player)
            squad:add(who)
        end)
        squad:remove(carol)
        crowd.flush(4096)
        crowd.flush(4096)
        Expect.equal(crowd.views.carol.Keyed:get(1), nil)
    end),

    -- A key narrowed to a player before their handshake finishes still reaches them, whatever was
    -- flushed while nobody was there to see it.
    Harness.case("set.narrowed-before-join", function()
        local crowd = crowded("SetNarrowedEarly", function(): any
            return { Keyed = Set.new(TEAMED):keyBy("team") }
        end)
        local keyed = crowd.mine.Keyed
        keyed:add(1, { team = 1, hp = 7 })
        crowd.flush(4096)
        crowd.join("alice", function(who: Player)
            keyed:audience(1, { who })
        end)
        crowd.flush(4096)
        Expect.equal(crowd.views.alice.Keyed:get(1).hp, 7)
    end),

    -- A partition kept for one player is let go once they have left and it holds nothing, so a
    -- long server does not walk every player it ever had.
    Harness.case("set.departed-partition-forgotten", function()
        local crowd = crowded("SetDeparted", function(): any
            local of = Codecs.struct({ owner = Codecs.vlq(), hp = Codecs.int(0, 100) })
            return { Owned = Set.new(of):keyBy("owner") }
        end)
        local owned = crowd.mine.Owned
        local alice = crowd.join("alice")
        owned:audience(7, alice)
        owned:add(1, { owner = 7, hp = 1 })
        crowd.flush(4096)
        local sync = crowd.server:set(crowd.server.space.byName.Owned.id)
        Expect.equal(#sync.order, 1)

        owned:remove(1)
        crowd.roster:leave(alice)
        crowd.flush(4096)
        crowd.flush(4096)
        Expect.equal(#sync.order, 0)
        Expect.equal(sync.seen.of[7], nil)
    end),

    -- A client that joins while a key is open and loses it before the next flush is never sent
    -- what it held.
    Harness.case("set.join-open-then-narrowed", function()
        local crowd = crowded("SetJoinOpen", function(): any
            return { Keyed = Set.new(TEAMED):keyBy("team") }
        end)
        local keyed = crowd.mine.Keyed
        keyed:add(1, { team = 1, hp = 1 })
        crowd.flush(4096)
        keyed:audience(1, Recipients.ALL)
        crowd.join("alice")
        keyed:audience(1, {})
        for _ = 1, 4 do
            crowd.flush(4096)
        end
        Expect.equal(crowd.views.alice.Keyed:get(1), nil)
    end),

    -- An audience for a key the key field cannot write is refused where it is given.
    Harness.case("set.audience-key-checked", function()
        local crowd = crowded("SetAudienceKey", function(): any
            return { Keyed = Set.new(TEAMED):keyBy("team") }
        end)
        Expect.throws(function()
            crowd.mine.Keyed:audience(9, Recipients.ALL)
        end, "Keyed.team cannot hold 9")
        crowd.mine.Keyed:clear()
        crowd.flush(4096)
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
                "encode",
                "decode",
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
