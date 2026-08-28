--!strict
--!optimize 2
-- A declaration whose value comes apart by a computation, as the leaves it takes and the pair.

local Base = require ("@src/codec/Base")
local Grid = require ("@src/shape/Grid")
local Ir = require ("@src/shape/Ir")
local Joins = require ("@src/shape/Joins")
local Protocol = require ("@src/wire/Protocol")
local Rotation = require ("@src/shape/Rotation")
local Scalars = require ("@src/codec/Scalars")

local Folds = {}

-- Types ---------------------------------------------------------------

-- What a fold becomes, which is what a field the language carries becomes and for one reason.
export type Field = Joins.Field

-- Constants -----------------------------------------------------------

-- What the engine calls each of the four this file takes apart.
const PLANE = "Vector2"
const VECTOR = "Vector3"
const FRAME = "CFrame"
const COLOUR = "Color3"

-- The same four, under the kinds that declare them.
Folds.ENGINE = table.freeze ({
    vec2 = PLANE,
    vec3 = VECTOR,
    color3 = COLOUR,
    cframe = FRAME,
})

-- The four a smallest three chooses between, which is what its tag is a ranged int over.
const CORNERS = Protocol.QUAT_W + 1

-- How far past its first leaf the last of those four sits.
const LAST = CORNERS - 1

-- What a packed colour spends on each of its three, which is named one at a time.
const RED = Protocol.RGB565_RED
const GREEN = Protocol.RGB565_GREEN
const BLUE = Protocol.RGB565_BLUE

-- Private -------------------------------------------------------------

-- A fold, as the one shape every form below answers in.
export type Fold = {
    leaves: { Grid.Grid },
    pull: (value: any, into: { number }, at: number) -> boolean,
    push: (from: { number }, at: number) -> any,
}

-- The components of a vector, one grid each, in the order they are written.
local function spread (of: Grid.Grid, wide: boolean): Fold
    local toIndex, fromIndex = of.toIndex, of.fromIndex

    local leaves = if wide then { of, of, of } else { of, of }

    -- Both widths come through here, so which datatype is wanted follows the one it was built for.
    local wanted = if wide then VECTOR else PLANE

    local function pull (value: any, into: { number }, at: number): boolean
        if typeof (value) ~= wanted then return false end

        local x, y = toIndex (value.X), toIndex (value.Y)
        if x == nil or y == nil then return false end

        if not wide then
            into[at], into[at + 1] = x, y
            return true
        end

        local z = toIndex (value.Z)
        if z == nil then return false end

        into[at], into[at + 1], into[at + 2] = x, y, z
        return true
    end

    local function push (from: { number }, at: number): any
        if not wide then return Vector2.new (fromIndex (from[at]), fromIndex (from[at + 1])) end
        local x, y = fromIndex (from[at]), fromIndex (from[at + 1])
        return Vector3.new (x, y, fromIndex (from[at + 2]))
    end

    return { leaves = leaves, pull = pull, push = push }
end

-- A direction as the two the octahedral fold keeps, which is `vec3.unit` and nothing else.
local function pointing (of: Grid.Grid): Fold
    local mapping = Rotation.octahedral (of)
    local plane, sphere = mapping.plane, mapping.sphere

    local function pull (value: any, into: { number }, at: number): boolean
        if typeof (value) ~= VECTOR then return false end

        local u, v = plane (value.X, value.Y, value.Z)
        if u == nil or v == nil then return false end

        into[at], into[at + 1] = u, v
        return true
    end

    local function push (from: { number }, at: number): any
        return Vector3.new (sphere (from[at], from[at + 1]))
    end

    return { leaves = { of, of }, pull = pull, push = push }
end

--[[
    A direction and how far it reaches, the one form whose leaves are two grids. The length is
    worked out and never read off the value, so nothing in this file asks a datatype for anything
    but its components.
]]
local function reaching (way: Grid.Grid, far: Grid.Grid): Fold
    local mapping = Rotation.octahedral (way)
    local plane, sphere = mapping.plane, mapping.sphere
    local toIndex, fromIndex = far.toIndex, far.fromIndex

    --[[
        Where a vector of no length points, which is nowhere and has to be somewhere. The fold
        divides by the sum of the magnitudes, so a zero would reach the grid as no place at all.
        The middle of the square is what it takes, which multiplies back out to the zero it was.
    ]]
    local centre = way.toIndex (0) :: number

    local function pull (value: any, into: { number }, at: number): boolean
        if typeof (value) ~= VECTOR then return false end

        local x, y, z = value.X, value.Y, value.Z
        local length = toIndex (math.sqrt (x * x + y * y + z * z))
        if length == nil then return false end

        --[[
            A vector whose length comes to none, which is every vector shorter than half a step and
            not only the one that arrived as a zero.
        ]]
        if fromIndex (length) == 0 then
            into[at], into[at + 1], into[at + 2] = centre, centre, length
            return true
        end

        local u, v = plane (x, y, z)
        if u == nil or v == nil then return false end

        into[at], into[at + 1], into[at + 2] = u, v, length
        return true
    end

    local function push (from: { number }, at: number): any
        local x, y, z = sphere (from[at], from[at + 1])
        local length = fromIndex (from[at + 2])

        return Vector3.new (x * length, y * length, z * length)
    end

    return { leaves = { way, way, far }, pull = pull, push = push }
