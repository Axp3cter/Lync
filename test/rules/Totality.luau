--!strict
--!optimize 2
-- What the library refuses: the schemas it will not compile, and the calls it will not take.

local Compile = require ("@src/shape/Compile")
local Lync = require ("@src")
local Protocol = require ("@src/wire/Protocol")

local Expect = require ("@test/harness/Expect")
local Generate = require ("@test/harness/Generate")
local Harness = require ("@test/harness")
local Rng = require ("@test/harness/Rng")

-- Constants -----------------------------------------------------------

-- The namespace this suite opens, which is what its sealed cases have to fire at.
const NAMESPACE = "totality"

-- The namespace a compiled definition is built under, which never reaches a transport.
const APART = "apart"

-- Fields a set may declare, and one past it.
const FIELDS = Protocol.MAX_FIELDS

-- A payload wider than a lossy frame carries, which is what the cap rule rejects.
const OVERSIZE = Protocol.UNRELIABLE_CAP + 1

-- Modifiers a chain applies, in the order a caller would write them.
const CHAIN = table.freeze ({ "validate", "as", "newest" })

--[[
    Two namespace names holding a mark a descriptor puts between its own names.

    Both marks, because a rule written against one of them is a rule half held, and the half left
    out is whichever mark the author happened not to think of.
]]
const MARKED = table.freeze ({ "space;beside", "space=frame" })

--[[
    The three calls a place makes about the library rather than through it, each with the word its
    refusal has to carry.
]]
const BEFORE = table.freeze ({
    table.freeze ({ name = "flush", call = function () Lync.flush () end }),
    table.freeze ({ name = "close", call = function () Lync.close () end }),
    table.freeze ({ name = "stats", call = function () Lync.stats (NAMESPACE) end }),
})

-- A namespace of nothing, which is as much schema as a name is refused without.
const NOTHING: any = table.freeze ({})

-- Types ---------------------------------------------------------------

type Rule = { read name: string, read about: string, read build: () -> any }

-- Private -------------------------------------------------------------

-- A record of that many boolean fields, which is how a field count is drawn past its bound.
local function record (fields: number): any
    local of = {}
    for index = 1, fields do
        of[`f{index}`] = Lync.bool ()
    end
    return Lync.struct (of)
end

--[[
    Compiling one definition on its own, away from the namespace this suite opened. Legality is
    decided where a schema is compiled and not where it is registered, so a rule can be reached
    without a namespace, a handshake, or a second start, which is what makes four thousand of them a
    run affordable.
]]
local function compiled (name: string, spec: any): (boolean, string)
    local ok, thrown = pcall (Compile.build, APART, { [name] = spec })
    return ok, tostring (thrown)
end

-- Public --------------------------------------------------------------

--[[
    The namespace the sealed cases below fire at. It holds one of each kind, because what they are
    about is the phase rather than the payload, and the smallest schema that reaches all three call
    surfaces is one of each.
]]
const DEFINITIONS = {
    beat = Lync.packet (Lync.bool ()),
    ask = Lync.query (Lync.bool (), Lync.bool ()),
    board = Lync.replicate (Lync.struct ({ alive = Lync.bool () })),
}

