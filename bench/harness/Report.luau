--!strict
--!optimize 2
-- What a run prints: one line per row, and the block a person commits to hold it to.

local Probe = require ("@self/Probe")

local Report = {}

-- Constants -----------------------------------------------------------

--[[
    Where the committed numbers live and what they are keyed by. A cell is one row on one side,
    because the same code compiles natively on the server and runs interpreted on the client, and
    holding one number to both would be holding two machines to whichever was measured last.
]]
const STORE = "bench/baseline.json"

--[[
    How far a time may move before the report says so, since a bench flagging every percent trains
    a reader to ignore the column that matters. Times alone: two runs of one tree moved a heap
    reading by three hundred percent where the widest time moved by sixteen, so one floor over
    both would call most rows of an unchanged tree a regression.
]]
const NOISE = 0.03

-- What a row's name is padded to, so the columns stand under one another.
const WIDTH = 32

-- Types ---------------------------------------------------------------

--[[
    One row measured. `wire` rides only on the rows that cross the wire, and `note` only on the rows
    that did not run, because a bench that reported a zero for a row that threw would be a
    regression nobody could see.
]]
export type Cell = {
    read name: string,
    read ops: number,
    read nanos: number,
    read allocated: number?,
    read wire: number?,
    read note: string?,
}

-- One side's committed numbers, as the store holds them.
export type Baseline = { [string]: { [string]: { nanos: number, allocated: number? } } }

-- Private -------------------------------------------------------------

--[[
    A number as a report prints it. Three places on the nanoseconds and one on the bytes, because a
    host does not answer the same figure twice and printing digits it cannot reproduce would make
    every diff a diff. The batch size prints whole: it is the count the doubling landed on rather
    than a measurement, and rounding it would hide which power of two a row settled at.
]]
local function nanos (of: number): string return string.format ("%9.3f ns", of) end

local function bytes (of: number): string return string.format ("%7.1f B", of) end

--[[
    What stands where a heap reading would, for a row whose every batch ran through a collection.
    Not a zero: three rows are about allocating nothing and a reader has to tell them from a row
    that allocates so much the collector never let it be counted.
]]
const UNWEIGHED = "    not weighed"

--[[
    How far a number moved, or nothing where it moved less than the noise floor or where there was
    nothing to move from. A new row prints no delta rather than an infinite one: it has not
    regressed, it has not been measured before.
]]
local function moved (now: number, was: number?): string
    if was == nil or was == 0 then return "" end

    local shift = (now - was) / was
    if math.abs (shift) < NOISE then return "" end
    return string.format ("  %+.0f%%", shift * 100)
end

-- Public --------------------------------------------------------------

Report.STORE = STORE

--[[
    The report, line by line, ready to print. A cell that threw prints its reason where its numbers
    would be, so a run reads top to bottom whether it went well or not.
]]
function Report.lines (host: Probe.Host, cells: { Cell }, was: Baseline?): { string }
    local held = if was ~= nil then was[host.side] else nil
    local out = { `Lync bench: {host.side}, {host.luau}{if host.studio then ", Studio" else ""}` }

    for _, cell in cells do
        local name = string.format (`  %-{WIDTH}s`, cell.name)
        if cell.note ~= nil then
            table.insert (out, `{name}{cell.note}`)
            continue
        end

        local knew = if held ~= nil then held[cell.name] else nil
        local line = `{name}{string.format ("%10d", cell.ops)} ops  {nanos (cell.nanos)}`
        line ..= moved (cell.nanos, if knew ~= nil then knew.nanos else nil)
        line ..= if cell.allocated ~= nil then `  {bytes (cell.allocated)}` else UNWEIGHED
        if cell.wire ~= nil then
            line ..= `  {cell.wire} wire`
        end

        table.insert (out, line)
    end
    return out
end

-- This side's numbers as the store holds them, for a person to paste.
function Report.committed (host: Probe.Host, cells: { Cell }): string
    local names = {}
    local held: { [string]: Cell } = {}

    for _, cell in cells do
        if cell.note ~= nil then continue end
        table.insert (names, cell.name)
        held[cell.name] = cell
    end
    table.sort (names)

    local out = { `{STORE}, under "{host.side}":` }
    for index, name in names do
        local cell = held[name]
        local tail = if index == #names then "" else ","

        -- A row nothing weighed commits its time and says so of the rest, rather than a zero.
        local weighed = if cell.allocated ~= nil
            then string.format ("%.1f", cell.allocated)
            else "null"

        table.insert (
            out,
            string.format (
                '    "%s": { "nanos": %.3f, "allocated": %s }%s',
                name,
                cell.nanos,
                weighed,
                tail
            )
        )
    end
    return table.concat (out, "\n")
end

return table.freeze (Report)
