--!strict
--!optimize 2
--[[
    One fire and many recipients, measured against how many, which is the whole of what a broadcast
    promises.
]]

local Lync = require ("@src")
local Session = require ("@src/runtime/Session")

local Doubles = require ("@fixtures/Doubles")
local Schemas = require ("@fixtures/Schemas")

local Harness = require ("@bench/harness")

-- Constants -----------------------------------------------------------

const SPACE = "fanout"

-- The one definition, fired at everyone.
const BEAT = Schemas.BEAT

-- The audience sizes, an order of magnitude apart.
const ONE = 1
const TEN = 10
const HUNDRED = 100

--[[
    The shape a broadcast carries, and the case of it.

    A frame of movement, and the same case another suite fires, so the two are measuring one
    payload from two directions and the fan is the only thing that differs between them.
]]
const CARRIED = "typical"

-- Types ---------------------------------------------------------------

--[[
    One server and the definition every row fires, with the clients standing on the roster rather
    than here. What a fanout row varies is how many are listening, so the count is the lane's and
    what this holds is the one thing fired at all of them.
]]
type Run = {
    read wire: Doubles.Wire,
    read defs: any,
    read server: Session.Session,
    read value: any,
}

-- Private -------------------------------------------------------------

-- A server and however many clients the row is about, every one of them listening and ready.
local function opened (viewers: number): Run
    local wire = Doubles.wire ()
    local roster = Doubles.roster ()

    local serverDefs = Schemas.beat ()
    local server = Session.new (SPACE, serverDefs, wire:server (), roster, "server")
    server:start ()

    for index = 1, viewers do
        local who = roster:join (`viewer{index}`)
        local clientDefs = Schemas.beat ()

        clientDefs[BEAT]:onClient (function () end)
        Session.new (SPACE, clientDefs, wire:client (who), roster, "client"):start ()
    end
    wire:settle ()

    return {
        wire = wire,
        defs = serverDefs,
        server = server,
        value = Schemas.cased (Schemas.motion, CARRIED),
    }
end

-- One broadcast, flushed and carried to rest.
local function fanned (of: Run): number
    of.defs[BEAT]:fireClient (Lync.all, of.value)
    of.server:flush ()
    return of.wire:settle ()
end

-- What one turn put on the lane, which for a broadcast is one frame however many hear it.
local function weighs (of: Run): number
    local before = of.wire:moved ().bytes

    fanned (of)
    return of.wire:moved ().bytes - before
end

-- Public --------------------------------------------------------------

return {
    -- A broadcast with one recipient, which is the base.
    Harness.row ({
        name = "fanout.one",
        setup = function (): Run return opened (ONE) end,
        run = fanned,
        bytes = weighs,
    }),

    -- The same fire reaching ten.
    Harness.row ({
        name = "fanout.ten",
        setup = function (): Run return opened (TEN) end,
        run = fanned,
        bytes = weighs,
    }),

    --[[
        The same fire reaching a hundred, which is where a per-recipient encode would be impossible
        to miss.
    ]]
    Harness.row ({
        name = "fanout.hundred",
        setup = function (): Run return opened (HUNDRED) end,
        run = fanned,
        bytes = weighs,
    }),
}
