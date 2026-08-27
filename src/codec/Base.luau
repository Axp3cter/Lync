--!strict
--!optimize 2
-- The codec cell: one frozen value per declaration, and the four modifiers that answer another.

local Log = require ("@src/kernel/Log")
local Types = require ("@src/Types")

local Base = {}

--[[
    The one metatable every codec shares, so a declaration costs one table and `table.clone`
    carries it to every copy it makes.
]]
local Modifiers = {}
Modifiers.__index = Modifiers

-- Constants -----------------------------------------------------------

-- Shared by every codec declaring neither, since two frozen empty tables cannot be told apart.
const NO_PARAMS: Params = table.freeze ({})
const NO_CHECKS = table.freeze ({} :: { Validate })

-- Types ---------------------------------------------------------------

export type Kind =
    "empty"
    | "bool"
    | "int"
    | "quant"
    | "angle"
    | "f32"
    | "f64"
    | "vlq"
    | "vli"
    | "str"
    | "buffer"
    | "struct"
    | "array"
    | "map"
    | "optional"
    | "tagged"
    | "enum"
    | "bitfield"
    | "vec2"
    | "vec3"
    | "cframe"
    | "rotation"
    | "color3"
    | "inst"
    | "unknown"

export type Marker = "none" | "monotonic" | "newest"

export type Validate = (value: any, ctx: Types.ValidateContext) -> string?

--[[
    Every parameter any constructor records, in one vocabulary. The set is closed and holds nothing
    without exact text: the descriptor writes parameters as decimals, and two machines agreeing on
    a schema is that text agreeing.
]]
export type Params = {
    read min: number?,
    read max: number?,
    read step: number?,
    read form: string?,
    read field: string?,
    read symbols: string?,
    read class: string?,
    read names: { string }?,
    read colors: { Color3 }?,
    read axis: Vector3?,
}

--[[
    A declaration, frozen, as the compile path reads it. There is one codec type and it is the
    public one, since two over one value cost more than the accessor below and neither an
    intersection nor a flat pair survives the solver. It carries no value type either: a walk over
    children meets a different one at every node.
]]
export type Cell = {
    read kind: Kind,
    read params: Params,
    read children: { [string]: Cell }?,
    read validates: { Validate },
    read marker: Marker,
    read newestHz: number?,
    read lift: ((wire: any) -> any)?,
    read lower: ((domain: any) -> any)?,
}

--[[
    What the library builds for itself: the one or two children a composite names. A caller's own
    table does not come through here, because a table whose properties are read-only satisfies no
    indexer in this solver and everything in this repository is frozen.
]]
export type Children = { [string]: Types.Codec<any> }

--[[
    A cell mid-change, with the five facts a modifier may move writable and everything that decides
    a layout still read-only. A modifier that tried to widen a field does not compile, which is the
    claim `codec.modifier-free` makes from the other end.
]]
type Open = {
    read kind: Kind,
    read params: Params,
    read children: { [string]: Cell }?,
    validates: { Validate },
    marker: Marker,
    newestHz: number?,
    lift: ((wire: any) -> any)?,
    lower: ((domain: any) -> any)?,
}

-- Private -------------------------------------------------------------

local function opened (of: Types.Codec<any>): Open return table.clone (of :: any) :: any end

local function sealed (made: Open): Types.Codec<any> return table.freeze (made :: any) :: any end

-- Public --------------------------------------------------------------

-- A codec as its constructor declares it, before any modifier.
function Base.make (kind: Kind, params: Params?, children: Children?): Types.Codec<any>
    local held: any = if children == nil then nil else table.freeze (table.clone (children))

    local taken: any = params
    if taken ~= nil then
        for name, value in taken do
            if type (value) == "table" then taken[name] = table.freeze (table.clone (value)) end
        end
    end

    return table.freeze (setmetatable ({
        kind = kind,
        params = if params == nil then NO_PARAMS else table.freeze (params),
        children = held,
        validates = NO_CHECKS,
        marker = "none" :: Marker,
    }, Modifiers)) :: any
end

--[[
    The same value as the compile path reads it. One call rather than a cast at every field, and the
    one place the two views of a codec meet.
]]
function Base.cell (of: Types.Codec<any>): Cell return of :: any end

-- The other way round, which is one table read two ways and never two tables.
function Base.codec (of: Cell): Types.Codec<any> return of :: any end

-- Whether a value came from here, which is what a composite asks of every child handed to it.
function Base.made (value: unknown): boolean return getmetatable (value :: any) == Modifiers end

--[[
    Checks run in declaration order and the first reason wins, so a chain appends rather than
    replaces. The array is frozen with the cell: a codec is a value, and a value whose checks could
    be appended to from outside would be two schemas under one hash.
]]
function Modifiers.validate <T>(
    self: Types.Codec<T>,
    check: (value: T, ctx: Types.ValidateContext) -> string?
): Types.Codec<T>
    local checks = table.clone (Base.cell (self).validates)
    table.insert (checks, check :: Validate)

    local made = opened (self)
    made.validates = table.freeze (checks)
    return sealed (made)
end

--[[
    The rate goes with the marker it belonged to, so a chain never leaves one behind a marker that
    has none and a descriptor never writes a rate onto `monotonic`.
]]
function Modifiers.monotonic <T>(self: Types.Codec<T>): Types.Codec<T>
    local made = opened (self)
    made.marker = "monotonic"
    made.newestHz = nil
    return sealed (made)
end

--[[
    A rate of zero never opens its gate and a negative one always does, so both are a stream that
    silently does not do what it says. Whether the marker belongs on this field at all is a
    question about the shape underneath it, and is asked when the namespace starts.
]]
function Modifiers.newest <T>(self: Types.Codec<T>, hz: number?): Types.Codec<T>
    if hz ~= nil and not (hz > 0 and hz < math.huge) then
        Log.refuse (`newest takes a rate above zero, not {hz}`)
    end

    local made = opened (self)
    made.marker = "newest"
    made.newestHz = hz
    return sealed (made)
end

--[[
    A pair is adopted whole where there is none beneath it, and composed where there is. A datatype
    is an `as` over its wire form, so the common case is the first one and a wrapper call per value
    would tax every vector in every frame.
]]
function Modifiers.as <T, U>(
    self: Types.Codec<T>,
    to: (value: T) -> U,
    from: (value: U) -> T
): Types.Codec<U>
    local held = Base.cell (self)
    local lift, lower = held.lift, held.lower

    local lifted = if lift == nil
        then to :: any
        else function (wire: any) return to (lift (wire)) end
    local lowered = if lower == nil
        then from
        else function (domain: any) return lower (from (domain)) end

    local made = opened (self)
    made.lift = lifted
    made.lower = lowered

    local checks = held.validates
    local reach = #checks
    if reach == 0 then return sealed (made) end

    local under = table.create (reach) :: { Validate }
    for index = 1, reach do
        local check = checks[index]
        under[index] = function (value: any, ctx: Types.ValidateContext): string?
            return check (from (value :: any), ctx)
        end
    end

    made.validates = table.freeze (under)
    return sealed (made)
end

return table.freeze (Base)
