--!strict
--!optimize 2
-- What a namespace's own numbering puts on the wire, which is that two of them number alike.

local Codecs = require("@src/codec")
local Packet = require("@src/api/Packet")
local Session = require("@src/runtime/Session")

local Doubles = require("@fixtures/Doubles")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")

-- Two namespaces holding one schema under one set of names, which is the collision worth making.
local ARENA = "arena"
local LOBBY = "lobby"
local SENDER = "alice"

-- Two definitions identical in everything but their names.
local BEAT = "beat"
local PULSE = "pulse"
local TOP = 100
local CARRIED = 7

-- One namespace on its own lane, with the frames it has put there since a reading was last taken.
type Space = {
    read wire: Doubles.Wire,
    read player: Player,
    read defs: any,
    read server: Session.Session,
    frames: { string },
}

-- The definitions one machine requires, rebuilt for every side and every namespace, since
-- isolation is the claim.
local function defined(): any
    return { [BEAT] = Packet.new(Codecs.int(0, TOP)), [PULSE] = Packet.new(Codecs.int(0, TOP)) }
end

local function opened(space: string, roster: Doubles.Roster, player: Player): Space
    local wire = Doubles.wire()
    local defs = defined()
    local server = Session.new(space, defs, wire:server(), roster, "server")
    server:start()
    local mine = defined()
    for _, name in { BEAT, PULSE } do
        mine[name]:onClient(function() end)
    end
    Session.new(space, mine, wire:client(player), roster, "client"):start()
    wire:settle()

    local held: Space = { wire = wire, player = player, defs = defs, server = server, frames = {} }
    wire:watch(function(carried: Doubles.Carried)
        table.insert(held.frames, Doubles.dumped(carried))
    end)
    return held
end

-- One fire, drained, as the bytes it put on the lane.
local function fired(of: Space, name: string, value: number): string
    table.clear(of.frames)
    of.defs[name]:fireClient(of.player, value)
    of.server:flush()
    of.wire:settle()
    return table.concat(of.frames, "\n")
end

return {
    -- Two namespaces number their definitions alike, and one numbers its own apart. Counted across
    -- the library, a definition added to one would move the wire under every namespace after it.
    Harness.case("ns.isolated", function()
        local roster = Doubles.roster()
        local player = roster:join(SENDER)
        local arena = opened(ARENA, roster, player)
        local lobby = opened(LOBBY, roster, player)

        local here = fired(arena, BEAT, CARRIED)
        Expect.holds(here ~= "", "a fire put nothing on the lane")
        Expect.equal(fired(lobby, BEAT, CARRIED), here)
        Expect.holds(fired(arena, PULSE, CARRIED) ~= here, "two definitions answered to one id")
    end),
}
