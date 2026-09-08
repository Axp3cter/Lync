--!strict
--!optimize 2
-- A namespace compiled: the ids handed out, the records each definition became, the descriptor.

local Codecs = require("@src/codec")
local Compile = require("@src/shape/Compile")
local Wide = require("@src/kernel/Wide")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")

local AT = table.freeze({ file = "Game.Shared.Net", line = 12 })

local function firing(of: any, unreliable: boolean?, newest: boolean?, stamped: boolean?): any
    return {
        kind = "packet" :: "packet",
        of = of,
        isUnreliable = unreliable == true,
        isNewest = newest == true,
        hz = if newest then 20 else nil,
        isTimestamped = stamped == true,
        at = AT,
    }
end

local function asking(of: any, reply: any): any
    return { kind = "query" :: "query", of = of, reply = reply, at = AT }
end

local function replicating(of: any, key: string?): any
    return { kind = "set" :: "set", of = of, keyField = key, at = AT }
end

local RECORD = Codecs.struct({
    hp = Codecs.int(0, 100),
    pos = Codecs.vec3():newest(),
    name = Codecs.optional(Codecs.str(0, 8)),
    slot = Codecs.int(0, 15),
})

local SPECS = {
    Jump = firing(Codecs.empty()),
    Look = firing(Codecs.vec3(), false, true),
    Ping = asking(Codecs.int(0, 255), Codecs.f64()),
    Players = replicating(RECORD, "slot"),
    Shots = firing(Codecs.array(Codecs.vec3(), 0, 8), true, false, true),
}

return {
    -- Ids go out in name order, a query taking two, and every id finds its definition.
    Harness.case("compile.ids", function()
        local of = Compile.build("Arena", SPECS)
        Expect.equal(of.space, "Arena")
        Expect.equal(of.count, 6)
        Expect.equal(#of.list, 5)
        local ids = {}
        for _, def in of.list do
            ids[def.name] = def.id
        end
        Expect.equal(ids, { Jump = 0, Look = 1, Ping = 2, Players = 4, Shots = 5 })
        Expect.equal(of.byId[2], of.byName.Ping)
        Expect.equal(of.byId[3], of.byName.Ping)
        Expect.equal(of.byId[4].kind, "set")
        Expect.equal(of.byId[6], nil)
        Expect.equal(table.isfrozen(of :: any), true)
    end),

    -- A packet's lane picks its head, and its block is the head and the payload.
    Harness.case("compile.packets", function()
        local of = Compile.build("Arena", SPECS)
        local jump = of.byName.Jump :: Compile.Packet
        Expect.equal(jump.delivery, "reliable")
        Expect.equal(jump.maxBytes, 0)
        Expect.equal(jump.blockBytes, jump.head.bytes)
        Expect.holds(jump.head.runs ~= nil, "a reliable packet's head does not run")
        Expect.equal(jump.file, AT.file)
        Expect.equal(jump.line, AT.line)

        local look = of.byName.Look :: Compile.Packet
        Expect.equal(look.delivery, "newest")
        Expect.equal(look.hz, 20)
        Expect.equal(look.head.runs, nil)
        Expect.equal(look.timestamped, false)

        local shots = of.byName.Shots :: Compile.Packet
        Expect.equal(shots.delivery, "unreliable")
        Expect.equal(shots.timestamped, true)
        Expect.equal(shots.head.fields, 2)
        Expect.equal(shots.blockBytes, shots.head.bytes + shots.built.maxBytes)
    end),

    -- A query is two builds under two names, costing the wider block.
    Harness.case("compile.queries", function()
        local of = Compile.build("Arena", SPECS)
        local ping = of.byName.Ping :: Compile.Query
        Expect.equal(ping.request.maxBytes, 1)
        Expect.equal(ping.response.maxBytes, 8)
        Expect.equal(ping.maxBytes, 8)
        Expect.equal(ping.blockBytes, ping.answers.bytes + 8)
        Expect.equal(ping.request.paths.texts[ping.request.tag.pathId], "Ping.request")
        Expect.equal(ping.response.paths.texts[ping.response.tag.pathId], "Ping.response")
        Expect.equal(ping.asking.fields, 1)
        Expect.equal(ping.answering.fields, 2)
    end),

    -- A set is its fields in name order, built against one site, with the marks beside them.
    Harness.case("compile.sets", function()
        local of = Compile.build("Arena", SPECS)
        local players = of.byName.Players :: Compile.Set
        Expect.equal(players.fieldNames, { "hp", "name", "pos", "slot" })
        Expect.equal(players.fieldIndex, { hp = 1, name = 2, pos = 3, slot = 4 })
        Expect.equal(players.fieldCount, 4)
        Expect.equal(players.keyField, "slot")
        Expect.equal(players.keyIndex, 4)
        Expect.equal(players.newestFields, { 3 })
        Expect.equal(players.optionalFields, { false, true, false, false })
        Expect.equal(players.template, { hp = false, name = false, pos = false, slot = false })
        Expect.equal(players.fieldBuilt[1].paths, players.site.paths)
        Expect.equal(players.fieldBuilt[3].paths, players.site.paths)
        Expect.equal(players.fieldBuilt[3].marker, "newest")
        local bytes = 0
        for _, built in players.fieldBuilt do
            bytes += built.maxBytes
        end
        Expect.equal(players.maxBytes, bytes)
        Expect.equal(players.stream.fields, 4)
        Expect.equal(players.follow.fields, 2)
    end),

    -- The descriptor leads with the namespace and names every definition, and the hash is over it.
    Harness.case("compile.descriptor", function()
        local of = Compile.build("Arena", SPECS)
        local lead = "Arena;"
        Expect.equal(string.sub(of.descriptor, 1, #lead), lead)
        for name in SPECS do
            Expect.holds(
                string.find(of.descriptor, `;{name}=`, 1, true) ~= nil,
                `the descriptor left out {name}`
            )
        end
        Expect.holds(Wide.eq(of.hash, Compile.build("Arena", SPECS).hash), "one schema, two hashes")
        local other = Compile.build("Arena", { Jump = firing(Codecs.empty(), true) })
        Expect.holds(not Wide.eq(of.hash, other.hash), "two schemas, one hash")
    end),

    -- A namespace or a definition with something wrong is refused before any id goes out.
    Harness.case("compile.refuses", function()
        Expect.throws(function()
            Compile.build("a;b", SPECS)
        end, "the namespace a;b")
        Expect.throws(function()
            Compile.build("Arena", { Bad = firing(Codecs.int(0, 5), true, true) })
        end, "Bad declares two ways")
        Expect.throws(function()
            Compile.build("Arena", { Bad = replicating(Codecs.int(0, 5)) })
        end, `declared at {AT.file}:{AT.line}`)
    end),
}
