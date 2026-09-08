--!strict
-- The command line: every command is a list of steps, run in order and summarized.
-- Usage: lune run scripts/run.luau <command> [arguments for the test runner]

local process = require("@lune/process")
local stdio = require("@lune/stdio")

local Checks = require("./Checks")
local Gate = require("./Gate")
local Repo = require("./Repo")
local Tools = require("./Tools")

type Step = { title: string, run: () -> Tools.Ruling }

type Command = { name: string, brief: string, steps: { string } }

local RESET = stdio.color("reset")
local PASSED = stdio.color("green") .. "pass" .. RESET
local FAILED = stdio.color("red") .. "FAIL" .. RESET

-- Whatever follows the command, handed on to the test runner: a seed and a name filter.
local PASSED_ON = table.move(process.args, 2, #process.args, 1, {})

-- Every step the commands compose, declared once. A step names what it is doing while it runs, so
-- a slow tool is never mistaken for a hang.
local STEPS: { [string]: Step } = {
    install = { title = "installing the toolchain", run = Tools.install },
    toolchain = { title = "checking the toolchain", run = Tools.installed },
    format = {
        title = "formatting",
        run = function()
            return Tools.format("write")
        end,
    },
    formatted = {
        title = "checking formatting",
        run = function()
            return Tools.format("check")
        end,
    },
    width = { title = "holding every line to the column", run = Checks.width },
    edges = { title = "holding the layer stack", run = Checks.edges },
    trees = {
        title = "type-checking the trees",
        run = function()
            return Tools.analyze("trees")
        end,
    },
    tooling = {
        title = "type-checking the tooling",
        run = function()
            return Tools.analyze("tooling")
        end,
    },
    test = {
        title = "running the suite",
        run = function()
            local args = { "run", Repo.TEST_RUNNER }
            table.move(PASSED_ON, 1, #PASSED_ON, #args + 1, args)
            return Tools.run("lune", args)
        end,
    },
    bench = {
        title = "running the bench",
        run = function()
            return Tools.run("lune", { "run", Repo.BENCH_RUNNER })
        end,
    },
    declaration = {
        title = "type-checking and compiling the declaration",
        run = function()
            local checked = Tools.npm({ "run", "check" })
            if not checked.ok then return checked end
            local staged = Gate.stage()
            if not staged.ok then return staged end
            return Tools.npm({ "run", "compile" })
        end,
    },
    model = { title = "building the library model", run = Tools.build },
}

-- Every check, ordered so most faults are reported before a slow tool has been waited on.
local CHECKED = { "toolchain", "formatted", "width", "edges", "trees", "tooling", "test" }

-- The commands, in lifecycle order.
local COMMANDS: { Command } = {
    { name = "setup", brief = "Install the toolchain.", steps = { "install" } },
    { name = "verify", brief = "Run every check and the suite.", steps = CHECKED },
    { name = "fmt", brief = "Format every authored tree.", steps = { "format" } },
    {
        name = "analyze",
        brief = "Type-check the trees and the tooling.",
        steps = { "trees", "tooling" },
    },
    {
        name = "test",
        brief = "Run the suite, with a seed and a filter after it.",
        steps = { "test" },
    },
    { name = "bench", brief = "Measure every bench row.", steps = { "bench" } },
    {
        name = "check",
        brief = "Type-check index.d.ts under tsc, then compile its use under roblox-ts.",
        steps = { "declaration" },
    },
    { name = "build", brief = "Build the library model.", steps = { "model" } },
}

-- Private -------------------------------------------------------------

local function line(text: string)
    stdio.write(`{text}\n`)
end

local function usage()
    line("usage: lune run scripts/run.luau <command>")
    line("")
    for _, command in COMMANDS do
        line(string.format("  %-8s %s", command.name, command.brief))
    end
end

-- Runs every step the command names and answers the process exit code. No step stops the run,
-- because one pass should report every problem the repository has rather than only the first.
local function dispatch(command: Command): number
    local started = os.clock()
    local failures = {}
    for _, name in command.steps do
        local step = STEPS[name]
        line(`{stdio.style("dim")}{step.title}{RESET}`)
        local ruling = step.run()
        local mark = if ruling.ok then PASSED else FAILED
        line(if ruling.note ~= nil then `  {mark} {name}: {ruling.note}` else `  {mark} {name}`)
        if not ruling.ok then table.insert(failures, name) end
    end

    local seconds = string.format("%.1f", os.clock() - started)
    if #failures == 0 then
        line(`{PASSED} {#command.steps} steps in {seconds}s`)
        return 0
    end
    line(`{FAILED} {table.concat(failures, ", ")} in {seconds}s`)
    return 1
end

-- Public --------------------------------------------------------------

if not Repo.exists(Repo.ROKIT) then
    line(`{FAILED} run this from the repository root`)
    process.exit(1)
end

local requested = process.args[1]
if requested == nil or requested == "help" then
    usage()
    process.exit(if requested == nil then 1 else 0)
end

for _, command in COMMANDS do
    if command.name == requested then process.exit(dispatch(command)) end
end

line(`{FAILED} unknown command: {requested}`)
usage()
process.exit(1)
