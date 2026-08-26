--!strict
-- The pinned tools: how each is invoked, the one place a child is spawned, and the version probe.

local process = require ("@lune/process")

local Reading = require ("./Reading")
local Repo = require ("./Repo")
local Ruling = require ("./Ruling")
local TEMP = require ("./TEMP_IntegerLiterals")

local Tools = {}

-- Constants -----------------------------------------------------------

-- Forwarding streams the child's output here and captures none.
local FORWARD: process.ExecOptions = { stdio = "forward" }

-- rokit installs these, and the CI action installs rokit, so rokit is never probed.
local PROBED = table.freeze ({ "darklua", "luau-lsp", "lune", "rojo", "stylua", "wally" })

-- The new type solver, which every module in the repository is written against.
local SOLVER = "--flag:LuauSolverV2=true"

--[[
    What npm is called where a spawn can start it. The bare name is a shell script on Windows and
    only the wrapper is an executable, so a spawn of the bare one reports the tool as missing on a
    machine that has it.
]]
local NPM = if process.os == "windows" then "npm.cmd" else "npm"

-- Public --------------------------------------------------------------

-- Judged by exit code alone. A tool that is not on PATH fails rather than throws.
function Tools.run (name: string, args: { string }): Ruling.Ruling
    local ok, outcome = pcall (process.exec, name, args, FORWARD)
    if not ok then return { ok = false, note = `{name} is not on PATH, run setup` } end
    return { ok = outcome.ok, note = if outcome.ok then nil else `{name} exited {outcome.code}` }
end

--[[
    Keeps the child's streams instead of forwarding them, and answers nil when the tool is not on
    PATH. The closure lets process.exec default its options, because a bare reference handed to
    pcall demands every optional argument.
]]
function Tools.capture (name: string, args: { string }): process.ExecResult?
    local ok, outcome = pcall (function () return process.exec (name, args) end)
    return if ok then outcome else nil
end

-- The package manager, under whichever of its names this platform can start.
function Tools.npm (args: { string }): Ruling.Ruling return Tools.run (NPM, args) end

-- Spawns a child that outlives this call. The caller owns it and must kill it.
function Tools.watch (name: string, args: { string }): process.ChildProcess
    return process.create (name, args)
end

--[[
    Rewrites every authored tree in place, or judges it silently. A repository with no trees yet
    passes, because there is nothing for the formatter to disagree with.
]]
function Tools.format (mode: "write" | "check"): Ruling.Ruling
    local targets = Repo.formatted ()
    if #targets == 0 then return { ok = true } end

    local args = if mode == "check" then { "--check" } else {}
    table.move (targets, 1, #targets, #args + 1, args)

    local masked = TEMP.hide (targets)
    local outcome = Tools.run ("stylua", args)
    TEMP.show (masked)
    if outcome.ok or mode == "write" then return outcome end
    return { ok = false, note = "formatting differs, run fmt" }
end

--[[
    Type-checks one of the two analysis units. The trees resolve against the Roblox definitions
    through the sourcemap, and the tooling resolves @lune through its own .luaurc, so neither pass
    can see the other's globals.
]]
function Tools.analyze (unit: "trees" | "tooling"): Ruling.Ruling
    if unit == "tooling" then
        return Tools.run ("luau-lsp", {
            "analyze",
            "--platform=standard",
            `--base-luaurc={Repo.SCRIPTS_LUAURC}`,
            SOLVER,
            Repo.SCRIPTS,
        })
    end

    local targets = Repo.trees ()
    if #targets == 0 then return { ok = true } end

    local args = {
        "analyze",
        "--platform=roblox",
        `--sourcemap={Repo.SOURCEMAP}`,
        `--definitions={Repo.DEFINITIONS}`,
        SOLVER,
    }
    table.move (targets, 1, #targets, #args + 1, args)
    return Tools.run ("luau-lsp", args)
end

--[[
    Brings a fresh machine up: rokit installs everything the manifest pins, and wally installs
    dependencies only once any are declared, so a library that depends on nothing never reaches for
    a registry.
]]
function Tools.install (): Ruling.Ruling
    local installed = Tools.run ("rokit", { "install" })
    if not installed.ok then return installed end

    local wally = Repo.decode ("toml", Repo.WALLY)
    local dependencies = if wally ~= nil then wally.dependencies else nil
    if typeof (dependencies) ~= "table" or next (dependencies :: { [string]: any }) == nil then
        return { ok = true }
    end
    return Tools.run ("wally", { "install" })
end

-- Every tool rokit.toml pins, mapped to the version it pins.
function Tools.pinned (): { [string]: string }
    local manifest = Repo.decode ("toml", Repo.ROKIT)
    local tools = if manifest ~= nil then manifest.tools else nil
    if typeof (tools) ~= "table" then return {} end

    local pins = {}
    for name, spec in tools :: { [string]: any } do
        if typeof (spec) == "string" then pins[name] = string.match (spec, "@(.+)$") end
    end
    return pins
end

--[[
    Holds the machine to the manifest: every probed tool present, at the version it is pinned to.
    Every problem is named, so one run reports them all.
]]
function Tools.installed (): Ruling.Ruling
    local pins = Tools.pinned ()
    if next (pins) == nil then return { ok = false, note = `{Repo.ROKIT} declares no tools` } end

    local wrong = {}
    for _, name in PROBED do
        local pinned = pins[name]
        if pinned == nil then
            table.insert (wrong, `{name} is not pinned`)
            continue
        end

        local outcome = Tools.capture (name, { "--version" })
        if outcome == nil or not outcome.ok then
            table.insert (wrong, `{name} is not on PATH`)
            continue
        end

        local found = Reading.versionIn (outcome.stdout) or Reading.versionIn (outcome.stderr)
        if found ~= pinned then
            table.insert (wrong, `{name} is {found or "unreadable"}, pinned {pinned}`)
        end
    end

    if #wrong == 0 then return { ok = true } end
    return { ok = false, note = `{table.concat (wrong, ", ")}, run setup` }
end

return table.freeze (Tools)
