--!strict
--!optimize 2
-- What the canonical ordering decides: the order of names, and which fields vary.

local Base = require ("@src/codec/Base")

local Order = {}

-- Constants -----------------------------------------------------------

-- The kinds that vary whatever they are made of.
const ALWAYS = table.freeze ({
    vlq = true,
    vli = true,
    tagged = true,
    optional = true,
    inst = true,
}) :: { [string]: boolean }

-- The kinds that carry a count, which vary exactly when the two ends of that count differ.
const COUNTED = table.freeze ({
    str = true,
    buffer = true,
    array = true,
    map = true,
}) :: { [string]: boolean }

-- Public --------------------------------------------------------------

-- The names a declaration carries, in the one order two machines can both arrive at.
function Order.names <V>(of: { [string]: V }): { string }
    local out: { string } = {}
    for name in of do
        table.insert (out, name)
    end

    table.sort (out)
    return out
end

--[[
    Whether a declaration's size depends on the value it carries, which is what decides the region a
    field is written in and nothing else.
]]
function Order.varies (of: Base.Cell): boolean
    local kind = of.kind
    if ALWAYS[kind] then return true end

    if COUNTED[kind] then
        local params = of.params
        if params.min ~= params.max then return true end
    end

    local children = of.children
    if children == nil then return false end

    for _, child in children do
        if Order.varies (child) then return true end
    end

    return false
end

return table.freeze (Order)
