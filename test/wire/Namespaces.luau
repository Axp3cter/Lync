--!strict
--!optimize 2
-- What a namespace's own numbering puts on the wire, which is that two of them number alike.

local Lync = require ("@src")
local Session = require ("@src/runtime/Session")

local Doubles = require ("@fixtures/Doubles")

local Expect = require ("@test/harness/Expect")
local Harness = require ("@test/harness")

-- Constants -----------------------------------------------------------

-- Two namespaces holding one schema under one set of names, which is the collision worth making.
const ARENA = "arena"
const LOBBY = "lobby"

-- The one player every fire is addressed to, because a fire needs somebody and not two of them.
const SENDER = "alice"

-- Two definitions rather than one, identical in everything but their names.
const BEAT = "beat"
const PULSE = "pulse"

-- The bound a fire's value is drawn inside, and the one value every fire here carries.
const TOP = 100
const CARRIED = 7

-- Types ---------------------------------------------------------------

--[[
    One namespace on its own lane, with the frames it has put there since a reading was last taken.

    A lane apiece rather than one between them, because a namespace opens its own remotes and a
    shared lane would be a fake of something the library does not do.
]]
type Space = {
    read wire: Doubles.Wire,
    read player: Player,
    read defs: any,
    read server: Session.Session,
    frames: { string },
}

-- Private -------------------------------------------------------------

--[[
    The definitions one machine requires, rebuilt for every side and every namespace. Isolation is
    the claim, so nothing here may reach a table the thing it is compared against also holds.
]]
local function defined (): any
    return {
        [BEAT] = Lync.packet (Lync.int (0, TOP)),
        [PULSE] = Lync.packet (Lync.int (0, TOP)),
    }
end

-- One namespace opened on both machines, watched from the moment the lane is made.
local function opened (space: string, roster: Doubles.Roster, player: Player): Space
    local wire = Doubles.wire ()

    local defs = defined ()
    local server = Session.new (space, defs, wire:server (), roster, "server")
    server:start ()

    local mine = defined ()
    for _, name in { BEAT, PULSE } do
        mine[name]:onClient (function () end)
    end

    Session.new (space, mine, wire:client (player), roster, "client"):start ()
    wire:settle ()

    local held: Space = { wire = wire, player = player, defs = defs, server = server, frames = {} }

    wire:watch (
        function (carried: Doubles.Carried) table.insert (held.frames, Doubles.dumped (carried)) end
    )
    return held
end

-- One fire, drained, as the bytes it put on the lane and nothing that came before them.
local function fired (of: Space, name: string, value: number): string
    table.clear (of.frames)

    of.defs[name]:fireClient (of.player, value)
    of.server:flush ()
    of.wire:settle ()

    return table.concat (of.frames, "\n")
end

-- Public --------------------------------------------------------------

return {
    --[[
        Two namespaces numbering their definitions alike, and one numbering its own apart. Counted
        across the library, the second namespace opened would number from wherever the first left
        off, so a definition added to one would move the wire under every namespace after it.
    ]]
    Harness.case ("ns.isolated", function ()
        local roster = Doubles.roster ()
        local player = roster:join (SENDER)

        local arena = opened (ARENA, roster, player)
        local lobby = opened (LOBBY, roster, player)

        local here = fired (arena, BEAT, CARRIED)
        Expect.holds (here ~= "", "a fire put nothing on the lane")
        Expect.equal (fired (lobby, BEAT, CARRIED), here)

        local beside = fired (arena, PULSE, CARRIED)
        Expect.holds (beside ~= here, "two definitions in one namespace answered to one id")
    end),
}
