--!strict
--!optimize 2
-- Which of the four regions every field of a record is written in, and in what order.

local Base = require ("@src/codec/Base")
local Folds = require ("@src/shape/Folds")
local Grid = require ("@src/shape/Grid")
local Joins = require ("@src/shape/Joins")
local Order = require ("@src/shape/Order")
local Protocol = require ("@src/wire/Protocol")

local Regions = {}

-- Constants -----------------------------------------------------------

-- The widest a leaf can be and still flow with its neighbours rather than take whole bytes.
const CEILING = Protocol.BIT_CEILING

-- Types ---------------------------------------------------------------

-- One field, at the path it is reached by from the record being partitioned.
export type Entry = {
    read at: { string },
    read of: Base.Cell,
}

-- The four regions, each in the order it is written, and the records that dissolved on the way.
export type Split = {
    read presence: { Entry },
    read bits: { Entry },
    read bytes: { Entry },
    read vars: { Entry },
    read nests: { Entry },
}

-- Private -------------------------------------------------------------

-- The leaves a declaration takes where it is a region field, and nothing where it is not.
local function held (of: Base.Cell): { Grid.Grid }?
    local named = Joins.leaves (of)
    if named ~= nil then return named end

    local fold = Folds.fold (of)
    return if fold == nil then nil else fold.leaves
end

-- Every field of a record into the region it is written in, and the fixed records under it too.
local function walk (of: { [string]: Base.Cell }, at: { string }, into: Split)
    for _, name in Order.names (of) do
        local child = of[name]

        local path = table.clone (at)
        table.insert (path, name)

        local entry: Entry = table.freeze ({ at = table.freeze (path), of = child })

        --[[
            Both lists, because the two ask different things. A presence bit says whether the field
            is there at all, and the value behind it is still one whose width is not known ahead.
        ]]
        if child.kind == "optional" then
            table.insert (into.presence, entry)
            table.insert (into.vars, entry)
            continue
        end

        if Order.varies (child) then
            table.insert (into.vars, entry)
            continue
        end

        if child.kind == "struct" then
            table.insert (into.nests, entry)
            walk (child.children :: { [string]: Base.Cell }, path, into)
            continue
        end

        if Regions.packs (child) then
            table.insert (into.bits, entry)
            continue
        end

        table.insert (into.bytes, entry)
    end
end

-- Public --------------------------------------------------------------

-- Whether a declaration flows in a bit run, which is one question asked of every leaf it takes.
function Regions.packs (of: Base.Cell): boolean
    local leaves = held (of)
    if leaves == nil then return false end

    for _, grid in leaves do
        if grid.width > CEILING then return false end
    end
    return true
end

function Regions.of (of: { [string]: Base.Cell }): Split
    local into: Split = { presence = {}, bits = {}, bytes = {}, vars = {}, nests = {} }
    walk (of, {}, into)

    table.freeze (into.presence)
    table.freeze (into.bits)
    table.freeze (into.bytes)
    table.freeze (into.vars)
    table.freeze (into.nests)
    return table.freeze (into)
end

return table.freeze (Regions)
