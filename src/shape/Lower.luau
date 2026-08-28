--!strict
--!optimize 2
-- A codec tree as the nodes the emitter writes, which is the whole of what a schema decides.

local Base = require ("@src/codec/Base")
local Folds = require ("@src/shape/Folds")
local Grid = require ("@src/shape/Grid")
local Ir = require ("@src/shape/Ir")
local Joins = require ("@src/shape/Joins")
local Order = require ("@src/shape/Order")
local Regions = require ("@src/shape/Regions")
local Serial = require ("@src/shape/Serial")
local Words = require ("@src/shape/Words")

local Lower = {}

-- Constants -----------------------------------------------------------

--[[
    The names a value in parts is read off, in the order they are written.

    Cloned at every use rather than handed over, because the constructor freezes the array it is
    given and a second freeze on a frozen table raises. What is shared is the reading of them.
]]
const PLANE = table.freeze ({ "X", "Y" })
const SPACE = table.freeze ({ "X", "Y", "Z" })
const LIGHT = table.freeze ({ "R", "G", "B" })
const FRAME = table.freeze ({ "Position", "Rotation" })

-- The third of the three a vector and a colour are each read off.
const THIRD = #SPACE

-- Types ---------------------------------------------------------------

--[[
    The two tables a walk interns into, which is everything a lowering needs that is not the
    declaration it is on. A record rather than two arguments, because the walk is recursive and the
    pair travels together to every node of a tree.
]]
export type Site = {
    read paths: Serial.Interner,
    read expected: Serial.Interner,
}

-- Private -------------------------------------------------------------

-- Where a declaration is and what it wanted, with the caller's own checks where there are any.
local function tagged (of: Base.Cell, at: string, site: Site): Ir.Tag
    local pathId, expectId = Serial.tagged (site.paths, site.expected, at, of)
    local checks = of.validates

    return table.freeze ({
        pathId = pathId,
        expectId = expectId,
        checks = if #checks == 0 then nil else checks,
    })
end

-- The same place, for the nodes under the one the checks are on and for the bits that are no node.
local function plain (of: Base.Cell, at: string, site: Site): Ir.Tag
    local pathId, expectId = Serial.tagged (site.paths, site.expected, at, of)
    return table.freeze ({ pathId = pathId, expectId = expectId })
end

local function counted (of: Base.Params): Ir.Span
    return { min = of.min :: number, max = of.max :: number }
end

-- Where a field is, spelled from where the record holding it is, one dissolved name at a time.
local function pathed (at: string, path: { string }): string
    local out = at
    for _, name in path do
        out = Serial.under (out, name)
    end
    return out
end

-- The same, as the one string a table of them can be keyed by.
local function spelled (path: { string }, deep: number): string
    return table.concat (path, ".", 1, deep)
end

-- Whether a field is there, which is the whole of what a presence bit is filled from.
local function there (value: any, into: { number }, at: number): boolean
    into[at] = if value == nil then 0 else 1
    return true
end

-- A presence join gives nothing back, since the bit says only whether the field came.
local function nothing (): any return nil end

local function planar (from: { any }): any return Vector2.new (from[1], from[2]) end

local function spatial (from: { any }): any return Vector3.new (from[1], from[2], from[THIRD]) end

local function lit (from: { any }): any return Color3.new (from[1], from[2], from[THIRD]) end

--[[
    A frame from its two halves, which is a turn moved to where it sits. The rotation comes back as
    a frame at the origin and adding a vector to a frame is the translation the position is written
    as, so there is nothing to compose here that the engine does not.
]]
local function framed (from: { any }): any return from[2] + from[1] end

