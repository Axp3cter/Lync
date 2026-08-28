--!strict
-- The command line: every command is a list of steps, run in order and summarized.

local process = require ("@lune/process")
local stdio = require ("@lune/stdio")

local Build = require ("./Build")
local Cases = require ("./Cases")
local Checks = require ("./Checks")
local Place = require ("./Place")
local Repo = require ("./Repo")
local Ruling = require ("./Ruling")
local Tools = require ("./Tools")

-- Types ---------------------------------------------------------------

type Step = {
    title: string,
    run: () -> Ruling.Ruling,
}

type Command = {
    name: string,
    brief: string,
    steps: { string },
}

-- Constants -----------------------------------------------------------

local RESET = stdio.color ("reset")
local PASSED = stdio.color ("green") .. "pass" .. RESET
local FAILED = stdio.color ("red") .. "FAIL" .. RESET

--[[
    Every step the commands compose, declared once. A step names what it is doing while it runs, so
    a slow tool is never mistaken for a hang.
]]
local STEPS: { [string]: Step } = {
    install = { title = "installing the toolchain", run = Tools.install },
    toolchain = { title = "checking the toolchain", run = Tools.installed },
    sourcemap = {
        title = "regenerating the sourcemap",
        run = function () return Build.sourcemap () end,
    },
    cases = { title = "holding the readers to their cases", run = Cases.run },
    format = { title = "formatting", run = function () return Tools.format ("write") end },
    formatted = {
        title = "checking formatting",
        run = function () return Tools.format ("check") end,
    },
    trees = {
        title = "type-checking the trees",
        run = function () return Tools.analyze ("trees") end,
    },
    tooling = {
        title = "type-checking the tooling",
        run = function () return Tools.analyze ("tooling") end,
    },
    versions = { title = "holding the version to one home", run = Checks.versions },
    edges = { title = "holding the layer stack", run = Checks.edges },
    constants = { title = "holding the wire constants to one home", run = Checks.constants },
    surface = { title = "holding the surface to the README", run = Checks.surface },
    folded = { title = "holding the debug door shut in a release build", run = Checks.folded },
    prose = { title = "holding the prose to its marks", run = Checks.prose },
    saying = { title = "holding a block to its length and its line", run = Checks.saying },
    restating = { title = "holding a comment to saying something", run = Checks.restating },
    twice = { title = "holding every fact to one home", run = Checks.twice },
    shaped = { title = "holding a comment to the shape it takes", run = Checks.shaped },
    citing = { title = "holding every comment to standing alone", run = Checks.citing },
    standing = {
        title = "holding every comment to naming nothing elsewhere",
        run = Checks.standing,
    },
    doors = { title = "holding every diagnostic to one door", run = Checks.doors },
    catalogued = { title = "holding every diagnosis to its name", run = Checks.catalogued },
    stated = { title = "holding every constant to saying which it is", run = Checks.stated },
    derived = { title = "holding every working to one place", run = Checks.derived },
    spelling = { title = "holding every vocabulary to its owner", run = Checks.spelling },
    doubles = { title = "holding the trees to one shape", run = Checks.doubles },
    answered = { title = "holding every check to being able to fail", run = Checks.answered },
    width = { title = "holding every line to the column", run = Checks.width },
    configs = { title = "holding the derived configs", run = Checks.configs },
    declaration = {
        title = "type-checking the declaration",
        run = function () return Tools.npm ({ "run", "check" }) end,
    },
    test = {
        title = "building the test place",
        run = function () return Build.place (Repo.TEST) end,
    },
    bench = {
        title = "building the bench place",
        run = function () return Build.place (Repo.BENCH) end,
    },
    model = {
        title = "building the library model",
        run = function () return Build.place (Repo.DEFAULT, Repo.DARKLUA_RELEASE) end,
    },
    dist = { title = "assembling the package", run = Build.dist },
    wally = { title = "publishing to wally", run = Tools.publishWally },
    npm = { title = "publishing to npm", run = Tools.publishNpm },
    serve = { title = "serving to Studio", run = function () return Build.serve (Repo.TEST) end },
    staged = {
        title = "staging the test tree",
        run = function () return Build.stage (Repo.TEST) end,
    },
    place = {
        title = "serving the test place",
        run = function () return Place.serve (Repo.TEST) end,
    },
    weighed = {
        title = "staging the bench tree",
        run = function () return Build.stage (Repo.BENCH) end,
    },
    weigh = {
        title = "serving the bench place",
        run = function () return Place.serve (Repo.BENCH) end,
    },
}

