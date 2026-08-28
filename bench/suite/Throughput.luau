--!strict
--!optimize 2
-- The whole loop over a lane, the flush that carries nothing, and the bare transport beneath both.

local Session = require ("@src/runtime/Session")
local Shape = require ("@src/shape")

local Doubles = require ("@fixtures/Doubles")
local Schemas = require ("@fixtures/Schemas")

local Harness = require ("@bench/harness")

-- Constants -----------------------------------------------------------

const SPACE = "throughput"

-- The one definition, and the one client it is fired at.
const BEAT = Schemas.BEAT
const SENDER = "alice"

--[[
    The lane a fire goes out on, spelled here because the bare row addresses the transport itself
    and has no definition to ask.
]]
const ORDERED: Doubles.Channel = "reliable"

-- The shape a row that sends anything carries.
const CARRIED = "typical"

-- Types ---------------------------------------------------------------

-- Everything a loop row needs, built once and reused, since none of it is what is timed.
type Run = {
    read wire: Doubles.Wire,
    read player: Player,
    read server: Session.Session,
    read defs: any,
    read value: any,
}

-- Private -------------------------------------------------------------

-- Two machines on a lane that never faults, with the client listening.
local function opened (): Run
    local wire = Doubles.wire ()
    local roster = Doubles.roster ()

    local serverDefs = Schemas.beat ()
    local server = Session.new (SPACE, serverDefs, wire:server (), roster, "server")
    server:start ()

    local player = roster:join (SENDER)
    local clientDefs = Schemas.beat ()
    clientDefs[BEAT]:onClient (function () end)

    local client = Session.new (SPACE, clientDefs, wire:client (player), roster, "client")
    client:start ()
    wire:settle ()

    return {
        wire = wire,
        player = player,
        server = server,
        defs = serverDefs,
        value = Schemas.cased (Schemas.motion, CARRIED),
    }
end

--[[
    One turn of the loop: a fire, the flush that carries it, and the rounds that hand it over.

    Settled rather than delivered once, because a frame the lane held is still this turn's traffic
    and a turn that left one behind would be timing a shorter loop than the one it is reporting.
]]
local function turned (of: Run): number
    of.defs[BEAT]:fireClient (of.player, of.value)
    of.server:flush ()
    return of.wire:settle ()
end

-- What one turn put on the lane, counted by the lane and taken after the samples.
local function carried (of: Run): number
    local before = of.wire:moved ().bytes

    turned (of)
    return of.wire:moved ().bytes - before
end

-- Public --------------------------------------------------------------

return {
    -- One fire, from a caller's call to a listener's, over a lane.
    Harness.row ({
        name = "throughput.loop",
        setup = opened,
        run = turned,
        bytes = carried,
    }),

    -- A flush with nothing behind it.
    Harness.row ({
        name = "throughput.empty-flush",
        setup = opened,
        run = function (of: Run): number
            of.server:flush ()
            return of.wire:settle ()
        end,
    }),

    -- The same bytes through the transport with nothing above them.
    Harness.row ({
        name = "throughput.raw-remote",
        setup = function (): any
            local of = opened ()
            local built = Shape.build (Schemas.motion.codec, BEAT)

            local sized = buffer.create (built.maxBytes)
            local width = built.write (sized, 0, of.value)

            return {
                wire = of.wire,
                player = of.player,
                transport = of.wire:server (),
                bytes = buffer.create (width),
            }
        end,
        run = function (state: any): number
            state.transport:fire (ORDERED, state.player, state.bytes, nil)
            return state.wire:settle ()
        end,
        bytes = function (state: any): number return buffer.len (state.bytes) end,
    }),
}
