--!strict
--[[
    TEMPORARY. DELETE THIS MODULE when full_moon parses integer literals. Luau accepts `64i` and
    full_moon does not, and StyLua and darklua both pin that crate, so the first such literal breaks
    the format gate and the package build at once. Nothing carries one yet.
]]

local fs = require ("@lune/fs")

local TEMP = {}

--[[
    Every literal form Luau suffixes: decimal, hex, and binary, separators included. Lowercase only,
    because `64I` is a malformed number to Luau and masking it would hide that from the analyzer.
]]
local FORMS = table.freeze ({
    "%f[%w]0[xX][%x_]+i%f[%W]",
    "%f[%w]0[bB][01_]+i%f[%W]",
    "%f[%w]%d[%d_]*i%f[%W]",
})

-- Private -------------------------------------------------------------

-- Every .luau file under a directory, depth first.
local function walk (dir: string): { string }
    local found = {}
    if not fs.isDir (dir) then return found end

    for _, entry in fs.readDir (dir) do
        local path = `{dir}/{entry}`
        if fs.isDir (path) then
            local nested = walk (path)
            table.move (nested, 1, #nested, #found + 1, found)
        elseif string.match (entry, "%.luau$") ~= nil then
            table.insert (found, path)
        end
    end
    return found
end

local function rewrite (path: string, apply: (string) -> string): boolean
    local source = fs.readFile (path)
    local rewritten = apply (source)
    if rewritten == source then return false end
    fs.writeFile (path, rewritten)
    return true
end

-- Public --------------------------------------------------------------

function TEMP.mask (source: string): string
    local masked = source
    for _, form in FORMS do
        masked = string.gsub (
            masked,
            form,
            function (literal: string): string return `_i({string.sub (literal, 1, -2)})` end
        )
    end
    return masked
end

function TEMP.unmask (source: string): string
    return (string.gsub (source, "_i%s*%(([%w_]+)%)", "%1i"))
end

--[[
    Masks every tree in place and answers the files it changed. Unmasking first repairs a tree an
    interrupted run left masked, which is why `_i` is reserved.
]]
function TEMP.hide (dirs: { string }): { string }
    local function masked (source: string): string return TEMP.mask (TEMP.unmask (source)) end

    local touched = {}
    for _, dir in dirs do
        for _, path in walk (dir) do
            if rewrite (path, masked) then table.insert (touched, path) end
        end
    end
    return touched
end

function TEMP.show (paths: { string })
    for _, path in paths do
        rewrite (path, TEMP.unmask)
    end
end

-- Puts every suffix back in a tree a tool has just written.
function TEMP.reveal (dir: string)
    for _, path in walk (dir) do
        rewrite (path, TEMP.unmask)
    end
end

--[[
    To remove: delete this file, delete the five TEMP calls in Tools.format and Build.convert, and
    drop the require from each. Nothing else moves.
]]
return table.freeze (TEMP)
