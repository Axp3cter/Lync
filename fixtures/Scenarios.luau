--!strict
--!optimize 2
-- The scripted traffic both places replay: what a set is told, in order, and nothing more.

local Lync = require ("@src")
local Protocol = require ("@src/wire/Protocol")

local Schemas = require ("@self/Schemas")

local Scenarios = {}

-- Constants -----------------------------------------------------------

--[[
    How many records each shape of scenario carries. A fill is small enough to read in a frame dump,
    a storm is the load the bench measures against, and a starve is sized past the section bound so
    a floor budget has to defer.
]]
const FILLED = 8
const STORMED = 64
const STARVED = 256

-- How many times a storm writes every record it holds, which is what makes it a storm.
const ROUNDS = 5

-- The fixtures the scenarios below drive, bound once each.
const ENTITY = Schemas.entity
const PROFILE = Schemas.profile
const EVERYTHING = Schemas.everything

-- Types ---------------------------------------------------------------

--[[
    One thing a scenario tells the library to do. A step carries no expectation: the oracle computes
    what should follow, and the goldens record what did, so a step that stated its own answer would
    be a third place to keep correct.
]]
export type Step =
    { read act: "add", read id: number, read record: any }
    | { read act: "update", read id: number, read fields: { [string]: any } }
    | { read act: "remove", read id: number }
    | { read act: "clear" }
    | { read act: "flush", read mark: string, read budget: number? }
    | { read act: "join", read who: string }
    | { read act: "leave", read who: string }
    | { read act: "audience", read key: any, read who: string }

--[[
    A scenario names the fixture its records conform to and the field a keyed set partitions by, so
    a driver has everything it needs to build the set before the first step. Players are labels: a
    fixture cannot hold a Player, and the driver owns whether they are stubs or the real thing.
]]
export type Scenario = {
    read name: string,
    read fixture: Schemas.Fixture,
    read key: string?,
    read steps: { Step },
}

-- Private -------------------------------------------------------------

-- Every step is a frozen record, and this is the one place that freezes one.
local function step (of: Step): Step return table.freeze (of) end

local function add (id: number, record: any): Step
    return step ({ act = "add" :: "add", id = id, record = record })
end

local function update (id: number, fields: { [string]: any }): Step
    return step ({ act = "update" :: "update", id = id, fields = fields })
end

local function remove (id: number): Step return step ({ act = "remove" :: "remove", id = id }) end

local function clear (): Step return step ({ act = "clear" :: "clear" }) end

local function flush (mark: string, budget: number?): Step
    return step ({ act = "flush" :: "flush", mark = mark, budget = budget })
end

local function join (who: string): Step return step ({ act = "join" :: "join", who = who }) end

local function leave (who: string): Step return step ({ act = "leave" :: "leave", who = who }) end

local function audience (key: any, who: string): Step
    return step ({ act = "audience" :: "audience", key = key, who = who })
end

