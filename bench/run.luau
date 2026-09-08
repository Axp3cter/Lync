--!strict
-- The Lune bench runner: measures every row of every suite and prints the report, with the
-- committed block after it. Usage: lune run bench/run.luau

local fs = require("@lune/fs")
local serde = require("@lune/serde")
local stdio = require("@lune/stdio")

local Load = require("../scripts/Load")

local Harness = Load.file("bench/harness/init.luau")
local Report = Load.file("bench/harness/Report.luau")

-- The host a report was measured on, so nobody reads its numbers against the wrong machine.
local HOST = `lune {_VERSION}`

-- Every row of every suite, in file order.
local rows = {}
for _, list in Load.directory("bench/suite") do
    assert(typeof(list) == "table" and #list > 0, "a bench suite declares no rows")
    table.move(list, 1, #list, #rows + 1, rows)
end

-- Those numbers as the store holds them, or nothing where none are committed.
local baseline = if fs.isFile(Report.STORE)
    then serde.decode("json", fs.readFile(Report.STORE))
    else nil

local cells = Harness.measure(rows)
for _, line in Report.lines(HOST, cells, baseline) do
    print(line)
end
print(`\n{Report.committed(HOST, cells)}`)

local broke = Harness.broke(cells)
if broke > 0 then stdio.ewrite(`\n  {broke} rows did not run\n`) end
