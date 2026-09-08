--!strict
--!optimize 2
-- What the library refuses: the schemas it will not compile, and the calls it will not take.

local Codecs = require("@src/codec")
local Compile = require("@src/shape/Compile")
local Define = require("@src/api/Define")
local Packet = require("@src/api/Packet")
local Protocol = require("@src/wire/Protocol")
local Query = require("@src/api/Query")
local Recipients = require("@src/channel/Recipients")
local Session = require("@src/runtime/Session")
local Set = require("@src/api/Set")

local Doubles = require("@fixtures/Doubles")

local Expect = require("@test/harness/Expect")
local Generate = require("@test/harness/Generate")
local Harness = require("@test/harness")
local Rng = require("@test/harness/Rng")

-- The namespace the early calls fire at, which is declared and never started, and the one a
-- session opens so a responder can be refused after the seal.
local NAMESPACE = "totality"
local OPENED = "totalityOpen"

-- The namespace a compiled definition is built under, which never reaches a transport.
local APART = "apart"

-- Fields a set may declare, and one past it.
local FIELDS = Protocol.MAX_FIELDS

-- A payload wider than a lossy frame carries, which is what the cap rule rejects.
local OVERSIZE = Protocol.UNRELIABLE_CAP + 1

-- Modifiers a chain applies, in the order a caller would write them.
local CHAIN = table.freeze({ "validate", "as", "newest" })

-- Two namespace names holding a mark a descriptor puts between its own names, both marks.
local MARKED = table.freeze({ "space;beside", "space=frame" })

-- A namespace of nothing, which is as much schema as a name is refused without.
local NOTHING: any = table.freeze({})

-- One legality rule a definition can break, named by what a person did rather than by what the
-- compiler noticed, with the shortest schema that breaks it and nothing else.
type Rule = { read name: string, read about: string, read build: () -> any }

-- Private -------------------------------------------------------------

local function flag(): any
    return Codecs.bool()
end

local function small(): any
    return Codecs.int(0, 9)
end

-- A record of that many boolean fields, which is how a field count is drawn past its bound.
local function record(fields: number): any
    local of = {}
    for index = 1, fields do
        of[`f{index}`] = flag()
    end
    return Codecs.struct(of)
end

-- A set keyed by `team`, whatever codec the key carries.
local function keyedBy(team: any): any
    return Set.new(Codecs.struct({ team = team, hp = small() })):keyBy("team")
end

local function rule(name: string, about: string, build: () -> any): Rule
    return table.freeze({ name = name, about = about, build = build })
end

-- Compiling one definition on its own, under the rule's name, so a throw names the rule.
local function compiled(name: string, spec: any): (boolean, string)
    local ok, thrown = pcall(Compile.build, APART, { [name] = spec })
    return ok, tostring(thrown)
end

-- The namespace the early calls fire at: one of each kind, since what they are about is the phase
-- rather than the payload.
local DEFINITIONS = Define.define(NAMESPACE, {
    beat = Packet.new(flag()),
    ask = Query.new(flag(), flag()),
    board = Set.new(Codecs.struct({ alive = flag() })),
})

-- Every legality rule a definition can break.
local RULES: { Rule } = table.freeze({
    rule("marker-in-packet", "a state marker inside a packet", function()
        return Packet.new(small():newest())
    end),
    rule("marker-in-query", "a state marker inside a query", function()
        return Query.new(small():newest(), flag())
    end),
    rule("marker-nested", "a state marker under a composite inside a packet", function()
        return Packet.new(Codecs.struct({ at = Codecs.array(Codecs.f32():newest(), 0, 2) }))
    end),
    rule("newest-on-key", "a newest marker on the field a set is keyed by", function()
        return keyedBy(Codecs.enum({ "red", "blue" }):newest())
    end),
    rule(
        "too-many-fields",
        "a set declaring more top-level fields than a dirty mask holds",
        function()
            return Set.new(record(FIELDS + 1))
        end
    ),
    rule(
        "lossy-over-cap",
        "an unreliable packet whose widest frame does not fit one fire",
        function()
            return Packet.new(Codecs.buffer(0, OVERSIZE)):unreliable()
        end
    ),
    rule("two-deliveries", "a packet declaring two ways of delivering itself", function()
        return Packet.new(flag()):unreliable():newest()
    end),
    rule("key-not-scalar", "a set keyed by a field whose codec is not a scalar", function()
        return keyedBy(Codecs.array(flag(), 0, 2))
    end),
})

-- Public --------------------------------------------------------------

