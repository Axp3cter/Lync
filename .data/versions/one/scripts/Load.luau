--!strict
-- One loader for every Lune runner: src, fixtures, test and bench modules through one resolver
-- and one environment, so a module reads the same under Lune as it does under Studio.

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")
local task = require("@lune/task")

local Load = {}

-- The require aliases, read from their one home.
local ALIASES: { [string]: string } = serde.decode("json", fs.readFile(".luaurc")).aliases

-- The one service the library reads, standing in for the shared clock.
local WORKSPACE = table.freeze({
    GetServerTimeNow = function(_: any): number
        return os.clock()
    end,
})

-- Every module loaded here shares one environment shape: Lune's globals, `task` and the Roblox
-- datatypes as Studio has them, and a require that resolves aliases and relative paths against
-- the requiring file. The datatypes are read untyped since the Lune definitions do not list them.
local loaded: { [string]: any } = {}
local datatypes: { [string]: any } = roblox :: any

-- The directory a file's own paths resolve against. An init.luau is its folder, so its `./` is
-- the folder's parent and `@self` is the folder itself, as Roblox and luau-lsp resolve them.
local function dirname(file: string): string
    return string.match(file, "^(.*)/[^/]*$") or "."
end

local function home(file: string): string
    local dir = dirname(file)
    return if string.match(file, "/init%.luau$") ~= nil then dirname(dir) else dir
end

local function normalize(path: string): string
    local parts = {}
    for part in string.gmatch(path, "[^/]+") do
        if part == ".." then
            table.remove(parts)
        elseif part ~= "." then
            table.insert(parts, part)
        end
    end
    return table.concat(parts, "/")
end

-- The path a require names, without its extension, resolved against the requiring file.
function Load.where(from: string, path: string): string
    local alias, rest = string.match(path, "^@([%w_]+)/?(.*)$")
    local base = if alias == "self"
        then `{dirname(from)}/{rest}`
        elseif alias ~= nil then `{assert(ALIASES[alias], `no alias @{alias} in .luaurc`)}/{rest}`
        else `{home(from)}/{path}`
    return normalize(base)
end

local function resolve(from: string, path: string): string
    local base = Load.where(from, path)
    if fs.isFile(`{base}.luau`) then return `{base}.luau` end
    if fs.isFile(`{base}/init.luau`) then return `{base}/init.luau` end
    error(`{from} requires {path}, and neither {base}.luau nor {base}/init.luau exists`, 0)
end

-- The module at a path relative to the repository root, loaded once and shared.
function Load.file(file: string): any
    local held = loaded[file]
    if held ~= nil then return held end

    local chunk = luau.load(fs.readFile(file), {
        debugName = file,
        environment = {
            task = task,
            Vector2 = datatypes.Vector2,
            Vector3 = datatypes.Vector3,
            CFrame = datatypes.CFrame,
            Color3 = datatypes.Color3,
            Instance = datatypes.Instance,
            workspace = WORKSPACE,
            require = function(path: string): any
                return Load.file(resolve(file, path))
            end,
        },
    })
    local result = chunk()
    loaded[file] = result
    return result
end

-- Every module directly under a directory, in name order, as the values they return.
function Load.directory(dir: string): { any }
    local files = fs.readDir(dir)
    table.sort(files)
    local out = {}
    for _, file in files do
        if string.match(file, "%.luau$") ~= nil then
            table.insert(out, Load.file(`{dir}/{file}`))
        end
    end
    return out
end

return table.freeze(Load)
