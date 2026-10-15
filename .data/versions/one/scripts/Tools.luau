--!strict
-- The pinned tools: how each is invoked, the one place a child is spawned, and the version probe.

local fs = require("@lune/fs")
local process = require("@lune/process")

local Repo = require("./Repo")

local Tools = {}

-- What every step answers with: whether it passed, and the line a reader needs when it did not.
export type Ruling = { ok: boolean, note: string? }

-- Forwarding streams the child's output here and captures none.
local FORWARD: process.ExecOptions = { stdio = "forward" }

-- The tools the scripts invoke, which rokit installs. rokit itself is never probed, since the CI
-- action installs it.
local PROBED = table.freeze({ "luau-lsp", "lune", "stylua" })

-- The new type solver, which every module in the repository is written against.
local SOLVER = "--flag:LuauSolverV2=true"

-- What npm is called where a spawn can start it. The bare name is a shell script on Windows and
-- only the wrapper is an executable.
local NPM = if process.os == "windows" then "npm.cmd" else "npm"

-- Private -------------------------------------------------------------

-- The first dotted number anywhere in the text, which is how every pinned tool answers --version.
local function versionIn(text: string): string?
    return string.match(text, "%d+%.%d+[%.%d]*")
end

-- Keeps the child's streams instead of forwarding them, and answers nothing when the tool is not
-- on PATH.
local function capture(name: string, args: { string }): process.ExecResult?
    local ok, outcome = pcall(function()
        return process.exec(name, args)
    end)
    return if ok then outcome else nil
end

-- Every tool rokit.toml pins, mapped to the version it pins.
local function pinned(): { [string]: string }
    local manifest = Repo.decode("toml", Repo.ROKIT)
    local tools = if manifest ~= nil then manifest.tools else nil
    if typeof(tools) ~= "table" then return {} end
    local pins = {}
    for name, spec in tools :: { [string]: any } do
        if typeof(spec) == "string" then pins[name] = string.match(spec, "@(.+)$") end
    end
    return pins
end

-- Public --------------------------------------------------------------

-- Judged by exit code alone. A tool that is not on PATH fails rather than throws.
function Tools.run(name: string, args: { string }): Ruling
    local ok, outcome = pcall(process.exec, name, args, FORWARD)
    if not ok then return { ok = false, note = `{name} is not on PATH, run setup` } end
    return { ok = outcome.ok, note = if outcome.ok then nil else `{name} exited {outcome.code}` }
end

-- The package manager, under whichever of its names this platform can start.
function Tools.npm(args: { string }): Ruling
    return Tools.run(NPM, args)
end

-- The library alone, packaged as the model a release publishes. Rojo writes into a directory that
-- exists and makes none, so the build directory is made first.
function Tools.build(): Ruling
    local dir = string.match(Repo.MODEL, "^(.*)/") :: string
    if not Repo.exists(dir) then fs.writeDir(dir) end
    return Tools.run("rojo", { "build", Repo.PROJECT, "-o", Repo.MODEL })
end

-- Rewrites every authored tree in place, or judges it silently.
function Tools.format(mode: "write" | "check"): Ruling
    local args = if mode == "check" then { "--check" } else {}
    table.move(Repo.FORMATTED, 1, #Repo.FORMATTED, #args + 1, args)
    local outcome = Tools.run("stylua", args)
    if outcome.ok or mode == "write" then return outcome end
    return { ok = false, note = "formatting differs, run fmt" }
end

-- Type-checks one of the two analysis units: the trees against the Roblox definitions, and the
-- tooling against Lune's through the `@lune` alias.
function Tools.analyze(unit: "trees" | "tooling"): Ruling
    local args = if unit == "tooling"
        then { "analyze", "--platform=standard", SOLVER }
        else { "analyze", "--platform=roblox", `--definitions={Repo.DEFINITIONS}`, SOLVER }
    local targets = if unit == "tooling" then Repo.TOOLING else Repo.TREES
    table.move(targets, 1, #targets, #args + 1, args)
    return Tools.run("luau-lsp", args)
end

-- Brings a fresh machine up: rokit installs everything the manifest pins.
function Tools.install(): Ruling
    return Tools.run("rokit", { "install" })
end

-- Holds the machine to the manifest: every probed tool present, at the version it is pinned to.
-- Every problem is named, so one run reports them all.
function Tools.installed(): Ruling
    local pins = pinned()
    if next(pins) == nil then return { ok = false, note = `{Repo.ROKIT} declares no tools` } end

    local wrong = {}
    for _, name in PROBED do
        local pinned = pins[name]
        if pinned == nil then
            table.insert(wrong, `{name} is not pinned`)
            continue
        end
        local outcome = capture(name, { "--version" })
        if outcome == nil or not outcome.ok then
            table.insert(wrong, `{name} is not on PATH`)
            continue
        end
        local found = versionIn(outcome.stdout) or versionIn(outcome.stderr)
        if found ~= pinned then
            table.insert(wrong, `{name} is {found or "unreadable"}, pinned {pinned}`)
        end
    end
    if #wrong == 0 then return { ok = true } end
    return { ok = false, note = `{table.concat(wrong, ", ")}, run setup` }
end

return table.freeze(Tools)
