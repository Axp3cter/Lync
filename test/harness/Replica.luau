--!strict
--!optimize 2
-- Two machines on one lane with a set between them, which is what a check about a view is read on.

local Session = require ("@src/runtime/Session")
local Types = require ("@src/Types")

local Doubles = require ("@fixtures/Doubles")

local Expect = require ("@test/harness/Expect")

local Replica = {}

-- Constants -----------------------------------------------------------

const ROUNDS = Doubles.ROUNDS

-- Types ---------------------------------------------------------------

-- One telling: which of the three, the id and record it names, what it was before, and any cause.
export type Seen = {
    read kind: string,
    read id: number,
    read record: any,
    read old: any,
    read cause: Types.Cause?,
}

export type Machine = { read session: Session.Session, read defs: any }

-- One client, with a machine of its own, since a viewer is a whole endpoint and not a view.
export type Viewer = {
    read player: Player,
    read machine: Machine,
    read set: any,
    read seen: { Seen },
}

-- What a run was opened with, kept so a client joining later is built the way the first one was.
export type Opening = {
    read space: string,
    read defined: () -> any,
    read watched: string?,
    read chance: Doubles.Faults?,
    read draw: (() -> number)?,
}

-- A server and however many clients have joined it, over one lane.
export type Alone = {
    read opening: Opening,
    read wire: Doubles.Wire,
    read roster: Doubles.Roster,
    read server: Machine,
    read viewers: { Viewer },
}

-- The same, once somebody is watching.
export type Run = Alone & {
    read client: Machine,
    read player: Player,
    read seen: { Seen },
}

--[[
    What a pair is opened with. `wires` runs against each side's definitions before that side
    starts, which is where a caller attaches a listener or a responder, and a roster and a player
    may be handed in, which is what two namespaces sharing one client are.
]]
export type Pairing = {
    read space: string,
    read defined: () -> any,
    read label: string,
    read roster: Doubles.Roster?,
    read player: Player?,
    read wires: ((defs: any, side: string) -> ())?,
}

-- Anything with a lane under it, which is all a reading of what crossed needs.
export type Carrying = { read wire: Doubles.Wire }

-- Two machines on one lane, both started, with nothing carried between them yet.
export type Paired = {
    read wire: Doubles.Wire,
    read roster: Doubles.Roster,
    read player: Player,
    read server: Machine,
    read client: Machine,
}

-- Private -------------------------------------------------------------

--[[
    A client built the way every client here is, watching before it starts.

    Watching first is where a caller writes a watcher, and it is what lets a late join be a check
    about the records that were already there rather than about when the listener was attached.
]]
local function viewer (
    opening: Opening,
    wire: Doubles.Wire,
    roster: Doubles.Roster,
    label: string
): Viewer
    local player = roster:join (label)
    local defs = opening.defined ()
    local session = Session.new (opening.space, defs, wire:client (player), roster, "client")

    local seen: { Seen } = {}
    if opening.watched ~= nil then Replica.watch (defs[opening.watched], seen) end

    session:start ()
    return {
        player = player,
        machine = { session = session, defs = defs },
        set = if opening.watched == nil then nil else defs[opening.watched],
        seen = seen,
    }
end

-- Public --------------------------------------------------------------

--[[
    Every callback a set hands over, in the order it hands them, written into one list.

    The record is copied rather than kept, for the reason every read of a record is copied: the row
    is lent rather than given, and a check holding the row itself would read whatever it became.
]]
function Replica.watch (set: any, into: { Seen })
    local function kept (of: any): any return if of ~= nil then table.clone (of) else nil end

    local function put (kind: string, id: number, of: any, was: any, why: Types.Cause?)
        table.insert (
            into,
            { kind = kind, id = id, record = kept (of), old = kept (was), cause = why }
        )
    end

    set:onAdded (function (id: number, of: any) put ("added", id, of, nil, nil) end)
    set:onChanged (function (id: number, of: any, was: any) put ("changed", id, of, was, nil) end)
    set:onRemoved (function (id: number, why: Types.Cause) put ("removed", id, nil, nil, why) end)
