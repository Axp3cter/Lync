--!strict
-- What the toolchain produces: the sourcemap, the converted mirror, the places, and the package.

local fs = require ("@lune/fs")
local serde = require ("@lune/serde")

local Repo = require ("./Repo")
local Ruling = require ("./Ruling")
local TEMP = require ("./TEMP_IntegerLiterals")
local Tools = require ("./Tools")

local Build = {}

-- Constants -----------------------------------------------------------

-- What the tree's own manifest says and the assembled one must not, spelled as it is written.
local PRIVATE = '"private": true,'

-- What a line of it ends on, spelled rather than escaped so nothing on the way to here eats it.
local LINES = string.char (10)

-- What a project mounts a data file as, and what darklua leaves in the staged tree instead.
local DATA = ".json"
local CONVERTED = ".lua"

-- Private -------------------------------------------------------------

-- Empties a directory to a known state, creating it when it is absent.
local function clear (path: string)
    if Repo.exists (path) then fs.removeDir (path) end
    fs.writeDir (path)
end

--[[
    Rewrites a tree's string requires into Roblox requires. The default config is the development
    build, and dist passes the release one to fold the __DEV__ branches away as well.
]]
local function convert (input: string, output: string, config: string?): Ruling.Ruling
    local args = { "process", input, output }
    if config ~= nil then
        table.insert (args, "-c")
        table.insert (args, config)
    end

    local masked = TEMP.hide ({ input })
    local outcome = Tools.run ("darklua", args)
    TEMP.show (masked)
    if outcome.ok then TEMP.reveal (output) end
    return outcome
end

-- Public --------------------------------------------------------------

--[[
    Regenerates the committed sourcemap, from the named project or from the widest one that can be
    mapped. darklua resolves every converted require through it. A tree too bare for any project to
    map is not a failure, only a repository with nothing yet to resolve.
]]
function Build.sourcemap (name: string?): Ruling.Ruling
    local wanted = name or Repo.mappable ()
    if wanted == nil then return { ok = true } end

    local project = Repo.projectPath (wanted)
    if project == nil then return { ok = false, note = `no {Repo.project (wanted)}` } end
    return Tools.run ("rojo", { "sourcemap", project, "-o", Repo.SOURCEMAP })
end

--[[
    Every path a project names, so one written against the tree as authored can be read against
    the tree as staged. Walked rather than matched on a key, since a path can stand wherever a
    node does.
]]
local function paths (node: any, out: { { [string]: any } })
    if typeof (node) ~= "table" then return end
    if typeof (node["$path"]) == "string" then table.insert (out, node) end

    for key, held in node do
        if string.sub (key, 1, 1) ~= "$" then paths (held, out) end
    end
end

--[[
    The staged project, describing what was staged. darklua rewrites a data file the project mounts
    into a module returning it and names that with the older Lua suffix, so a path left as authored
    names a file the staged tree does not have. Only a name darklua moved is rewritten, and only
    where what it moved it to is there.
]]
local function described (project: string)
    local held = Repo.decode ("json", project)
    if held == nil then return end

    local found: { { [string]: any } } = {}
    paths (held.tree, found)

    for _, node in found do
        local path = node["$path"] :: string
        if Repo.exists (Repo.staged (path)) then continue end

        local instead = `{string.sub (path, 1, -#DATA - 1)}{CONVERTED}`
        if string.sub (path, -#DATA) ~= DATA or not Repo.exists (Repo.staged (instead)) then
            continue
        end
        node["$path"] = instead
    end

    fs.writeFile (Repo.staged (project), serde.encode ("json", held, true))
end

--[[
    Converts every tree a project mounts into build/stage and writes the project file beside them,
    so Rojo packages Roblox requires rather than the string aliases Studio rejects. The sourcemap is
    left describing the project that was staged, because the watchers serve reconverts through must
    keep reading the instance paths of the place they are serving.
]]
function Build.stage (name: string, config: string?): Ruling.Ruling
    local project = Repo.projectPath (name)
    if project == nil then return { ok = false, note = `no {Repo.project (name)}` } end

    local mapped = Build.sourcemap (name)
    if not mapped.ok then return mapped end

    clear (Repo.STAGE)
    for _, dir in Repo.mounted (name) do
        local converted = convert (dir, Repo.staged (dir), config)
        if not converted.ok then return { ok = false, note = `darklua failed on {dir}` } end
    end
    fs.copy (project, Repo.staged (project))
    described (project)

    return { ok = true }
end

--[[
    Packages a staged project into build/, a place or a model by its root class. A caller naming a
    config gets the tree that config converts, which is how the model that ships is the release one
    where the places that run the suite and the bench are the development one.
]]
function Build.place (name: string, config: string?): Ruling.Ruling
    local staged = Build.stage (name, config)
    if not staged.ok then return staged end

    local output = Repo.artifact (name)
    return Tools.run ("rojo", { "build", Repo.staged (Repo.project (name)), "-o", output })
end

--[[
    Assembles the publishable dist: the release-converted library beside the two manifests, the
    declaration, and the files a registry page renders from. Both registries publish this directory,
    never the source tree.
]]
function Build.dist (): Ruling.Ruling
    local mapped = Build.sourcemap (Repo.DEFAULT)
    if not mapped.ok then return mapped end

    clear (Repo.DIST)
    local converted = convert (Repo.SRC, Repo.DIST, Repo.DARKLUA_RELEASE)
    if not converted.ok then return { ok = false, note = `darklua failed on {Repo.SRC}` } end

    for _, file in { Repo.WALLY, Repo.DTS, Repo.README, Repo.LICENSE } do
        if not Repo.exists (file) then return { ok = false, note = `{file} is missing` } end
        fs.copy (file, `{Repo.DIST}/{file}`)
    end

    --[[
        The npm manifest written rather than copied, because the one in the tree says it is private
        and this one may not be. What that buys is a publish run from the wrong directory being
        refused by npm instead of shipping every file the tree holds, which is a mistake that has
        already been made once and cannot be taken back.
    ]]
    local manifest = Repo.read (Repo.NPM)
    if manifest == nil then return { ok = false, note = `{Repo.NPM} is missing` } end

    local kept = {}
    local dropped = 0

    for _, line in string.split (manifest, LINES) do
        if string.find (line, PRIVATE, 1, true) ~= nil then
            dropped += 1
            continue
        end
        table.insert (kept, line)
    end

    if dropped ~= 1 then return { ok = false, note = `{Repo.NPM} does not say {PRIVATE} once` } end

    fs.writeFile (`{Repo.DIST}/{Repo.NPM}`, table.concat (kept, LINES))
    return { ok = true }
end

--[[
    Serves a staged project to Studio and reconverts as sources change, so an edit reaches the place
    without a rebuild. Blocks until Rojo exits, then stops every watcher it started. Adding or
    renaming a file moves instance paths, so the sourcemap only refreshes on the next serve.
]]
function Build.serve (name: string): Ruling.Ruling
    local staged = Build.stage (name)
    if not staged.ok then return staged end

    local watchers = {}
    for _, dir in Repo.mounted (name) do
        table.insert (
            watchers,
            Tools.watch ("darklua", { "process", "--watch", dir, Repo.staged (dir) })
        )
    end

    local served = Tools.run ("rojo", { "serve", Repo.staged (Repo.project (name)) })
    for _, watcher in watchers do
        watcher:kill ()
    end
    return served
end

return table.freeze (Build)
