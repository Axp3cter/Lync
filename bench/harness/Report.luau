--!strict
--!optimize 2
-- What a run prints: one line per row, and the block a person commits to hold it to.

local Report = {}

-- Where the committed numbers live, keyed by the host they were measured on.
local STORE = "bench/baseline.json"

-- How far a time may move before the report says so, since a bench flagging every percent trains
-- a reader to ignore the column that matters. Times alone: a heap reading moves far more between
-- two runs of one tree than a time does.
local NOISE = 0.03

-- What a row's name is padded to, so the columns stand under one another.
local WIDTH = 32

-- What stands where a heap reading would, for a row whose every batch ran through a collection.
-- Not a zero, since some rows are about allocating nothing.
local UNWEIGHED = "    not weighed"

-- One row measured. `wire` rides only on the rows that cross the wire, and `note` only on the rows
-- that did not run, so a row that threw never reads as a zero.
export type Cell = {
    read name: string,
    read ops: number,
    read nanos: number,
    read allocated: number?,
    read wire: number?,
    read note: string?,
}

-- Every host's committed numbers, as the store holds them.
export type Baseline = { [string]: { [string]: { nanos: number, allocated: number? } } }

-- Private -------------------------------------------------------------

-- Three places on the nanoseconds and one on the bytes, since a host does not answer the same
-- figure twice. The batch size prints whole, being a count rather than a measurement.
local function nanos(of: number): string
    return string.format("%9.3f ns", of)
end

local function bytes(of: number): string
    return string.format("%7.1f B", of)
end

-- How far a number moved, or nothing where it moved less than the noise floor or where there was
-- nothing to move from.
local function moved(now: number, was: number?): string
    if was == nil or was == 0 then return "" end
    local shift = (now - was) / was
    if math.abs(shift) < NOISE then return "" end
    return string.format("  %+.0f%%", shift * 100)
end

-- Public --------------------------------------------------------------

Report.STORE = STORE

-- The report, line by line, ready to print. A cell that threw prints its reason where its numbers
-- would be, so a run reads top to bottom whether it went well or not.
function Report.lines(host: string, cells: { Cell }, was: Baseline?): { string }
    local held = if was ~= nil then was[host] else nil
    local out = { `Lync bench: {host}` }
    for _, cell in cells do
        local name = string.format(`  %-{WIDTH}s`, cell.name)
        if cell.note ~= nil then
            table.insert(out, `{name}{cell.note}`)
            continue
        end
        local knew = if held ~= nil then held[cell.name] else nil
        local line = `{name}{string.format("%10d", cell.ops)} ops  {nanos(cell.nanos)}`
        line ..= moved(cell.nanos, if knew ~= nil then knew.nanos else nil)
        line ..= if cell.allocated ~= nil then `  {bytes(cell.allocated)}` else UNWEIGHED
        if cell.wire ~= nil then
            line ..= `  {cell.wire} wire`
        end
        table.insert(out, line)
    end
    return out
end

-- This host's numbers as the store holds them, for a person to paste.
function Report.committed(host: string, cells: { Cell }): string
    local names = {}
    local held: { [string]: Cell } = {}
    for _, cell in cells do
        if cell.note ~= nil then continue end
        table.insert(names, cell.name)
        held[cell.name] = cell
    end
    table.sort(names)

    local out = { `{STORE}, under "{host}":` }
    for index, name in names do
        local cell = held[name]
        local tail = if index == #names then "" else ","
        -- A row nothing weighed commits its time and says so of the rest, rather than a zero.
        local weighed = if cell.allocated ~= nil
            then string.format("%.1f", cell.allocated)
            else "null"
        local line = '    "%s": { "nanos": %.3f, "allocated": %s }%s'
        table.insert(out, string.format(line, name, cell.nanos, weighed, tail))
    end
    return table.concat(out, "\n")
end

return table.freeze(Report)