end

-- A server started, and one client watching it, which is what a check about a view opens with.
function Replica.open (opening: Opening, label: string): Run
    local of = Replica.serves (opening)
    local first = Replica.joins (of, label)

    return {
        opening = of.opening,
        wire = of.wire,
        roster = of.roster,
        server = of.server,
        viewers = of.viewers,
        client = first.machine,
        player = first.player,
        seen = first.seen,
    }
end

-- The set the server owns, which is what a check about a view writes through.
function Replica.ours (of: Alone): any
    local name = of.opening.watched
    Expect.holds (name ~= nil, "this run watches no definition, so there is no set to read")
    return of.server.defs[name]
end

-- What a viewer was told, thrown away, so a check reads what came after and not what led up to it.
function Replica.forgets (held: Viewer) table.clear (held.seen) end

-- A server started with nobody watching it yet, which is what a check about arriving opens with.
function Replica.serves (opening: Opening): Alone
    local wire = Doubles.wire (opening.chance, opening.draw)
    local roster = Doubles.roster ()

    local defs = opening.defined ()
    local session = Session.new (opening.space, defs, wire:server (), roster, "server")
    session:start ()
    wire:settle ()

    return {
        opening = opening,
        wire = wire,
        roster = roster,
        server = { session = session, defs = defs },
        viewers = {},
    }
end

--[[
    Two machines on one lane, each with definitions of its own, both started and settled.

    Settled once a side, so a frame that never crossed cannot be read as one that did. The server
    starts before the client joins, which is the order a place has.
]]
function Replica.paired (of: Pairing): Paired
    local wire = Doubles.wire ()
    local roster = of.roster or Doubles.roster ()

    local serverDefs = of.defined ()
    if of.wires ~= nil then of.wires (serverDefs, "server") end

    local server = Session.new (of.space, serverDefs, wire:server (), roster, "server")
    server:start ()

    local player = of.player or roster:join (of.label)
    local clientDefs = of.defined ()
    if of.wires ~= nil then of.wires (clientDefs, "client") end

    local client = Session.new (of.space, clientDefs, wire:client (player), roster, "client")
    client:start ()
    wire:settle ()

    return {
        wire = wire,
        roster = roster,
        player = player,
        server = { session = server, defs = serverDefs },
        client = { session = client, defs = clientDefs },
    }
end

-- Another client, joined after the run opened, which is what a late join is made of.
function Replica.joins (of: Alone, label: string): Viewer
    local held = viewer (of.opening, of.wire, of.roster, label)
    table.insert (of.viewers, held)

    of.wire:settle ()
    return held
end

--[[
    A client gone from the game. The roster drops it and the lane stops reaching it on a
    broadcast, which is the pair a departure is: a library told nobody left would go on addressing
    frames to it.
]]
function Replica.leaves (of: Alone, held: Viewer)
    of.roster:leave (held.player)
    of.wire:gone (held.player)
end

-- Everything queued, sent, and carried as far as the lane will carry it.
function Replica.ships (of: Alone)
    of.server.session:flush ()
    of.wire:settle ()
end

-- The same drain where how long it took is not the check's subject, which is most of them.
function Replica.drains (of: Alone) Replica.rounds (of) end

-- Flushed until nothing more moves, bounded so a set that never settles says so rather than spins.
function Replica.rounds (of: Alone): number
    for round = 1, ROUNDS do
        local before = of.wire:moved ().frames
        Replica.ships (of)

        if of.wire:moved ().frames == before then return round end
    end

    Expect.holds (false, `the lane was still carrying after {ROUNDS} flushes`)
    return ROUNDS
end

--[[
    What the lane has carried, read off the lane rather than off the counters under test. Taken as
    bytes and as frames, which are the two things a claim about traffic is ever made of.
]]
function Replica.carried (of: Carrying): number return of.wire:moved ().bytes end

function Replica.crossed (of: Carrying): number return of.wire:moved ().frames end

return table.freeze (Replica)
