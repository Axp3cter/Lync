--!strict
--!optimize 2
-- The bench harness: how one row is measured, and the turns the suites drive a lane through.

local Doubles = require("@fixtures/Doubles")
local Session = require("@src/runtime/Session")

local Report = require("@self/Report")

local Harness = {}

-- How long a batch must take before its time means anything. `os.clock` is good to about a
-- microsecond, so a batch of ten milliseconds carries four digits, and every row here measures an
-- operation costing tens of nanoseconds.
local FLOOR = 0.01

-- How many batches a row is measured over, of which the fastest is the one believed.
local SAMPLES = 5

-- Batches tried for a heap reading, past the samples, where every sample ran through a
-- collection: a collection frees more than a batch allocated, so the reading comes back negative
-- and says nothing about the row.
local ATTEMPTS = 16

-- Turns run and thrown away before anything is timed, so a cold first batch cannot clear the
-- floor at a size a warm one would not.
local WARMS = 200

-- The widest a batch grows to. A row that has not cleared the floor by here is measuring something
-- below the harness's own cost.
local MOST = 2 ^ 26

-- What a probe batch takes before its reading is used to size the real one.
local PROBED = 0.002

local KILOBYTE = 1024
local NANOS = 1e9

-- How many flushes an opener may take to go quiet before it is a set that never settles.
local ROUNDS = 64

-- One thing worth measuring. `setup` builds what the operation needs once, outside every timing.
-- `run` performs it once and answers something, which is kept, since a call whose result went
-- nowhere is one an optimizer may reconsider. `bytes` rides only on the rows that cross the wire.
export type Row = {
    read name: string,
    read setup: (() -> any)?,
    read run: (any) -> any,
    read bytes: ((any) -> number)?,
}

export type Cell = Report.Cell

-- What a suite's turn is driven through, shared by every row of it that sends, and the toggle a
-- row that alternates a value steps between turns.
export type Turning = {
    read wire: Doubles.Wire,
    read server: Session.Session,
}

export type Stepping = { up: boolean }

-- Private -------------------------------------------------------------

-- Where every measured call's answer goes. An upvalue, the cheapest write there is, and readable
-- below so nothing can decide the write is dead.
local sank: any = nil

-- The yardstick, and the first line of every report: an empty call through the loop every row
-- below it goes through. Every number includes this one.
local FLOOR_ROW: Row = table.freeze({
    name = "host.floor",
    run = function(): nil
        return nil
    end,
})

local function prepared(of: Row): any
    return if of.setup ~= nil then of.setup() else nil
end

-- One batch, from its own setup: the seconds it took and the heap it grew, read after the setup
-- and outside the clock so neither lands in the number.
local function batched(of: Row, ops: number): (number, number)
    local state = prepared(of)
    local before = gcinfo()
    local from = os.clock()
    for _ = 1, ops do
        sank = of.run(state)
    end
    local spent = os.clock() - from
    return spent, gcinfo() - before
end

-- The turns that fill the floor, worked out from what one costs rather than from where a search
-- stopped, since a crossing moves with the noise where a divided cost barely moves at all.
local function settled(of: Row): number
    local at, spent = 1, 0
    while at < MOST do
        spent = batched(of, at)
        if spent >= PROBED then break end
        at *= 4
    end
    if spent <= 0 then return MOST end
    local wanted = math.floor(at * FLOOR / spent)
    return math.max(1, math.min(MOST, wanted))
end

-- One row, measured. Throws where the row does, which its caller contains.
local function measured(of: Row): Cell
    batched(of, WARMS)
    local ops = settled(of)

    -- The fastest of the samples, and the widest heap reading none of them lost to a collection,
    -- kept apart because a row that allocates nothing reads zero and a collection answers the same.
    local fastest, widest = math.huge, nil :: number?
    for _ = 1, SAMPLES do
        local spent, grew = batched(of, ops)
        if spent < fastest then fastest = spent end
        if grew >= 0 and (widest == nil or grew > widest) then widest = grew end
    end
    for _ = 1, if widest == nil then ATTEMPTS else 0 do
        local _, grew = batched(of, ops)
        if grew >= 0 then
            widest = grew
            break
        end
    end

    local wire = if of.bytes ~= nil then of.bytes(prepared(of)) else nil
    return table.freeze({
        name = of.name,
        ops = ops,
        nanos = fastest / ops * NANOS,
        allocated = if widest ~= nil then widest * KILOBYTE / ops else nil,
        wire = wire,
    })
end

-- Public --------------------------------------------------------------

-- The value an alternating field takes this turn, so that every write is a write.
function Harness.stepped(of: Stepping, low: number, high: number): number
    of.up = not of.up
    return if of.up then high else low
end

-- One flush and everything it put on the lane, which is what most rows are measured over.
function Harness.drained(of: Turning): number
    of.server:flush()
    return of.wire:settle()
end

-- Flushed until the lane carries nothing, which is where a row's first measured turn should start,
-- since an opener that flushes once leaves whatever a budget would not carry.
function Harness.quiet(of: Turning)
    for _ = 1, ROUNDS do
        if Harness.drained(of) == 0 then return end
    end
    error(`a lane still carrying after {ROUNDS} flushes`, 0)
end

-- A turn read for the bytes it moved rather than for the time it took.
function Harness.weighs(turn: (any) -> number): (any) -> number
    return function(of: any): number
        local before = of.wire:moved().bytes
        turn(of)
        return of.wire:moved().bytes - before
    end
end

-- The last thing a measured call answered, which nothing has a use for.
function Harness.sank(): any
    return sank
end

-- The one door a row is declared through, so nothing measured can be edited after it is named.
function Harness.row(of: Row): Row
    return table.freeze(of)
end

-- Every row handed over, measured, with the floor ahead of them.
function Harness.measure(rows: { Row }): { Cell }
    local cells: { Cell } = { measured(FLOOR_ROW) }
    for _, of in rows do
        local ok, answer = pcall(measured, of)
        local cell: Cell = if ok
            then answer
            else table.freeze({
                name = of.name,
                ops = 0,
                nanos = 0,
                allocated = 0,
                note = `did not run: {tostring(answer)}`,
            })
        table.insert(cells, cell)
        task.wait()
    end
    return cells
end

-- How many of them did not run, which is the one thing a caller does with the notes.
function Harness.broke(cells: { Cell }): number
    local count = 0
    for _, one in cells do
        if one.note ~= nil then
            count += 1
        end
    end
    return count
end

return table.freeze(Harness)
