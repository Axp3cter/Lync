--!strict
-- The two things about the tree no tool holds: the column, and the layer stack.

local Load = require("./Load")
local Repo = require("./Repo")
local Tools = require("./Tools")

local Checks = {}

-- The layer stack, as the set each layer may reach. It is not the reading order: codec may reach
-- kernel but never wire, and channel may reach wire but never codec, so an index comparison would
-- pass edges the table forbids. A require inside one layer is always legal.
local PERMITTED: { [string]: { [string]: boolean } } = {
    kernel = {},
    wire = { kernel = true },
    codec = { kernel = true },
    shape = { codec = true, wire = true, kernel = true },
    channel = { wire = true, kernel = true },
    state = { shape = true, channel = true, wire = true, kernel = true },
    runtime = { state = true, channel = true, shape = true, wire = true, kernel = true },
    api = {
        runtime = true,
        state = true,
        channel = true,
        shape = true,
        codec = true,
        wire = true,
        kernel = true,
    },
}

-- Private -------------------------------------------------------------

local function failure(faults: { string }): Tools.Ruling
    if #faults == 0 then return { ok = true } end
    return { ok = false, note = table.concat(faults, ", ") }
end

-- The layer a source path belongs to, or nothing for the entry module itself.
local function layerOf(path: string): string?
    return (string.match(path, `^{Repo.SRC}/([^/]+)/`))
end

-- Public --------------------------------------------------------------

-- Every authored line inside the formatter's column, read from the formatter's own configuration
-- so the number keeps one home. StyLua wraps code to it and leaves comments alone, so a comment is
-- the one line in a Luau file that can outgrow the width with the formatter reporting nothing.
function Checks.width(): Tools.Ruling
    local config = Repo.decode("toml", Repo.STYLUA)
    local column = if config ~= nil then config.column_width else nil
    if typeof(column) ~= "number" then
        return { ok = false, note = `{Repo.STYLUA} declares no column width` }
    end

    local wrong = {}
    for _, dir in Repo.FORMATTED do
        for _, path in Repo.walk(dir) do
            for number, line in Repo.lines(Repo.read(path) :: string) do
                if #line > column then table.insert(wrong, `{path}:{number} runs to {#line}`) end
            end
        end
    end
    return failure(wrong)
end

-- Every require in src resolved to its layer and held to the permitted set. An edge that climbs
-- or crosses names both ends, so the fix is unambiguous.
function Checks.edges(): Tools.Ruling
    local wrong = {}
    for _, path in Repo.walk(Repo.SRC) do
        local from = layerOf(path)
        if from == nil then continue end
        for required in string.gmatch(Repo.read(path) :: string, 'require%s*%("([^"]+)"%)') do
            local to = layerOf(Load.where(path, required))
            if to ~= nil and to ~= from and PERMITTED[from][to] == nil then
                table.insert(wrong, `{path} reaches {to}`)
            end
        end
    end
    return failure(wrong)
end

return table.freeze(Checks)