--[[
    Every legality rule a definition can break, each with the shortest schema that breaks it and
    nothing else. A rule is named by what a person did rather than by what the compiler noticed,
    because the throw is read by whoever wrote the schema.
]]
const RULES: { Rule } = {
    {
        name = "marker-in-packet",
        about = "a state marker inside a packet",
        build = function () return Lync.packet (Lync.int (0, 10):monotonic ()) end,
    },
    {
        name = "marker-in-query",
        about = "a state marker inside a query",
        build = function () return Lync.query (Lync.int (0, 10):monotonic (), Lync.bool ()) end,
    },
    {
        name = "marker-nested",
        about = "a state marker under a composite inside a packet",
        build = function ()
            return Lync.packet (Lync.struct ({ at = Lync.array (Lync.f32 ():newest (), 0, 2) }))
        end,
    },
    {
        name = "newest-on-key",
        about = "a newest marker on the field a set is keyed by",
        build = function ()
            local fields = { team = Lync.enum ({ "red", "blue" }):newest (), hp = Lync.int (0, 9) }
            return Lync.replicate (Lync.struct (fields)):keyBy ("team")
        end,
    },
    {
        name = "too-many-fields",
        about = "a set declaring more top-level fields than a dirty mask holds",
        build = function () return Lync.replicate (record (FIELDS + 1)) end,
    },
    {
        name = "lossy-over-cap",
        about = "an unreliable packet whose widest frame does not fit one fire",
        build = function () return Lync.packet (Lync.buffer (0, OVERSIZE)):unreliable () end,
    },
    {
        name = "two-deliveries",
        about = "a packet declaring two ways of delivering itself",
        build = function () return Lync.packet (Lync.bool ()):unreliable ():newest () end,
    },
    {
        name = "key-not-scalar",
        about = "a set keyed by a field whose codec is not a scalar",
        build = function ()
            local fields = { team = Lync.array (Lync.bool (), 0, 2), hp = Lync.int (0, 9) }
            return Lync.replicate (Lync.struct (fields)):keyBy ("team")
        end,
    },
}

