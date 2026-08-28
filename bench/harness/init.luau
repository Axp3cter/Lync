--!strict
--!optimize 2
-- The bench runner: how one row is measured, and what a run makes of the answer.

local Doubles = require ("@fixtures/Doubles")
local Session = require ("@src/runtime/Session")

local Probe = require ("@self/Probe")
local Report = require ("@self/Report")

local Harness = {}

-- Constants -----------------------------------------------------------

--[[
    How long a batch must take before its time means anything. `os.clock` is good to about a
    microsecond, so a batch of ten milliseconds carries four digits and a batch of one carries
    three. Every row here measures an operation costing tens of nanoseconds, which no clock reads
    one of.
]]
const FLOOR = 0.01

-- How many batches a row is measured over, of which the fastest is the one believed.
const SAMPLES = 5

--[[
    Batches tried for a heap reading, past the samples, where every sample ran through a collection.
    A collection frees more than a batch allocated, so the reading comes back negative and says
    nothing about the row. Most rows clear this on the first try and a row that allocates enough to
    make the collector run every time never will, which is what a reading of nothing is for.
]]
const ATTEMPTS = 16

--[[
    Turns run and thrown away before anything is timed. Sharing one state across every batch used to
    warm the code as a side effect of the search, and a batch building its own no longer does, so a
    cold first batch could clear the floor at a size a warm one would not and take the samples down
    with it. Enough to reach the paths a turn uses and far too few to matter beside a batch.
]]
const WARMS = 200

--[[
    The widest a batch grows to. A row that has not cleared the floor by here is measuring something
    below the harness's own cost, and doubling further would buy digits nothing can act on.
]]
const MOST = 2 ^ 26

--[[
    What a probe batch takes before its reading is used to size the real one. Small enough that
    finding it costs little beside the batch it sizes, and far enough above the clock's own step
    that the cost it answers is worth dividing by.
]]
const PROBED = 0.002

-- What the heap reading is in, and what a report is in.
const KILOBYTE = 1024
const NANOS = 1e9

--[[
    How many flushes an opener may take to go quiet before it is a set that never settles. A flush
    carries what a budget allows, so a set opened with records in it catches a viewer up over
    several, and a bound says so instead of spinning.
]]
const ROUNDS = 64

-- Where the committed numbers sit in the tree, if they have been committed.
const BASELINE = "baseline"

-- Where the rows live, walked in name order the way the test tree's are.
const SUITE = "suite"

-- Types ---------------------------------------------------------------

-- Which machine a run measures, one compiling a row natively where the other interprets it.
export type Side = "server" | "client"

--[[
    One thing worth measuring. `setup` builds what the operation needs once, outside every timing.
    `run` performs it once and answers something, and what it answers is kept, since a call whose
    result went nowhere is one an optimizer may reconsider. `bytes` rides only on the rows that
    cross the wire.
]]
export type Row = {
    read name: string,
    read setup: (() -> any)?,
    read run: (any) -> any,
    read bytes: ((any) -> number)?,
}

export type Cell = Report.Cell

-- Private -------------------------------------------------------------

--[[
    Where every measured call's answer goes, so nothing an optimizer may reconsider is measured.
    An upvalue rather than a field, the loop writing it once a turn and an upvalue store being the
    cheapest write there is, and it is readable below so nothing can decide the write is dead.
]]
local sank: any = nil

--[[
    The yardstick, and the first line of every report. Two hosts run one piece of code at different
    speeds, so every run measures one thing whose cost is known: an empty call through the loop
    every row below it goes through. Every number includes this one, and a reader who wants the
    operation alone subtracts it.
]]
const FLOOR_ROW: Row = table.freeze ({
    name = "host.floor",
    run = function (): nil return nil end,
})

--[[
    One batch, from its own setup: the seconds it took and the heap it grew, read after the setup
    and outside the clock so neither lands in the number. Its own, because a batch sharing state
    runs against what the one before it left, so a set that fills costs what its position cost and
    the number follows a batch size that settles a doubling apart between runs.
]]
local function batched (of: Row, ops: number): (number, number)
    local state = if of.setup ~= nil then of.setup () else nil

    local before = gcinfo ()
    local from = os.clock ()

    for _ = 1, ops do
        sank = of.run (state)
    end

    local spent = os.clock () - from
    local grew = gcinfo () - before
    return spent, grew
end

--[[
    The turns that fill the floor, worked out from what one costs rather than from where a search
    stopped. A crossing moves with the noise, so two readings of one row settled a factor of two
    apart and a per-turn cost that varies with the size followed them. What noise moves here is the
    cost the probe divides, which barely moves at all.
]]
local function settled (of: Row): number
    local at, spent = 1, 0
    while at < MOST do
        spent = batched (of, at)
        if spent >= PROBED then break end
        at *= 4
    end
    if spent <= 0 then return MOST end

    local wanted = math.floor (at * FLOOR / spent)
    return math.max (1, math.min (MOST, wanted))
end