return {
    -- Nothing moves before the seal: the machinery a fire reaches for does not exist until the
    -- schemas are compiled and the transports are open.
    Harness.case("life.traffic-before-start", function()
        local early = `before {NAMESPACE} was started`
        Expect.throws(function()
            DEFINITIONS.beat:fireServer(true)
        end, early)
        Expect.throws(function()
            DEFINITIONS.beat:fireClient(Recipients.ALL, true)
        end, early)
        Expect.throws(function()
            DEFINITIONS.ask:request(true)
        end, early)
        Expect.throws(function()
            DEFINITIONS.board:add(1, { alive = true })
        end, early)
        Expect.throws(function()
            DEFINITIONS.board:update(1, { alive = false })
        end, early)
        Expect.throws(function()
            DEFINITIONS.board:remove(1)
        end, early)
        Expect.throws(function()
            DEFINITIONS.board:clear()
        end, early)
    end),

    -- A query has one responder per direction, refused at registration rather than at the reply.
    Harness.case("query.one-responder", function()
        DEFINITIONS.ask:onServer(function()
            return true
        end)
        Expect.throws(function()
            DEFINITIONS.ask:onServer(function()
                return false
            end)
        end, "already has a responder")
    end),

    -- Responders are immutable after the seal, in both directions, since one attached late answers
    -- requests that already timed out on the far side.
    Harness.case("life.start-seals-responders", function()
        local defs = Define.define(OPENED, { ask = Query.new(flag(), flag()) })
        Session.new(OPENED, defs, Doubles.wire():server(), Doubles.roster(), "server"):start()

        local sealed = "start seals responders"
        Expect.throws(function()
            defs.ask:onServer(function()
                return true
            end)
        end, sealed)
        Expect.throws(function()
            defs.ask:onClient(function()
                return true
            end)
        end, sealed)
    end),

    -- A chain of modifiers, each link held to being a value none of the others became, which is
    -- where a shared table would show.
    Harness.case("codec.modifier-pure", function()
        local base = Codecs.int(0, 100)
        Expect.equal(table.isfrozen(base :: any), true)

        local held: any = base
        local seen: { [any]: boolean } = { [base] = true }
        for _, modifier in CHAIN do
            local link
            if modifier == "validate" then
                link = held:validate(function()
                    return nil
                end)
            elseif modifier == "as" then
                link = held:as(function(v)
                    return v
                end, function(v)
                    return v
                end)
            else
                link = held:newest()
            end
            Expect.holds(seen[link] == nil, `{modifier} answered a codec already in the chain`)
            Expect.equal(table.isfrozen(link), true)
            seen[link] = true
            held = link
        end

        Expect.holds(seen[base] ~= nil, "the base left the chain")
        Expect.equal(table.isfrozen(base :: any), true)
        Expect.throws(function()
            (base :: any).mine = 1
        end)
    end),

    -- A namespace whose own name holds a mark a descriptor separates its names with writes a
    -- descriptor reading as some other namespace.
    Harness.case("total.namespace-legal", function()
        for _, name in MARKED do
            local ok, thrown = pcall(Compile.build, name, NOTHING)
            Expect.holds(not ok, `the namespace {name} compiled`)
            local said = tostring(thrown)
            Expect.holds(
                string.find(said, name, 1, true) ~= nil,
                `a marked namespace threw without naming itself: {said}`
            )
        end
    end),

    -- Every rule, one schema each, compiled on its own so the throw names one fault.
    Harness.case("total.legality-rules", function()
        for _, one in RULES do
            local ok, thrown = compiled(one.name, one.build())
            Expect.holds(not ok, `{one.about} compiled`)
            Expect.holds(
                string.find(thrown, one.name, 1, true) ~= nil,
                `{one.about} threw without naming it: {thrown}`
            )
        end
    end),

    -- Every namespace a caller can build, compiled. A drawn one is legal by construction, so it
    -- compiles to something frozen, and half the cases add one definition breaking a named rule,
    -- which has to throw.
    Harness.property("total.compiles-or-rejects", "schemas", function(rng: Rng.Rng)
        local specs = Generate.definitions(rng)
        if not rng:bool() then
            local built = Compile.build(APART, specs)
            Expect.equal(table.isfrozen(built :: any), true)
            return
        end

        local one = rng:pick(RULES)
        specs[one.name] = one.build()
        local ok, thrown = pcall(Compile.build, APART, specs)
        Expect.holds(not ok, `a namespace holding {one.about} compiled`)
        Expect.holds(
            string.find(tostring(thrown), one.name, 1, true) ~= nil,
            `{one.about} threw without naming it: {tostring(thrown)}`
        )
    end),
}
