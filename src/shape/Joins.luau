--!strict
--!optimize 2
-- One declaration as the leaves it takes in a bit region and the join that fills them.

local Base = require ("@src/codec/Base")
local Grid = require ("@src/shape/Grid")
local Ir = require ("@src/shape/Ir")
local Scalars = require ("@src/codec/Scalars")

local Joins = {}

-- Types ---------------------------------------------------------------

--[[
    What a region field comes to: the grids it occupies, in wire order, and the join that says where
    they are and how a value gets in and out of them.
]]
export type Field = {
    read leaves: { Grid.Grid },
    read join: Ir.Join,
}

-- Public --------------------------------------------------------------

-- The one grid a declaration indexes through, where it has one.
function Joins.grid (of: Base.Cell): Grid.Grid?
    local kind, params = of.kind, of.params

    if kind == "bool" then return Grid.flag () end
    if kind == "int" then return Grid.of (params.min :: number, params.max :: number, 1) end
    if kind == "quant" then
        return Grid.of (params.min :: number, params.max :: number, params.step :: number)
    end

    if kind == "angle" then
        --[[
            A step short of a turn, since the wrap makes the top point and the bottom the same one,
            and cyclic so a reading is folded into the range rather than clamped to either end.
        ]]
        local step = params.step :: number
        return Grid.of (0, Scalars.TURN - step, step, true)
    end

    if kind == "enum" then return Grid.named (params.names :: { string }) end
    return nil
end

-- The leaves a declaration takes, where its value is one the language carries.
function Joins.leaves (of: Base.Cell): { Grid.Grid }?
    local single = Joins.grid (of)
    if single ~= nil then return { single } end
    if of.kind ~= "bitfield" then return nil end

    local names = of.params.names :: { string }
    local reach = #names

    local out = table.create (reach) :: { Grid.Grid }
    for place = 1, reach do
        out[place] = Grid.flag ()
    end
    return out
end

-- A declaration, at the leaf it starts on, as the field it becomes.
function Joins.of (of: Base.Cell, tag: Ir.Tag, at: number, key: string?, nest: number?): Field?
    local leaves = Joins.leaves (of)
    if leaves == nil then return nil end

    if of.kind ~= "bitfield" then
        return {
            leaves = leaves,
            join = { at = at, count = 1, key = key, nest = nest, tag = tag },
        }
    end

    --[[
        A bitfield's pair reads and writes by name rather than by position, so the leaves are its
        names in the order the cell records them and nothing about the record's own key order
        reaches the wire. A name a record does not carry is not there, which is what a truth of
        false already means, and a value that is no record has no name to read at all.
    ]]
    local names = of.params.names :: { string }
    local reach = #names

    --[[
        The record a reading comes back as, with every name already on it. A bitfield answers a
        table of names and nothing else, so the shape of that table is the same one every time and
        a copy of it arrives sized where one built name by name grows into its keys.
    ]]
    local blank = {}
    for _, name in names do
        blank[name] = false
    end

    table.freeze (blank)

    local function pull (value: any, into: { number }, opens: number): boolean
        if type (value) ~= "table" then return false end

        local names = names

        --[[
            A name it does carry has to carry a truth. A flag is a `bool` declared n at a time and
            `bool` turns away everything that is not one, so asking only whether the value is truthy
            would let `{ dead = "no" }` write that the thing is dead. The whole field goes rather
            than the flag, because a bitfield's twentieth bit is still the bitfield.
        ]]
        local at = opens
        for place = 1, reach do
            local held = value[names[place]]

            if held == false or held == nil then
                into[at] = 0
            elseif held == true then
                into[at] = 1
            else
                return false
            end

            at += 1
        end
        return true
    end

    local function push (from: { number }, opens: number): any
        local names, out = names, table.clone (blank) :: { [string]: boolean }

        --[[
            Only the flags that are set are laid down. The copy already carries every name against
            a false, so writing one there is writing what is already under it, and a field of flags
            is mostly false in the places that declare one.
        ]]
        local at = opens
        for place = 1, reach do
            if from[at] == 1 then out[names[place]] = true end
            at += 1
        end
        return out
    end

    return {
        leaves = leaves,
        join = {
            at = at,
            count = reach,
            key = key,
            nest = nest,
            tag = tag,
            pull = pull,
            push = push,
        },
    }
end

return table.freeze (Joins)
