--!strict
-- Every path the tooling names, and the guarded reads that turn one into data.

local fs = require ("@lune/fs")
local serde = require ("@lune/serde")

local Repo = {}

-- Constants -----------------------------------------------------------

-- The five authored trees, which hold every line of Luau a person here writes.
Repo.SRC = "src"
Repo.TEST = "test"
Repo.BENCH = "bench"
Repo.FIXTURES = "fixtures"
Repo.SCRIPTS = "scripts"

-- Where a build puts what it makes and what it builds by default, none of it committed.
Repo.BUILD = "build"
Repo.STAGE = `{Repo.BUILD}/stage`
Repo.DIST = "dist"
Repo.DEFAULT = "default"

-- What a consumer is handed, and the manifests that say what they are being handed.
Repo.ROKIT = "rokit.toml"
Repo.WALLY = "wally.toml"
Repo.NPM = "package.json"
Repo.README = "README.md"
Repo.LICENSE = "LICENSE"
Repo.DTS = "index.d.ts"
Repo.SOURCEMAP = "sourcemap.json"

-- What the tools are told, more than one of which restates a path this module already names.
Repo.STYLUA = "stylua.toml"
Repo.LUAURC = ".luaurc"
Repo.SCRIPTS_LUAURC = `{Repo.SCRIPTS}/{Repo.LUAURC}`
Repo.RUN = `{Repo.SCRIPTS}/run.luau`
Repo.DARKLUA = ".darklua.json"
Repo.DARKLUA_RELEASE = ".darklua.release.json"
Repo.TASKS = ".vscode/tasks.json"
Repo.SETTINGS = ".vscode/settings.json"

--[[
    The two vendored type trees, neither authored here. `DEFINITIONS` reaches luau-lsp on the
    command line and is named again in the editor settings, so the two are compared and a rename in
    one cannot leave the other behind. `LUNE_TYPES` is reached only through the `@lune` alias, which
    is pinned the same way.
]]
Repo.DEFINITIONS = "typedefs/roblox.d.luau"
Repo.LUNE_TYPES = "typedefs/lune"

-- The files inside the trees that a gate names on their own.
Repo.ENTRY = `{Repo.SRC}/init.luau`
Repo.PROTOCOL = `{Repo.SRC}/wire/Protocol.luau`
Repo.EXPECT = `{Repo.TEST}/harness/Expect.luau`
Repo.DOUBLES = `{Repo.FIXTURES}/Doubles.luau`

--[[
    Format covers everything authored. Analysis splits in two because the trees resolve against the
    Roblox definitions and the tooling against Lune's.
]]
local FORMATTED = table.freeze ({ Repo.SRC, Repo.TEST, Repo.BENCH, Repo.FIXTURES, Repo.SCRIPTS })
local TREES = table.freeze ({ Repo.SRC, Repo.TEST, Repo.BENCH, Repo.FIXTURES })

--[[
    Projects in the order the sourcemap prefers them. The test place is the daily one and the editor
    maps against it, so it wins whenever it is whole.
]]
local MAPPABLE = table.freeze ({ Repo.TEST, Repo.BENCH, Repo.DEFAULT })

-- Private -------------------------------------------------------------

local function present (paths: { string }): { string }
    local found = {}
    for _, path in paths do
        if Repo.exists (path) then table.insert (found, path) end
    end
    return found
end

-- Public --------------------------------------------------------------

--[[
    fs.metadata reports exists = false for a missing path. A permission error propagates, because a
    repository the tooling cannot read is not a skip.
]]
function Repo.exists (path: string): boolean return fs.metadata (path).exists end

-- The file's text, or nil when it is absent.
function Repo.read (path: string): string?
    return if Repo.exists (path) then fs.readFile (path) else nil
end

--[[
    The file decoded to a table, or nil when it is absent or malformed. The one guarded read behind
    every manifest, config, and project the checks compare.
]]
function Repo.decode (format: serde.EncodeDecodeFormat, path: string): { [string]: any }?
    local text = Repo.read (path)
    if text == nil then return nil end
    local ok, decoded = pcall (serde.decode, format, text)
    return if ok and typeof (decoded) == "table" then decoded :: { [string]: any } else nil
end

-- The Rojo project file for a name, whether or not it exists.
function Repo.project (name: string): string return `{name}.project.json` end

function Repo.projectPath (name: string): string?
    local path = Repo.project (name)
    return if Repo.exists (path) then path else nil
end

function Repo.formatted (): { string } return present (FORMATTED) end

function Repo.trees (): { string } return present (TREES) end

-- Every $path a project declares, verbatim and in no particular order.
function Repo.paths (name: string): { string }
    local project = Repo.decode ("jsonc", Repo.project (name))
    if project == nil then return {} end

    local found = {}
    local function walk (node: { [string]: any })
        for key, value in node do
            if key == "$path" and typeof (value) == "string" then
                table.insert (found, value)
            elseif typeof (value) == "table" then
                walk (value)
            end
        end
    end
    walk (project)

    return found
end

--[[
    The distinct top-level directories a project mounts. These are the trees darklua converts before
    Rojo packages them, which is why they are the roots rather than the mounted paths themselves.
]]
function Repo.mounted (name: string): { string }
    local dirs, seen = {}, {}
    for _, path in Repo.paths (name) do
        local top = string.match (path, "^[^/]+") :: string
        if not seen[top] then
            seen[top] = true
            table.insert (dirs, top)
        end
    end
    return dirs
end

--[[
    The widest project every one of whose paths exists, or nil while none does. Rojo refuses a
    project that mounts a path it cannot find, so a half-built tree has to map against something
    narrower than the place it is heading for.
]]
function Repo.mappable (): string?
    for _, name in MAPPABLE do
        local paths = Repo.paths (name)
        if #paths > 0 then
            local whole = true
            for _, path in paths do
                if not Repo.exists (path) then
                    whole = false
                    break
                end
            end
            if whole then return name end
        end
    end
    return nil
end

-- A mounted directory's path inside the staging mirror.
function Repo.staged (path: string): string return `{Repo.STAGE}/{path}` end

--[[
    Where a project builds to. A DataModel root is a place and builds to .rbxl, anything else is a
    model and builds to .rbxm.
]]
function Repo.artifact (name: string): string
    local project = Repo.decode ("jsonc", Repo.project (name))
    local tree = if project ~= nil then project.tree else nil
    local isPlace = typeof (tree) == "table"
        and (tree :: { [string]: any })["$className"] == "DataModel"
    return `{Repo.BUILD}/{name}.{if isPlace then "rbxl" else "rbxm"}`
end

return table.freeze (Repo)