--[[
    Every static check, cheapest first, so a fault a pattern can find is reported before a type
    check has been waited on. Named rather than written inside one command, since publishing runs
    the same gate and a second copy of the list would be one that falls behind.
]]
local CHECKED = {
    "toolchain",
    "sourcemap",
    "cases",
    "formatted",
    "width",
    "prose",
    "saying",
    "restating",
    "twice",
    "shaped",
    "citing",
    "standing",
    "doors",
    "catalogued",
    "stated",
    "derived",
    "spelling",
    "doubles",
    "answered",
    "versions",
    "trees",
    "tooling",
    "edges",
    "constants",
    "surface",
    "folded",
    "configs",
}

-- The gate, and then everything a release does after it, as the steps one command runs in order.
local RELEASED = table.clone (CHECKED)
table.move (
    { "declaration", "model", "test", "bench", "dist", "wally", "npm" },
    1,
    7,
    #RELEASED + 1,
    RELEASED
)

-- The commands, in lifecycle order.
local COMMANDS: { Command } = {
    {
        name = "setup",
        brief = "Install the toolchain and write the sourcemap.",
        steps = { "install", "sourcemap" },
    },
    { name = "verify", brief = "Run every static check.", steps = CHECKED },
    { name = "fmt", brief = "Format every authored tree.", steps = { "format" } },
    {
        name = "analyze",
        brief = "Type-check the trees and the tooling.",
        steps = { "sourcemap", "trees", "tooling" },
    },
    {
        name = "check",
        brief = "Type-check index.d.ts under the pinned TypeScript.",
        steps = { "declaration" },
    },
    { name = "sourcemap", brief = "Regenerate sourcemap.json.", steps = { "sourcemap" } },
    { name = "test", brief = "Build the test place for Studio.", steps = { "test" } },
    { name = "bench", brief = "Build the bench place for Studio.", steps = { "bench" } },
    { name = "serve", brief = "Serve the test place to Studio.", steps = { "serve" } },
    {
        name = "place",
        brief = "Build the test place in Studio without a sync plugin.",
        steps = { "sourcemap", "staged", "place" },
    },
    {
        name = "weigh",
        brief = "Build the bench place in Studio without a sync plugin.",
        steps = { "sourcemap", "weighed", "weigh" },
    },
    { name = "build", brief = "Build the library model.", steps = { "model" } },
    { name = "dist", brief = "Assemble the publishable package.", steps = { "dist" } },
    {
        name = "publish",
        brief = "Verify, build, and publish to both registries as whoever is signed in.",
        steps = RELEASED,
    },
}

-- Private -------------------------------------------------------------

local function line (text: string) stdio.write (`{text}\n`) end

local function usage ()
    line ("usage: lune run scripts/run.luau <command>")
    line ("")
    for _, command in COMMANDS do
        line (string.format ("  %-10s %s", command.name, command.brief))
    end
end

--[[
    Runs every step the command names and answers the process exit code. No step stops the run,
    because one pass should report every problem the repository has rather than only the first.
]]
local function dispatch (command: Command): number
    local started = os.clock ()
    local failures = {}

    for _, name in command.steps do
        local step = STEPS[name]
        line (`{stdio.style ("dim")}{step.title}{RESET}`)

        local ruling = step.run ()
        local mark = if ruling.ok then PASSED else FAILED
        line (if ruling.note ~= nil then `  {mark} {name}: {ruling.note}` else `  {mark} {name}`)
        if not ruling.ok then table.insert (failures, name) end
    end

    local seconds = string.format ("%.1f", os.clock () - started)
    if #failures == 0 then
        line (`{PASSED} {#command.steps} steps in {seconds}s`)
        return 0
    end
    line (`{FAILED} {table.concat (failures, ", ")} in {seconds}s`)
    return 1
end

-- Public --------------------------------------------------------------

if not Repo.exists (Repo.ROKIT) then
    line (`{FAILED} run this from the repository root`)
    process.exit (1)
end

local requested = process.args[1]
if requested == nil or requested == "help" then
    usage ()
    process.exit (if requested == nil then 1 else 0)
end

for _, command in COMMANDS do
    if command.name == requested then process.exit (dispatch (command)) end
end

line (`{FAILED} unknown command: {requested}`)
usage ()
process.exit (1)
