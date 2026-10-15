--!strict
--!optimize 2
-- A scenario driven on two machines over the fake wire, as the frames it puts on it.

local Session = require("@src/runtime/Session")
local Set = require("@src/api/Set")

local Doubles = require("@self/Doubles")
local Scenarios = require("@self/Scenarios")

local Stage = {}

-- The namespace every run opens under and the one definition in it. One name for every scenario,
-- because a stage is torn down with its machines and two runs never overlap.
local SPACE = "stage"
local RECORDS = "records"

local ROUNDS = Doubles.ROUNDS

-- What a frame addressed to nobody in particular is filed under, and to a player with no label.
local EVERYBODY = "all"
local NOBODY = "gone"

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

-- A run in progress. `frames` is every frame the wire carried since the last flush.
export type Run = {
    read scenario: Scenarios.Scenario,
    read wire: Doubles.Wire,
    read roster: Doubles.Roster,
    read server: Session.Session,
    read set: any,
    read viewers: { [string]: Viewer },
    read labels: { [Player]: string },
    read frames: { Carried },
}

-- Private -------------------------------------------------------------

-- The definitions one machine requires, once a side, so no viewer reads the server's own view.
local function defined(of: Scenarios.Scenario): any
    local set: any = Set.new(of.fixture.codec)
    if of.key ~= nil then set = set:keyBy(of.key) end
    return { [RECORDS] = set }
end

-- Who a frame went to, as the name a scenario knows them by.
local function addressed(of: Run, to: Player?): string
    if to == nil then return EVERYBODY end
    return of.labels[to] or NOBODY
end

-- A machine arriving under the label a scenario names it by, built the way the first one was.
local function joins(of: Run, who: string): Viewer
    local player = of.roster:join(who)
    local defs = defined(of.scenario)
    local session = Session.new(SPACE, defs, of.wire:client(player), of.roster, "client")
    session:start()
    of.wire:settle()

    local held: Viewer = { who = player, session = session, set = defs[RECORDS] }
    of.viewers[who] = held
    of.labels[player] = who
    return held
end

-- Flushes until the lane carries nothing more, or says it never settled. A step that names a
-- budget flushes once, since what a budget held back is the whole of what it is about.
local function ships(of: Run, budget: number?)
    if budget ~= nil then
        of.server:flush(budget)
        of.wire:settle()
        return
    end
    for _ = 1, ROUNDS do
        local before = of.wire:moved().frames
        of.server:flush()
        of.wire:settle()
        if of.wire:moved().frames == before then return end
    end
    error(`the lane was still carrying after {ROUNDS} flushes`, 0)
end

-- Public --------------------------------------------------------------

-- A scenario opened: a server, no viewers yet, and a watcher on the lane. Nothing is flushed here,
-- since a scenario's first step decides what the first frame is.
function Stage.opened(of: Scenarios.Scenario): Run
    local wire = Doubles.wire()
    local roster = Doubles.roster()
    local defs = defined(of)
    local server = Session.new(SPACE, defs, wire:server(), roster, "server")
    server:start()

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
    wire:watch(function(carried: Doubles.Carried)
        table.insert(
            run.frames,
            { to = addressed(run, carried.to), line = Doubles.dumped(carried) }
        )
    end)
    return run
end

-- One step, performed. A flush clears the record before it runs, so a dump reads that flush's
-- traffic rather than everything the lane has carried since the run opened.
function Stage.performed(of: Run, step: Scenarios.Step)
    if step.act == "add" then
        of.set:add(step.id, step.record)
    elseif step.act == "update" then
        of.set:update(step.id, step.fields)
    elseif step.act == "remove" then
        of.set:remove(step.id)
    elseif step.act == "clear" then
        of.set:clear()
    elseif step.act == "join" then
        joins(of, step.who)
    elseif step.act == "leave" then
        local held = of.viewers[step.who]
        of.roster:leave(held.who)
        of.wire:gone(held.who)
        of.viewers[step.who] = nil
    elseif step.act == "audience" then
        of.set:audience(step.key, { of.viewers[step.who].who })
    else
        table.clear(of.frames)
        ships(of, step.budget)
    end
end

-- What the last flush carried, per recipient in name order and in arrival order within each.
function Stage.dump(of: Run): { string }
    local names = {}
    local held: { [string]: { string } } = {}
    for _, carried in of.frames do
        if held[carried.to] == nil then
            held[carried.to] = {}
            table.insert(names, carried.to)
        end
        table.insert(held[carried.to], carried.line)
    end
    table.sort(names)

    local out = {}
    for _, name in names do
        for _, line in held[name] do
            table.insert(out, `{name} {line}`)
        end
    end
    return out
end

return table.freeze(Stage)
