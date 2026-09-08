--!strict
-- Every path the tooling names, and the guarded reads that turn one into data.

local fs = require("@lune/fs")
local serde = require("@lune/serde")

local Repo = {}

-- The authored trees, which hold every line of Luau a person here writes.
Repo.SRC = "src"
Repo.TEST = "test"
Repo.BENCH = "bench"
Repo.FIXTURES = "fixtures"
Repo.SCRIPTS = "scripts"

-- The manifests and configs the tools are told.
Repo.ROKIT = "rokit.toml"
Repo.STYLUA = "stylua.toml"

-- The project that mounts the library alone, and the model a release builds from it.
Repo.PROJECT = "default.project.json"
Repo.MODEL = "build/Lync.rbxm"

-- The declaration and the throwaway consumer project the roblox-ts compiler is pointed at.
Repo.DECLARATION = "index.d.ts"
Repo.MANIFEST = "package.json"
Repo.SURFACE = "test/Declaration.ts"
Repo.GATE = "build/rbxts"

-- The vendored Roblox definitions the trees resolve against. The Lune ones are reached through the
-- `@lune` alias .luaurc declares.
Repo.DEFINITIONS = "typedefs/roblox.d.luau"

-- The two Lune entry points, which analyze with the tooling rather than with the trees they sit in.
Repo.TEST_RUNNER = `{Repo.TEST}/run.luau`
Repo.BENCH_RUNNER = `{Repo.BENCH}/run.luau`

-- Format covers everything authored. Analysis splits in two because the trees resolve against the
-- Roblox definitions and the tooling against Lune's.
Repo.FORMATTED = table.freeze({ Repo.SRC, Repo.TEST, Repo.BENCH, Repo.FIXTURES, Repo.SCRIPTS })
Repo.TREES = table.freeze({
    Repo.SRC,
    Repo.FIXTURES,
    `{Repo.TEST}/harness`,
    `{Repo.TEST}/units`,
    `{Repo.TEST}/rules`,
    `{Repo.TEST}/wire`,
    `{Repo.BENCH}/harness`,
    `{Repo.BENCH}/suite`,
})
Repo.TOOLING = table.freeze({ Repo.SCRIPTS, Repo.TEST_RUNNER, Repo.BENCH_RUNNER })

-- Public --------------------------------------------------------------

-- A missing path reads as absent. A permission error propagates, since a repository the tooling
-- cannot read is not a skip.
function Repo.exists(path: string): boolean
    return fs.metadata(path).exists
end

-- The file's text, or nothing when it is absent.
function Repo.read(path: string): string?
    return if Repo.exists(path) then fs.readFile(path) else nil
end

-- The file decoded to a table, or nothing when it is absent or malformed.
function Repo.decode(format: serde.EncodeDecodeFormat, path: string): { [string]: any }?
    local text = Repo.read(path)
    if text == nil then return nil end
    local ok, decoded = pcall(serde.decode, format, text)
    return if ok and typeof(decoded) == "table" then decoded :: { [string]: any } else nil
end

-- Every Luau file under a directory, depth first.
function Repo.walk(dir: string): { string }
    local found = {}
    if not Repo.exists(dir) then return found end
    for _, entry in fs.readDir(dir) do
        local path = `{dir}/{entry}`
        if fs.isDir(path) then
            local nested = Repo.walk(path)
            table.move(nested, 1, #nested, #found + 1, found)
        elseif string.match(entry, "%.luau$") ~= nil then
            table.insert(found, path)
        end
    end
    return found
end

-- Every line of a text, so a fault can name the line it sits on.
function Repo.lines(text: string): { string }
    local found = {}
    for line in string.gmatch(`{text}\n`, "([^\n]*)\n") do
        table.insert(found, line)
    end
    return found
end

return table.freeze(Repo)
