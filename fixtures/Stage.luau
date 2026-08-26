--!strict
--!optimize 2
-- A scenario driven on two machines over the fake wire, as the frames it puts on it.

local Lync = require ("@src")
local Session = require ("@src/runtime/Session")

local Doubles = require ("@fixtures/Doubles")
local Scenarios = require ("@fixtures/Scenarios")

local Stage = {}

-- Constants -----------------------------------------------------------

--[[
    The namespace every run opens under, and the one definition in it.

    One name for every scenario, because a stage is torn down with its machines and two runs never
    overlap. A scenario that wanted its own name would be filing the frames under two things.
]]
const SPACE = "stage"
const RECORDS = "records"

-- How many flushes a drain takes before it is a failure, read from its one home.
const ROUNDS = Doubles.ROUNDS

-- What a frame addressed to nobody in particular is filed under, and to somebody who has left.
const EVERYBODY = "all"
const NOBODY = "gone"

-- Types ---------------------------------------------------------------

-- One machine on the wire: who it belongs to, and the set it reads through.
export type Viewer = {
    read who: Player,
    read session: Session.Session,
    read set: any,
}

-- One frame the lane carried, under the name of whoever it went to.
export type Carried = {
    read to: string,
    read line: string,
}

--[[
    A run in progress. `frames` is every frame the wire carried since the last flush, so a caller
    reading it after a flush reads that flush and nothing before it.
]]
export type Run = {
    read scenario: Scenarios.Scenario,
    read wire: Doubles.Wire,
    read roster: Doubles.Roster,
    read server: Session.Session,
    read set: any,
    read viewers: { [string]: Viewer },
    read labels: { [Player]: string },
    frames: { Carried },
}

-- Private -------------------------------------------------------------

--[[
    The definitions one machine requires, once a side the way `Doubles` asks for. A stage sharing
    one table would have every viewer reading the server's own view, and every audience would be
    satisfied by construction.
]]
local function defined (of: Scenarios.Scenario): any
    local set = Lync.replicate (of.fixture.codec)
    if of.key ~= nil then set = (set :: any):keyBy (of.key) end

    return { [RECORDS] = set }
end

--[[
    Who a frame went to, as the name a scenario knows them by.

    A frame naming nobody went to everybody, and one naming somebody who never joined under a label
    cannot happen, since a stage is the only thing that makes them.
]]
local function addressed (of: Run, to: Player?): string
    if to == nil then return EVERYBODY end
    return of.labels[to] or NOBODY
end

-- Public --------------------------------------------------------------

--[[
    A scenario opened: a server, no viewers yet, and a watcher on the lane.

    Nothing is flushed here. A scenario's first step decides what the first frame is, and a stage
    that had already sent something would put it in the first flush's dump.
]]
function Stage.opened (of: Scenarios.Scenario): Run
    local wire = Doubles.wire ()
    local roster = Doubles.roster ()

    local defs = defined (of)
    local server = Session.new (SPACE, defs, wire:server (), roster, "server")
    server:start ()

    local run: Run = {
        scenario = of,
        wire = wire,
        roster = roster,
        server = server,
        set = defs[RECORDS],
        viewers = {},
        labels = {},
        frames = {},
    }

    wire:watch (
        function (carried: Doubles.Carried)
            table.insert (
                run.frames,
                { to = addressed (run, carried.to), line = Doubles.dumped (carried) }
            )
        end
    )
    return run
end

--[[
    A machine arriving under the label a scenario names it by, built the way the first one was so
    a late join differs from an early one in nothing but when it happened.
]]
function Stage.joins (of: Run, who: string): Viewer
    local player = of.roster:join (who)
    local defs = defined (of.scenario)

    local session = Session.new (SPACE, defs, of.wire:client (player), of.roster, "client")
    session:start ()
    of.wire:settle ()

    local held: Viewer = { who = player, session = session, set = defs[RECORDS] }
    of.viewers[who] = held
    of.labels[player] = who
    return held
end

--[[
    One step, performed.

    A flush is the one act that clears the record before it runs, because what a dump reads is that
    flush's traffic rather than everything the lane has carried since the run opened.
]]
function Stage.performed (of: Run, step: Scenarios.Step)
    if step.act == "add" then
        of.set:add (step.id, step.record)
    elseif step.act == "update" then
        of.set:update (step.id, step.fields)
    elseif step.act == "remove" then
        of.set:remove (step.id)
    elseif step.act == "clear" then
        of.set:clear ()
    elseif step.act == "join" then
        Stage.joins (of, step.who)
    elseif step.act == "leave" then
        local held = of.viewers[step.who]
        of.roster:leave (held.who)
        of.wire:gone (held.who)
        of.viewers[step.who] = nil
    elseif step.act == "audience" then
        of.set:audience (step.key, { of.viewers[step.who].who })
    else
        table.clear (of.frames)
        Stage.ships (of, step.budget)
    end
end

-- What the last flush carried, per recipient in name order and in arrival order within each.
function Stage.dump (of: Run): { string }
    local names = {}
    local held: { [string]: { string } } = {}

    for _, carried in of.frames do
        if held[carried.to] == nil then
            held[carried.to] = {}
            table.insert (names, carried.to)
        end
        table.insert (held[carried.to], carried.line)
    end

    table.sort (names)

    local out = {}
    for _, name in names do
        for _, line in held[name] do
            table.insert (out, `{name} {line}`)
        end
    end
    return out
end

-- Flushes until the lane carries nothing more, or says it never settled.
function Stage.ships (of: Run, budget: number?)
    for _ = 1, ROUNDS do
        local before = of.wire:moved ().frames
        of.server:flush (budget)
        of.wire:settle ()

        if of.wire:moved ().frames == before then return end
    end

    error (`the lane was still carrying after {ROUNDS} flushes`, 0)
end

return table.freeze (Stage)