end

-- A frame that turns about nothing, which occupies no leaves at all.
local function still (): Fold
    local function pull (): boolean return true end
    local function push (): any return CFrame.identity end

    return { leaves = {}, pull = pull, push = push }
end

-- A frame, whichever rotation form declared it, since all of them come back through a quaternion.
local function turned (leaves: { Grid.Grid }, parts: any, whole: any, reach: number): Fold
    local function pull (value: any, into: { number }, at: number): boolean
        if typeof (value) ~= FRAME then return false end

        local first, second, third, fourth = parts (value:GetComponents ())
        if first == nil then return false end

        into[at] = first :: number
        if reach == 1 then return true end

        if second == nil then return false end
        into[at + 1] = second :: number
        if reach == 2 then return true end

        if third == nil or fourth == nil then return false end
        into[at + 2], into[at + LAST] = third :: number, fourth :: number
        return true
    end

    local function push (from: { number }, at: number): any
        local x, y, z, w = whole (from[at], from[at + 1], from[at + 2], from[at + LAST])
        return CFrame.new (0, 0, 0, x, y, z, w)
    end

    return { leaves = leaves, pull = pull, push = push }
end

-- The three a packed colour spends its sixteen bits on, green taking the odd one.
local function packed (): Fold
    local red, green, blue = Grid.channel (RED), Grid.channel (GREEN), Grid.channel (BLUE)

    local function pull (value: any, into: { number }, at: number): boolean
        if typeof (value) ~= COLOUR then return false end

        local r, g, b = red.toIndex (value.R), green.toIndex (value.G), blue.toIndex (value.B)
        if r == nil or g == nil or b == nil then return false end

        into[at], into[at + 1], into[at + 2] = r, g, b
        return true
    end

    local function push (from: { number }, at: number): any
        return Color3.new (
            red.fromIndex (from[at]),
            green.fromIndex (from[at + 1]),
            blue.fromIndex (from[at + 2])
        )
    end

    return { leaves = { red, green, blue }, pull = pull, push = push }
end

-- One of a list of colours, as where it sits in the list.
local function chosen (colors: { Color3 }): Fold
    local reach = #colors
    local of = Grid.index (reach)

    local index: { [string]: number } = {}
    for place, one in colors do
        index[`{one.R},{one.G},{one.B}`] = place - 1
    end

    local function pull (value: any, into: { number }, at: number): boolean
        if typeof (value) ~= COLOUR then return false end

        local held = index[`{value.R},{value.G},{value.B}`]
        if held == nil then return false end

        into[at] = held
        return true
    end

    local function push (from: { number }, at: number): any return colors[from[at] + 1] end

    return { leaves = { of }, pull = pull, push = push }
end

-- Public --------------------------------------------------------------

-- Which fold a declaration is, or nothing where it is no region field at all.
function Folds.fold (of: Base.Cell): Fold?
    local kind, params = of.kind, of.params
    local form = params.form

    if kind == "vec2" or kind == "vec3" then
        local children = of.children
        local component = if children == nil then nil else children.component

        if form == "unit" then return pointing (Grid.plane (params.step :: number)) end
        if form == "bounded" then
            local max, step = params.max :: number, params.step :: number
            return reaching (Grid.of (-1, 1, step / max), Grid.of (0, max, step))
        end

        if component == nil then return nil end

        local single = Joins.grid (component)
        if single == nil then return nil end

        return spread (single, kind == "vec3")
    end

    if kind == "rotation" then
        if form == "none" then return still () end

        local step = params.step :: number
        if form == "axis" then
            local axis = params.axis :: Vector3
            local grid = Grid.of (0, Scalars.TURN - step, step, true)
            local mapping = Rotation.axial (grid, axis.X, axis.Y, axis.Z)

            return turned ({ grid }, mapping.parts, mapping.whole, 1)
        end

        if form == "direction" then
            local grid = Grid.plane (step)
            local mapping = Rotation.facing (grid)

            return turned ({ grid, grid }, mapping.parts, mapping.whole, 2)
        end

        local chord = Grid.chord (step)
        local mapping = Rotation.smallest (chord)

        return turned (
            { Grid.index (CORNERS), chord, chord, chord },
            mapping.parts,
            mapping.whole,
            4
        )
    end

    if kind ~= "color3" then return nil end

    if form == "rgb565" then return packed () end
    if form == "palette" then return chosen (params.colors :: { Color3 }) end

    return nil
end

-- A declaration, at the leaf it starts on, as the field it becomes.
function Folds.of (of: Base.Cell, tag: Ir.Tag, at: number, key: string?, nest: number?): Field?
    local held = Folds.fold (of)
    if held == nil then return nil end

    return {
        leaves = held.leaves,
        join = {
            at = at,
            count = #held.leaves,
            key = key,
            nest = nest,
            tag = tag,
            pull = held.pull,
            push = held.push,
        },
    }
end

return table.freeze (Folds)