return {
    Harness.opens (NAMESPACE, DEFINITIONS),

    --[[
        Nothing moves before the seal. The machinery a fire reaches for does not exist until the
        schemas are compiled and the transports are open. The request is the client form written on
        the server, so it is a wrong-side call as well as an early one, and what it names is the
        namespace rather than an argument.
    ]]
    Harness.sealed ("life.traffic-before-start", function ()
        local early = `before {NAMESPACE} was started`
        Expect.throws (function () DEFINITIONS.beat:fireServer (true) end, early)
        Expect.throws (function () DEFINITIONS.beat:fireClient (Lync.all, true) end, early)
        Expect.throws (
            function () DEFINITIONS.ask:request (true) end,
            `before {NAMESPACE} was started`
        )
        Expect.throws (function () DEFINITIONS.board:add (1, { alive = true }) end, early)
        Expect.throws (function () DEFINITIONS.board:update (1, { alive = false }) end, early)
        Expect.throws (function () DEFINITIONS.board:remove (1) end, early)
        Expect.throws (function () DEFINITIONS.board:clear () end, early)
    end),

    --[[
        The three lifecycle calls, made before the library is open. What separates them from the
        fires beside them is that each has a plausible quiet answer instead of a throw, and every
        one is a lie: a flush says the queue is empty, a close says the transports are released, and
        a snapshot of zeros reads as a namespace that has been quiet.
    ]]
    Harness.sealed ("life.lifecycle-before-start", function ()
        for _, door in BEFORE do
            Expect.throws (door.call, door.name)
        end
    end),

    --[[
        A query has one responder per direction, and the second registration is where that is said.
        Refusing at registration rather than at the reply is what makes it a programmer error: at
        reply time both responders exist and the library would have to pick, and whichever it picked
        would be right half the time and silent about the other half.
    ]]
    Harness.sealed ("query.one-responder", function ()
        DEFINITIONS.ask:onServer (function () return true end)
        Expect.throws (function ()
            DEFINITIONS.ask:onServer (function () return false end)
        end, "already has a responder")
    end),

    --[[
        The library starts once per machine and nothing reopens it. The runner has already started
        it by the time this runs, which is why the case is one line: the second start is the only
        one a suite can make.
    ]]
    Harness.case ("life.start-once", function ()
        Expect.throws (function () Lync.start () end, "start has already run")
    end),

    --[[
        Definitions are immutable after the seal. A namespace opened late holds ids nobody else
        assigned and moves a hash the other machine has already accepted, so the last frame both
        agreed about is the one sent before it.
    ]]
    Harness.case ("life.start-seals-defs", function ()
        Expect.throws (
            function () Lync.define ("late", { beat = Lync.packet (Lync.bool ()) }) end,
            "was defined after start"
        )
    end),

    --[[
        Responders are immutable after the seal, in both directions. One attached late begins
        answering requests that already timed out on the far side, which reaches the requester as a
        reply to nothing and reaches the responder as a call it cannot tell from a live one.
    ]]
    Harness.case ("life.start-seals-responders", function ()
        local sealed = "start seals responders"
        Expect.throws (function ()
            DEFINITIONS.ask:onServer (function () return true end)
        end, sealed)
        Expect.throws (function ()
            DEFINITIONS.ask:onClient (function () return true end)
        end, sealed)
    end),

    --[[
        A chain of modifiers, each link held to being a value none of the others became. Asking one
        base what four modifiers make of it is a separate question, and this asks a chain whether
        the third link is still the second, which is where a shared table would show.
    ]]
    Harness.case ("codec.modifier-pure", function ()
        local base = Lync.int (0, 100)
        Expect.equal (table.isfrozen (base :: any), true)

        local held = base
        local seen: { [any]: boolean } = { [base] = true }

        for _, modifier in CHAIN do
            local next_ = if modifier == "validate"
                then held:validate (function () return nil end)
                elseif modifier == "as" then held:as (
                    function (v) return v end,
                    function (v) return v end
                )
                else (held :: any):newest ()

            Expect.holds (seen[next_] == nil, `{modifier} answered a codec already in the chain`)
            Expect.equal (table.isfrozen (next_ :: any), true)

            seen[next_] = true
            held = next_
        end

        Expect.holds (seen[base] ~= nil, "the base left the chain")
        Expect.equal (table.isfrozen (base :: any), true)
        Expect.throws (function () (base :: any).mine = 1 end)
    end),

    --[[
        A namespace whose own name holds a mark a descriptor separates its names with. The text is
        what a handshake hashes, so such a name writes a descriptor reading as some other namespace
        and two machines holding one schema agree about being different.
    ]]
    Harness.case ("total.namespace-legal", function ()
        for _, name in MARKED do
            local ok, thrown = pcall (Compile.build, name, NOTHING)
            Expect.holds (not ok, `the namespace {name} compiled`)

            local said = tostring (thrown)
            Expect.holds (
                string.find (said, name, 1, true) ~= nil,
                `a marked namespace threw without naming itself: {said}`
            )
        end
    end),

    --[[
        Every rule, one schema each. Each is compiled on its own so the throw names one fault and
        the case that fails names one rule, and each is the shortest schema breaking it, so a throw
        for the wrong reason reads as a pass nowhere.
    ]]
    Harness.case ("total.legality-rules", function ()
        for _, rule in RULES do
            local ok, thrown = compiled (rule.name, rule.build ())
            if ok then
                Expect.holds (false, `{rule.about} compiled`)
                continue
            end
            if string.find (thrown, rule.name, 1, true) ~= nil then continue end
            Expect.holds (false, `{rule.about} threw without naming it: {thrown}`)
        end
    end),

    --[[
        Every namespace a caller can build, compiled. A drawn one is legal by construction, so it
        has to compile and answer something frozen, and half the cases add one definition breaking a
        named rule, which has to throw. The claim is the pair: a compiler that accepts everything
        passes the first half, and one that rejects everything passes the second.
    ]]
    Harness.property ("total.compiles-or-rejects", "schemas", function (rng: Rng.Rng)
        local specs = Generate.definitions (rng)

        if not Rng.bool (rng) then
            local built = Compile.build (APART, specs)
            Expect.equal (table.isfrozen (built :: any), true)
            return
        end

        local rule = Rng.pick (rng, RULES)
        specs[rule.name] = rule.build ()

        local ok, thrown = pcall (Compile.build, APART, specs)
        if not ok and string.find (tostring (thrown), rule.name, 1, true) ~= nil then return end
        if ok then
            Expect.holds (false, `a namespace holding {rule.about} compiled`)
            return
        end
        Expect.holds (false, `{rule.about} threw without naming it: {tostring (thrown)}`)
    end),
}
