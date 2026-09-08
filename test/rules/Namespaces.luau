--!strict
--!optimize 2
-- A namespace as the unit it is: what opens one, and what a flush of one will not take.

local Codecs = require("@src/codec")
local Define = require("@src/api/Define")
local Packet = require("@src/api/Packet")
local Protocol = require("@src/wire/Protocol")
local Query = require("@src/api/Query")
local Session = require("@src/runtime/Session")
local Set = require("@src/api/Set")

local Doubles = require("@fixtures/Doubles")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")

local NAMESPACE = "namespaces"

-- The smallest budget a flush takes, and the one below it that it will not.
local FLOOR = Protocol.BUDGET_FLOOR

-- A name no `define` opened, which is what a caller reaches with a typo.
local NOWHERE = "nowhere"

-- A second namespace, opened by the one check that reads what `define` hands back.
local SHARED = "shared"

-- Every kind, so a namespace is more than a table of packets.
local DEFINITIONS = Define.define(NAMESPACE, {
    beat = Packet.new(Codecs.bool()),
    thud = Packet.new(Codecs.bool()),
    stamp = Packet.new(Codecs.bool()):timestamped(),
    ask = Query.new(Codecs.bool(), Codecs.bool()),
    board = Set.new(Codecs.struct({ alive = Codecs.bool() })),
})

-- Public --------------------------------------------------------------

return {
    -- A name already taken: two definitions tables under one name is two schemas one name resolves
    -- to, and whichever the handshake hashed is the one the other side does not have.
    Harness.case("ns.duplicate-name", function()
        Expect.throws(function()
            Define.define(NAMESPACE, DEFINITIONS :: any)
        end, "has already been defined")
    end),

    -- A name the descriptor cannot spell back: nothing at all, or a mark the grammar separates
    -- with. The number holds neither mark, so the definitions already being named are what turn
    -- it away.
    Harness.case("ns.illegal-name", function()
        Expect.throws(function()
            Define.define("", DEFINITIONS :: any)
        end, "cannot be required by anybody")
        Expect.throws(function()
            Define.define("holds;a;mark", {} :: any)
        end, "which is what a descriptor separates its own names with")
        Expect.throws(function()
            Define.define(5 :: any, DEFINITIONS :: any)
        end, "is already named in")
    end),

    -- A value in the table that is not a definition: a bare number is the typo, and a bare codec
    -- is the mistake worth catching.
    Harness.case("ns.non-definition", function()
        local said = "is not a packet, a query or a set"
        Expect.throws(function()
            Define.define(NOWHERE, { wrong = 5 } :: any)
        end, said)
        Expect.throws(function()
            Define.define(NOWHERE, { wrong = Codecs.bool() } :: any)
        end, said)
    end),

    -- What `define` hands back is the definitions themselves, nothing else, and read-only.
    Harness.case("ns.pure-data", function()
        local given: any = { relay = Packet.new(Codecs.bool()) }
        local back: any = Define.define(SHARED, given)
        for name, of in given do
            Expect.holds(back[name] == of, `{name} came back as something else`)
        end
        for name in back do
            Expect.holds(given[name] ~= nil, `{name} is a name nobody declared`)
        end
        Expect.equal(table.isfrozen(back), true)
        Expect.throws(function()
            back.late = Packet.new(Codecs.bool())
        end)
    end),

    -- A budget under the floor. A section is bounded by the same number, so any legal budget ships
    -- at least one of them and a smaller one would ship nothing forever while looking like it was
    -- trying.
    Harness.case("life.flush-floor", function()
        local wire = Doubles.wire()
        local roster = Doubles.roster()
        local server = Session.new(NAMESPACE, DEFINITIONS, wire:server(), roster, "server")
        server:start()

        Expect.throws(function()
            server:flush(FLOOR - 1)
        end, "is under the floor of")
        server:flush(FLOOR)
    end),
}