-- A declaration whose value is one bit run, as the region it is on its own.
local function worded (of: Base.Cell, at: string, site: Site, tag: Ir.Tag): Ir.Word
    local held = plain (of, at, site)

    local made = Joins.of (of, held, 1, nil)
    if made == nil then made = Folds.of (of, held, 1, nil) end

    local field = made :: Joins.Field
    local widths = table.create (#field.leaves) :: { number }
    for index, grid in field.leaves do
        widths[index] = grid.width
    end

    return Ir.word (tag, Words.plan (widths), field.leaves, { field.join })
end

-- A record, as the four regions and the records that dissolved into it.
local function recorded (
    of: Base.Cell,
    at: string,
    site: Site,
    tag: Ir.Tag,
    carries: string?
): Ir.Group
    local split = Regions.of (of.children :: { [string]: Base.Cell })

    --[[
        The records that dissolved, each hanging off the one above it. They arrive in depth order,
        so the one a nest hangs off has always been made by the time the nest is.
    ]]
    local nests = table.create (#split.nests) :: { Ir.Nest }
    local under: { [string]: number } = {}

    -- The names each of these records may carry, one set per record.
    local allow: { [string]: boolean } = {}
    local allows = table.create (#split.nests) :: { { [string]: boolean } }

    for index, entry in split.nests do
        local path = entry.at
        local deep = #path

        allows[index] = {}
        nests[index] = {
            key = path[deep],
            under = if deep == 1 then nil else under[spelled (path, deep - 1)],
            allow = allows[index],
            tag = plain (entry.of, pathed (at, path), site),
        }
        under[spelled (path, deep)] = index
    end

    local function inside (path: { string }): number?
        if #path == 1 then return nil end
        return under[spelled (path, #path - 1)]
    end

    --[[
        Every nest is made before any name is declared, so a field at any depth reaches the record
        it belongs to. An optional's bit and its payload are one declaration under one name, so the
        presence list has nothing here the variable list does not.
    ]]
    local function declare (path: { string })
        local deep = #path
        local into = if deep == 1 then allow else allows[under[spelled (path, deep - 1)]]
        into[path[deep]] = true
    end

    for _, entry in split.nests do
        declare (entry.at)
    end
    for _, entry in split.bits do
        declare (entry.at)
    end
    for _, entry in split.bytes do
        declare (entry.at)
    end
    for _, entry in split.vars do
        declare (entry.at)
    end
    --[[
        The one name a record may carry that its own declaration does not hold, which is the tag a
        variant was chosen by. Every variant is a struct and none of them declares the tag, both of
        which the constructor holds them to, so this adds a name and never replaces one.
    ]]
    if carries ~= nil then allow[carries] = true end

    for _, one in allows do
        table.freeze (one)
    end

    --[[
        Which leaf each optional's bit is, which the payload needs and the partition already knows:
        the bits are the first leaves of the region in the order the presence list holds them, and
        the same entry is in the variable list under the same field's name.
    ]]
    local bit: { [Regions.Entry]: number } = {}
    local leaves: { Grid.Grid } = {}
    local joins: { Ir.Join } = {}

    for index, entry in split.presence do
        local path = entry.at
        bit[entry] = index

        table.insert (leaves, Grid.flag ())
        table.insert (joins, {
            at = index,
            count = 1,
            key = path[#path],
            nest = inside (path),
            tag = plain (entry.of, pathed (at, path), site),
            pull = there,
            push = nothing,
        })
    end

    for _, entry in split.bits do
        local path = entry.at
        local held = tagged (entry.of, pathed (at, path), site)
        local key, nest = path[#path], inside (path)

        local made = Joins.of (entry.of, held, #leaves + 1, key, nest)
        if made == nil then made = Folds.of (entry.of, held, #leaves + 1, key, nest) end

        local field = made :: Joins.Field
        for _, grid in field.leaves do
            table.insert (leaves, grid)
        end
        table.insert (joins, field.join)
    end

    local parts: { Ir.Part } = {}

    for _, entry in split.bytes do
        local path = entry.at
        table.insert (parts, {
            key = path[#path],
            nest = inside (path),
            of = Lower.of (entry.of, pathed (at, path), site),
        })
    end

    --[[
        An optional is its payload and the bit that says whether it is there, and the bit was laid
        down above. The checks a caller declared on it ride on the node that may not be reached, so
        an absent field is one they never run on.
    ]]
    for _, entry in split.vars do
        local path = entry.at
        local where = pathed (at, path)
        local place = bit[entry]

        local made: Ir.Shape
        if place == nil then
            made = Lower.of (entry.of, where, site)
        else
            local inner = (entry.of.children :: any).inner :: Base.Cell
            made = Ir.opt (
                tagged (entry.of, where, site),
                place,
                Lower.of (inner, Serial.under (where, "inner"), site)
            )
        end

        table.insert (parts, { key = path[#path], nest = inside (path), of = made })
    end

    local word: Ir.Word? = nil
    if #joins > 0 then
        local widths = table.create (#leaves) :: { number }
        for index, grid in leaves do
            widths[index] = grid.width
        end
        word = Ir.word (plain (of, at, site), Words.plan (widths), leaves, joins)
    end

    return Ir.group (tag, word, parts, if #nests == 0 then nil else nests, allow)
end

-- One declaration to the node it becomes, with everything under it already its own.
local function shaped (
    of: Base.Cell,
    at: string,
    site: Site,
    tag: Ir.Tag,
    carries: string?
): Ir.Shape
    local kind, params = of.kind, of.params
    if Regions.packs (of) then return worded (of, at, site, tag) end

    -- A field the language carries whose one leaf is too wide to flow, which is whole bytes.
    local single = Joins.grid (of)
    if single ~= nil then return Ir.wide (tag, single) end

    if kind == "empty" then return Ir.none (tag) end
    if kind == "f32" then return Ir.float (tag, false) end
    if kind == "f64" then return Ir.float (tag, true) end
    if kind == "vlq" then return Ir.varint (tag, false) end
    if kind == "vli" then return Ir.varint (tag, true) end
    if kind == "inst" then return Ir.slot (tag, params.class) end

    if kind == "str" then return Ir.bytes (tag, counted (params), "string", params.symbols) end
    if kind == "buffer" then return Ir.bytes (tag, counted (params), "buffer", nil) end
    if kind == "unknown" then return Ir.unknown (tag, counted (params)) end

    --[[
        An array is a packed run where its element is one leaf that fits, and a list of aligned
        elements otherwise. An element of several leaves that would all fit is a list too, and pays
        up to seven pad bits each for it, because a run carries one grid and a bitfield or a
        quantized vector is more than one. Closing that means a run whose element is a region.
    ]]
    if kind == "array" then
        local element = (of.children :: any).element :: Base.Cell
        local grid = if Regions.packs (element) then Joins.grid (element) else nil
        if grid ~= nil then return Ir.run (tag, counted (params), grid) end

        return Ir.list (
            tag,
            counted (params),
            Lower.of (element, Serial.under (at, "element"), site)
        )
    end

    if kind == "map" then
        local children = of.children :: any
        return Ir.pairs (
            tag,
            counted (params),
            Lower.of (children.key, Serial.under (at, "key"), site),
            Lower.of (children.value, Serial.under (at, "value"), site)
        )
    end

    --[[
        An optional whose whole definition it is. Its bit has no region to live in, so it gets one
        of its own, and both the bit and the payload are nameless because what comes back is the
        value rather than a record of one field.
    ]]
    if kind == "optional" then
        local held = plain (of, at, site)
        local join: Ir.Join = {
            at = 1,
            count = 1,
            key = nil,
            tag = held,
            pull = there,
            push = nothing,
        }

        local inner = (of.children :: any).inner :: Base.Cell
        local part: Ir.Part = {
            of = Ir.opt (tag, 1, Lower.of (inner, Serial.under (at, "inner"), site)),
        }

        return Ir.group (
            held,
            Ir.word (held, Words.plan ({ 1 }), { Grid.flag () }, { join }),
            { part }
        )
    end

    if kind == "tagged" then
        local variants = of.children :: { [string]: Base.Cell }
        local names = Order.names (variants)
        local field = params.field :: string

        local arms = table.create (#names) :: { Ir.Shape }
        for index, name in names do
            arms[index] = Lower.of (variants[name], Serial.under (at, name), site, field)
        end

        return Ir.branch (tag, field, names, arms)
    end

    if kind == "struct" then return recorded (of, at, site, tag, carries) end

    --[[
        A vector and a colour of components too wide to flow, which is every one whose components
        are floats. The component is lowered once and stood in every place, since the three are one
        declaration and a node is a value.
    ]]
    if kind == "vec2" or kind == "vec3" or kind == "color3" then
        local children = of.children
        local component = if children == nil then nil else children.component

        local one = if component == nil
            then Ir.float (plain (of, at, site), false) :: Ir.Shape
            else Lower.of (component, Serial.under (at, "component"), site)

        if kind == "vec2" then
            return Ir.apart (tag, Folds.ENGINE.vec2, table.clone (PLANE), { one, one }, planar)
        end

        local push = if kind == "vec3" then spatial else lit
        local keys = if kind == "vec3" then SPACE else LIGHT
        local engine = if kind == "vec3" then Folds.ENGINE.vec3 else Folds.ENGINE.color3
        return Ir.apart (tag, engine, table.clone (keys), { one, one, one }, push)
    end

    local children = of.children :: any
    return Ir.apart (tag, Folds.ENGINE.cframe, table.clone (FRAME), {
        Lower.of (children.position, Serial.under (at, "position"), site),
        Lower.of (children.rotation, Serial.under (at, "rotation"), site),
    }, framed)
end

-- Public --------------------------------------------------------------

-- A declaration, at the path a refusal in it reads as, and everything under it.
function Lower.of (of: Base.Cell, at: string, site: Site, carries: string?): Ir.Shape
    local lift = of.lift
    if lift == nil then return shaped (of, at, site, tagged (of, at, site), carries) end

    local inner = shaped (of, at, site, plain (of, at, site), carries)
    return Ir.xform (tagged (of, at, site), inner, lift, of.lower :: (any) -> any)
end

return table.freeze (Lower)