-- One row, measured. Throws where the row does, which its caller contains.
local function measured (of: Row): Cell
    batched (of, WARMS)
    local ops = settled (of)

    --[[
        The fastest of the samples, and the widest heap reading none of them lost to a collection.
        Kept apart because zero is a reading three rows below are about and a collection answers the
        same zero, so a growth that was never seen is nothing rather than none.
    ]]
    local fastest, widest = math.huge, nil :: number?
    for _ = 1, SAMPLES do
        local spent, grew = batched (of, ops)
        if spent < fastest then fastest = spent end
        if grew >= 0 and (widest == nil or grew > widest) then widest = grew end
    end

    for _ = 1, if widest == nil then ATTEMPTS else 0 do
        local _, grew = batched (of, ops)
        if grew < 0 then continue end

        widest = grew
        break
    end

    -- What one turn moves, measured off a setup of its own, built the way a batch's is.
    local wire = nil
    if of.bytes ~= nil then wire = of.bytes (if of.setup ~= nil then of.setup () else nil) end

    return table.freeze ({
        name = of.name,
        ops = ops,
        nanos = fastest / ops * NANOS,
        allocated = if widest ~= nil then widest * KILOBYTE / ops else nil,
        wire = wire,
    })
end

-- Every row a suite holds, its modules walked in name order.
local function collect (suite: Instance): { Row }
    local found: { Row } = {}

    local children = suite:GetChildren ()
    table.sort (children, function (a: Instance, b: Instance): boolean return a.Name < b.Name end)

    for _, child in children do
        if not child:IsA ("ModuleScript") then continue end

        local list = require (child) :: { Row }
        assert (typeof (list) == "table" and #list > 0, `bench/{child.Name} declares no rows`)
        table.move (list, 1, #list, #found + 1, found)
    end
    return found
end

-- Those numbers as the module holds them, or nothing where none are committed.
local function committed (root: Instance): Report.Baseline?
    local held = root:FindFirstChild (BASELINE)
    if held == nil or not held:IsA ("ModuleScript") then return nil end
    return require (held) :: Report.Baseline
end

-- Public --------------------------------------------------------------

-- What a suite's turn is driven through, shared by every row of it that sends.
export type Turning = {
    read wire: Doubles.Wire,
    read server: Session.Session,
    up: boolean,
}

-- The value an alternating field takes this turn, so that every write is a write.
function Harness.stepped (of: Turning, low: number, high: number): number
    of.up = not of.up
    return if of.up then high else low
end

-- One flush and everything it put on the lane, which is what most rows are measured over.
function Harness.drained (of: Turning): number
    of.server:flush ()
    return of.wire:settle ()
end

--[[
    Flushed until the lane carries nothing, which is where a row's first measured turn should start.
    An opener that flushes once leaves whatever a budget would not carry, so the turns after it pay
    a catch-up the row is not about and pay it once however long the batch, which is a per-turn cost
    that falls as the batch grows.
]]
function Harness.quiet (of: Turning)
    for _ = 1, ROUNDS do
        if Harness.drained (of) == 0 then return end
    end
    error (`a lane still carrying after {ROUNDS} flushes`, 0)
end

--[[
    A turn read for the bytes it moved rather than for the time it took.

    Wrapped rather than measured beside the turn, because a row names its own turn once and a size
    a second copy of it produced would be a size for a row nobody measured.
]]
function Harness.weighs (turn: (any) -> number): (any) -> number
    return function (of: any): number
        local before = of.wire:moved ().bytes

        turn (of)
        return of.wire:moved ().bytes - before
    end
end

-- The last thing a measured call answered, which nothing has a use for. See the sink above.
function Harness.sank (): any return sank end

-- The one door a row is declared through, so nothing measured can be edited after it is named.
function Harness.row (of: Row): Row return table.freeze (of) end

-- Every row handed over, measured, with the floor ahead of them.
function Harness.measure (rows: { Row }): { Cell }
    local cells: { Cell } = { measured (FLOOR_ROW) }

    for _, of in rows do
        local ok, answer = pcall (measured, of)
        table.insert (
            cells,
            if ok
                then answer :: Cell
                else table.freeze ({
                    name = of.name,
                    ops = 0,
                    nanos = 0,
                    allocated = 0,
                    note = `did not run: {tostring (answer)}`,
                })
        )
        task.wait ()
    end
    return cells
end

-- How many of them did not run, which is the one thing a caller does with the notes.
function Harness.broke (cells: { Cell }): number
    local count = 0
    for _, one in cells do
        if one.note ~= nil then
            count += 1
        end
    end
    return count
end

-- Every row this side owns, found where a place keeps them, measured and reported.
function Harness.run (side: Side)
    local root = assert (script.Parent, "the bench harness expects to sit under the bench tree")
    local suite = assert (root:FindFirstChild (SUITE), `the bench tree has no {SUITE}`)

    local host = Probe.host (side)
    local cells = Harness.measure (collect (suite))

    for _, line in Report.lines (host, cells, committed (root)) do
        print (line)
    end

    print (`\n{Report.committed (host, cells)}`)

    local broke = Harness.broke (cells)
    if broke > 0 then warn (`\n  {broke} rows did not run`) end
end

return table.freeze (Harness)
