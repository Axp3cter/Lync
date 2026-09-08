--!strict
--!optimize 2
-- One fire and many recipients, measured against how many, which is the whole of what a broadcast
-- promises.

local Recipients = require("@src/channel/Recipients")
local Session = require("@src/runtime/Session")

local Doubles = require("@fixtures/Doubles")
local Schemas = require("@fixtures/Schemas")

local Harness = require("@bench/harness")

local SPACE = "fanout"

-- The one definition, fired at everyone, and the case of the frame of movement it carries.
local BEAT = Schemas.BEAT
local CARRIED = "typical"

-- The audience sizes, an order of magnitude apart.
local SIZES = table.freeze({ one = 1, ten = 10, hundred = 100 } :: { [string]: number })

-- One server and the definition every row fires, with the clients standing on the roster.
type Run = {
    read wire: Doubles.Wire,
    read defs: any,
    read server: Session.Session,
    read value: any,
}

-- Private -------------------------------------------------------------

-- A server and however many clients the row is about, every one of them listening and ready.
local function opened(viewers: number): Run
    local wire = Doubles.wire()
    local roster = Doubles.roster()
    local serverDefs = Schemas.beat()
    local server = Session.new(SPACE, serverDefs, wire:server(), roster, "server")
    server:start()
    for index = 1, viewers do
        local who = roster:join(`viewer{index}`)
        local clientDefs = Schemas.beat()
        clientDefs[BEAT]:onClient(function() end)
        Session.new(SPACE, clientDefs, wire:client(who), roster, "client"):start()
    end
    wire:settle()
    return {
        wire = wire,
        defs = serverDefs,
        server = server,
        value = Schemas.cased(Schemas.motion, CARRIED),
    }
end

-- One broadcast, flushed and carried to rest.
local function fanned(of: Run): number
    of.defs[BEAT]:fireClient(Recipients.ALL, of.value)
    return Harness.drained(of)
end

-- A broadcast reaching that many, which for a per-recipient encode would be impossible to miss
-- at a hundred.
local function reaching(name: string): Harness.Row
    return Harness.row({
        name = `fanout.{name}`,
        setup = function(): Run
            return opened(SIZES[name])
        end,
        run = fanned,
        bytes = Harness.weighs(fanned),
    })
end

-- Public --------------------------------------------------------------

return { reaching("one"), reaching("ten"), reaching("hundred") }
