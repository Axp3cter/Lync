--!strict
-- A place served to Studio as data rather than synced into it.

local fs = require ("@lune/fs")
local net = require ("@lune/net")
local serde = require ("@lune/serde")
local stdio = require ("@lune/stdio")
local task = require ("@lune/task")

local Repo = require ("./Repo")
local Ruling = require ("./Ruling")

local Place = {}

-- Constants -----------------------------------------------------------

Place.PORT = 8770
Place.ROUTE = "/tree.json"

--[[
    What a file becomes, read off the end of its name the way the project file's own reader does.
    A data file is here as `.lua` because that is what it is by the time this walks: darklua turns
    a project's JSON into a module returning it, and names what it wrote with the older suffix.
]]
local KINDS = {
    { tail = ".server.luau", class = "Script" },
    { tail = ".client.luau", class = "LocalScript" },
    { tail = ".luau", class = "ModuleScript" },
    { tail = ".lua", class = "ModuleScript" },
}

local OPENS = "init.luau"

-- How long the serving command sleeps at a time, which is all it does once it is serving.
local PATIENCE = 60

--[[
    The builder, printed for whoever is holding Studio. A node carrying no class is one the project
    implied rather than declared, so it is made as a folder where it is missing and never torn down.
    Everything else is ours and one already standing under that name is torn down first, so a
    second run is a replacement rather than a tree growing beside the old one.
]]
local BUILDER = [[
local http = game:GetService ("HttpService")
for _, node in http:JSONDecode (http:GetAsync ("http://127.0.0.1:%d%s")) do
    local names = string.split (node.at, "/")
    local held = game:GetService (names[1])
    for at = 2, #names - 1 do
        held = held:FindFirstChild (names[at])
    end

    if #names > 1 then
        local name = names[#names]
        local was = held:FindFirstChild (name)

        if node.class == nil then
            if was == nil then
                local made = Instance.new ("Folder")
                made.Name, made.Parent = name, held
            end
        else
            if was ~= nil then was:Destroy () end
            local made = Instance.new (node.class)
            made.Name = name
            if node.source ~= nil then made.Source = node.source end
            made.Parent = held
        end
    end
end
]]

-- Types ---------------------------------------------------------------

--[[
    One instance, as the path it sits at, what to make it and what to put in it.

    `class` is nothing for a node the project implied by nesting rather than declared, and `source`
    is nothing for anything that is not a script.
]]
export type Node = {
    at: string,
    class: string?,
    source: string?,
}

-- Private -------------------------------------------------------------

-- The name a file carries in a place and the class it becomes, or nothing where it becomes neither.
local function named (file: string): (string?, string?)
    for _, kind in KINDS do
        if string.sub (file, -#kind.tail) == kind.tail then
            return string.sub (file, 1, -#kind.tail - 1), kind.class
        end
    end
    return nil, nil
end

--[[
    One directory as the instance it is, and everything under it.

    A directory holding an `init.luau` is that module with the rest of the directory hanging off it,
    which is the one rule that makes a folder and a module the same thing to a reader.
]]
local function walked (where: string, at: string, out: { Node })
    local opens = `{where}/{OPENS}`
    if Repo.exists (opens) then
        table.insert (out, { at = at, class = "ModuleScript", source = fs.readFile (opens) })
    else
        table.insert (out, { at = at, class = "Folder" })
    end

    local entries = fs.readDir (where)
    table.sort (entries)

    for _, entry in entries do
        if entry == OPENS then continue end

        local path = `{where}/{entry}`
        if fs.isDir (path) then
            walked (path, `{at}/{entry}`, out)
            continue
        end

        local name, class = named (entry)
        if class == nil then continue end
        table.insert (out, { at = `{at}/{name}`, class = class, source = fs.readFile (path) })
    end
end

-- One entry of the project file, and whatever it says is under it.
local function spread (node: { [string]: any }, at: string, out: { Node })
    local path = node["$path"]
    if typeof (path) == "string" then
        local where = Repo.staged (path)
        if fs.isDir (where) then
            walked (where, at, out)
            return
        end

        local _, class = named (where)
        table.insert (
            out,
            { at = at, class = class or "ModuleScript", source = fs.readFile (where) }
        )
        return
    end

    table.insert (out, { at = at, class = node["$className"] })

    local names = {}
    for name in node do
        if string.sub (name, 1, 1) ~= "$" then table.insert (names, name) end
    end
    table.sort (names)

    for _, name in names do
        spread (node[name], `{at}/{name}`, out)
    end
end

-- Public --------------------------------------------------------------

--[[
    Every instance a project declares, parents first, read off the staged tree.

    The DataModel is the place that is already open, so its own line is not one to make, and every
    name directly under it is a service the builder reaches for rather than creates.
]]
function Place.tree (name: string): { Node }
    local project = Repo.decode ("json", Repo.staged (Repo.project (name)))
    if project == nil then return {} end

    local services = {}
    for held in project.tree do
        if string.sub (held, 1, 1) ~= "$" then table.insert (services, held) end
    end
    table.sort (services)

    local out: { Node } = {}
    for _, held in services do
        spread (project.tree[held], held, out)
    end
    return out
end

-- The tree on a local port, and the lines a person pastes into Studio to build it.
function Place.serve (name: string): Ruling.Ruling
    local nodes = Place.tree (name)
    if #nodes == 0 then return { ok = false, note = `{Repo.project (name)} declares no tree` } end

    local held = serde.encode ("json", nodes)
    local where = `http://127.0.0.1:{Place.PORT}{Place.ROUTE}`

    local line = "paste this into the Studio command bar, then press Play:"
    stdio.write (`{#nodes} nodes, {#held} bytes on {where}\n{line}\n`)
    stdio.write (string.format (BUILDER, Place.PORT, Place.ROUTE))

    local headers: { [string]: string } = { ["Content-Type"] = "application/json" }
    local answer: net.ServeResponse = { status = 200, headers = headers, body = held }
    net.serve (Place.PORT, function () return answer end)

    -- Serving is the command rather than a step before one, so this comes back only on a signal.
    while true do
        task.wait (PATIENCE)
    end
end

return table.freeze (Place)