-- The case the nth filled record takes, cycled so a set holds more than one value.
local function cycled (fixture: Schemas.Fixture, index: number): any
    return fixture.cases[(index - 1) % #fixture.cases + 1].value
end

-- The steps are frozen with the scenario, so a driver that replayed one cannot have altered it.
local function scenario (
    name: string,
    fixture: Schemas.Fixture,
    key: string?,
    steps: { Step }
): Scenario
    return table.freeze ({
        name = name,
        fixture = fixture,
        key = key,
        steps = table.freeze (steps),
    })
end

-- Every step of a list, then every step of the next, as one list.
local function joined (parts: { { Step } }): { Step }
    local out = {}
    for _, part in parts do
        table.move (part, 1, #part, #out + 1, out)
    end
    return out
end

-- A set filled from the front, ids one upward, so no scenario has to name an id to write to.
local function fills (fixture: Schemas.Fixture, count: number): { Step }
    local out = table.create (count) :: { Step }
    for index = 1, count do
        table.insert (out, add (index, cycled (fixture, index)))
    end
    return out
end

-- Every record written what a caller computes from its id, which is one delta per record.
local function touches (count: number, fields: (number) -> { [string]: any }): { Step }
    local out = table.create (count) :: { Step }
    for index = 1, count do
        table.insert (out, update (index, fields (index)))
    end
    return out
end

-- Every record written, flushed, and again, which is what a storm is.
local function storming (count: number, times: number): { Step }
    local out = {}
    for round = 1, times do
        for index = 1, count do
            table.insert (out, update (index, { x = round * 7 }))
        end
        table.insert (out, flush (`round-{round}`))
    end
    return out
end

-- Public --------------------------------------------------------------

-- Records in, one flush. The keyframe on its own, which every later cost is read against.
Scenarios.fill = scenario (
    "fill",
    ENTITY,
    nil,
    joined ({
        fills (ENTITY, FILLED),
        { flush ("keyframe") },
    })
)

--[[
    One field of every record moves. The delta claim in its simplest form: what ships is the mask
    and the values under it, never the records around them.
]]
Scenarios.drift = scenario (
    "drift",
    ENTITY,
    nil,
    joined ({
        fills (ENTITY, FILLED),
        { flush ("keyframe") },
        touches (FILLED, function (): { [string]: any } return { x = 42 } end),
        { flush ("delta") },
    })
)

--[[
    Records that move different fields between them. No one field is on every record of the delta,
    so which of them carry it has to be spelled, and the section spends what a field on all of them
    leaves out.
]]
Scenarios.parted = scenario (
    "parted",
    ENTITY,
    nil,
    joined ({
        fills (ENTITY, FILLED),
        { flush ("keyframe") },
        touches (FILLED, function (index: number): { [string]: any }
            if index % 2 == 0 then return { x = 42 } end

            return { y = 42 }
        end),
        { flush ("delta") },
    })
)

--[[
    Traffic that must cost nothing. First every record written the value it already holds, then a
    flush with nothing behind it at all. Those are the two ways a stream goes idle, and neither may
    put a byte on the wire.
]]
Scenarios.quiet = scenario (
    "quiet",
    ENTITY,
    nil,
    joined ({
        fills (ENTITY, FILLED),
        { flush ("keyframe") },
        touches (
            FILLED,
            function (index: number): { [string]: any } return { x = cycled (ENTITY, index).x } end
        ),
        { flush ("unchanged") },
        { flush ("empty") },
    })
)

-- Three writes to one field between flushes, which is one send carrying the last.
Scenarios.coalesce = scenario ("coalesce", ENTITY, nil, {
    add (1, Schemas.cased (ENTITY, "typical")),
    flush ("keyframe"),
    update (1, { x = 11 }),
    update (1, { x = 22 }),
    update (1, { x = 33 }),
    flush ("net"),
})

--[[
    Three sequences the net-op table folds. Added and removed inside one flush never existed.
    Added and then written ships once, as a keyframe holding the value it ended on. Removed and
    added back ships both, which is the one fold that grows: a receiver has to be told the record
    is gone before it is handed another under the same id.
]]
Scenarios.fleeting = scenario ("fleeting", ENTITY, nil, {
    add (1, Schemas.cased (ENTITY, "typical")),
    remove (1),
    flush ("cancelled"),
    add (2, Schemas.cased (ENTITY, "smallest")),
    update (2, { x = 7 }),
    flush ("merged"),
    remove (2),
    add (2, Schemas.cased (ENTITY, "largest")),
    flush ("replaced"),
})

-- A full set emptied, which is one section rather than a removal each.
Scenarios.sweep = scenario (
    "sweep",
    ENTITY,
    nil,
    joined ({
        fills (ENTITY, FILLED),
        { flush ("keyframe") },
        { clear () },
        { flush ("cleared") },
    })
)

--[[
    A keyed set through the three things a key does: grant a viewer, move a record between
    partitions, and replace one key's audience with another. The migration is the interesting one.
    Inside a single flush the losing viewer is told the record is gone and the gaining viewer is
    told it arrived.
]]
Scenarios.migrate = scenario ("migrate", PROFILE, "team", {
    join ("a"),
    join ("b"),
    join ("c"),
    audience ("red", "a"),
    audience ("blue", "b"),
    audience ("spectator", "c"),
    add (1, Schemas.cased (PROFILE, "shortest")),
    add (2, Schemas.cased (PROFILE, "typical")),
    add (3, Schemas.cased (PROFILE, "longest")),
    flush ("granted"),
    update (1, { team = "blue" }),
    flush ("migrated"),
    audience ("blue", "a"),
    flush ("replaced"),
})

--[[
    A client arriving after the records did, and one leaving while they stand. The arrival is owed
    every visible record as catch-up. The departure is owed nothing, which is what the flush after
    it says.
]]
Scenarios.visitors = scenario (
    "visitors",
    ENTITY,
    nil,
    joined ({
        { join ("a") },
        fills (ENTITY, FILLED),
        { flush ("keyframe") },
        { join ("b") },
        { flush ("catch-up") },
        { leave ("a") },
        { flush ("after-leave") },
    })
)

--[[
    More records than the smallest legal budget can carry. The first flush ships the prefix that
    fits and holds the rest, and the second, unbudgeted, drains it. Sized past the section bound on
    purpose: a budget at the floor must still ship one whole section, which is the only reason
    draining ever finishes.
]]
Scenarios.starve = scenario (
    "starve",
    ENTITY,
    nil,
    joined ({
        fills (ENTITY, STARVED),
        { flush ("prefix", Protocol.BUDGET_FLOOR) },
        { flush ("drain") },
    })
)

-- The load the bench reads: a filled set, then every record moving every flush.
Scenarios.storm = scenario (
    "storm",
    ENTITY,
    nil,
    joined ({
        fills (ENTITY, STORMED),
        { flush ("keyframe") },
        storming (STORMED, ROUNDS),
    })
)

--[[
    The acceptance record end to end, on a keyed set with one viewer. A keyframe, a delta that fills
    every field the smallest case left at its floor, a clear through the none sentinel, a write to
    the field that replicates unreliably, a flush with nothing behind it, and the removal.
]]
Scenarios.acceptance = scenario ("acceptance", EVERYTHING, "team", {
    join ("a"),
    audience ("red", "a"),
    add (1, Schemas.cased (EVERYTHING, "smallest")),
    flush ("keyframe"),
    update (1, Schemas.cased (EVERYTHING, "typical")),
    flush ("delta"),
    update (1, { title = Lync.none }),
    flush ("cleared"),
    update (1, { carry = Vector3.new (2.5, 0, 5) }),
    flush ("newest"),
    flush ("idle"),
    remove (1),
    flush ("removed"),
})

--[[
    Every scenario, in the order the goldens file them. A suite parametrizes over this list, so a
    new scenario is covered the moment it lands.
]]
Scenarios.all = table.freeze ({
    Scenarios.fill,
    Scenarios.drift,
    Scenarios.parted,
    Scenarios.quiet,
    Scenarios.coalesce,
    Scenarios.fleeting,
    Scenarios.sweep,
    Scenarios.migrate,
    Scenarios.visitors,
    Scenarios.starve,
    Scenarios.storm,
    Scenarios.acceptance,
})

--[[
    The player labels a scenario needs, in the order it first names them. Read off the steps rather
    than declared beside them, because a declared list is a second place to keep right and the steps
    are the one that has to be.
]]
function Scenarios.viewers (of: Scenario): { string }
    local seen = {}
    local order = {}

    for _, step in of.steps do
        local who = if step.act == "join" then step.who else nil
        if who ~= nil and not seen[who] then
            seen[who] = true
            table.insert (order, who)
        end
    end
    return order
end

return table.freeze (Scenarios)
