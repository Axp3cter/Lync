--!strict
--!optimize 2
-- The six Roblox datatypes: what each one declares, and never how it converts.

local Base = require ("@src/codec/Base")
local Legality = require ("@src/codec/Legality")
local Log = require ("@src/kernel/Log")
local Scalars = require ("@src/codec/Scalars")
local Types = require ("@src/Types")

local Datatypes = {}

-- Private -------------------------------------------------------------

--[[
    A form is recorded wherever a name carries more than one, because a form is a different wire
    object rather than a different parameter. The lowering then reads one field and branches,
    instead of working out which parameters happen to be absent.
]]
local function turning (_: any, component: Types.Codec<any>?): Types.Codec<Vector3>
    if component == nil then return Base.make ("vec3", { form = "components" }) end

    Legality.bare ("vec3", "component", component)
    return Base.make ("vec3", { form = "components" }, { component = component })
end

local function unit (precision: number): Types.Codec<Vector3>
    Scalars.precise ("vec3.unit", precision)
    return Base.make ("vec3", { form = "unit", step = precision })
end

local function bounded (max: number, step: number): Types.Codec<Vector3>
    if not (Legality.finite (max) and max > 0) then
        Log.refuse (`vec3.bounded takes a radius above zero, not {max}`)
    end
    if not (Legality.finite (step) and step > 0) then
        Log.refuse (`vec3.bounded takes a step above zero, not {step}`)
    end

    return Base.make ("vec3", { form = "bounded", max = max, step = step })
end

local function still (): Types.Codec<CFrame> return Base.make ("rotation", { form = "none" }) end

--[[
    The axis is recorded as it was given rather than normalised. Any positive multiple of it is the
    same turn and would lower the same way, so canonicalising it would change what a caller wrote to
    make two descriptors agree that no two builds can disagree about.
]]
local function about (axis: Vector3, precision: number): Types.Codec<CFrame>
    if typeof (axis) ~= "Vector3" then
        Log.refuse (`rotation.axis takes a Vector3 to turn about, not a {typeof (axis)}`)
    end
    if not (Legality.finite (axis.Magnitude) and axis.Magnitude > 0) then
        Log.refuse (`rotation.axis takes an axis with a direction, not {tostring (axis)}`)
    end
    Scalars.precise ("rotation.axis", precision)

    return Base.make ("rotation", { form = "axis", axis = axis, step = precision })
end

local function facing (precision: number): Types.Codec<CFrame>
    Scalars.precise ("rotation.direction", precision)
    return Base.make ("rotation", { form = "direction", step = precision })
end

local function quat (precision: number): Types.Codec<CFrame>
    Scalars.precise ("rotation.quat", precision)
    return Base.make ("rotation", { form = "quat", step = precision })
end

local function packed (): Types.Codec<Color3> return Base.make ("color3", { form = "rgb565" }) end

--[[
    Read by their components rather than by identity, because a colour is a userdata and two of them
    equal by value are two keys in a table. A repeat costs the same here as a repeated symbol in
    an alphabet does, which is an index nothing can ever be encoded as.
]]
local function palette (colors: { Color3 }): Types.Codec<Color3>
    if type (colors) ~= "table" then
        Log.refuse (`color3.palette takes a list of colours, not a {typeof (colors)}`)
    end
    if #colors == 0 then Log.refuse ("color3.palette takes at least one colour") end

    local seen = {}
    for index = 1, #colors do
        local color = colors[index]
        if typeof (color) ~= "Color3" then
            Log.refuse (`color3.palette takes a colour at {index}, not a {typeof (color)}`)
        end

        local at = `{color.R} {color.G} {color.B}`
        if seen[at] ~= nil then
            Log.refuse (`color3.palette takes each colour once, and the one at {index} is twice`)
        end
        seen[at] = true
    end

    return Base.make ("color3", { form = "palette", colors = colors })
end

-- Three floats, which is what a colour is where nothing narrower was asked for.
local function coloured (_: any): Types.Codec<Color3>
    return Base.make ("color3", { form = "components" })
end

-- Public --------------------------------------------------------------

-- Two components in the codec given, or two floats where none was.
function Datatypes.vec2 (component: Types.Codec<any>?): Types.Codec<Vector2>
    if component == nil then return Base.make ("vec2") end

    Legality.bare ("vec2", "component", component)
    return Base.make ("vec2", nil, { component = component })
end

Datatypes.vec3 = table.freeze (setmetatable ({ unit = unit, bounded = bounded }, {
    __call = turning,
}))

--[[
    A position codec and a rotation codec, and neither is held to a kind. `as` is how a caller
    reaches a datatype this vocabulary does not name, so a position built out of a struct is a
    position, and what it lifts to is the caller's promise rather than something a kind can say.
]]
function Datatypes.cframe (
    position: Types.Codec<any>,
    rotation: Types.Codec<any>
): Types.Codec<CFrame>
    Legality.bare ("cframe", "position", position)
    Legality.bare ("cframe", "rotation", rotation)

    return Base.make ("cframe", nil, { position = position, rotation = rotation })
end

-- Four ways to spell a turn and no default among them, so the name itself answers nothing.
Datatypes.rotation = table.freeze ({
    none = still,
    axis = about,
    direction = facing,
    quat = quat,
})

Datatypes.color3 = table.freeze (setmetatable ({ rgb565 = packed, palette = palette }, {
    __call = coloured,
}))

--[[
    Always optional, since a receiver that cannot see the instance is handed nothing and that is a
    normal outcome rather than a drop. The class is a name to check against on the way in and
    nothing here can tell a real one from a typo, so it is only held.
]]
function Datatypes.inst (class: string?): Types.Codec<Instance?>
    if class == nil then return Base.make ("inst") end
    if type (class) ~= "string" or class == "" then
        Log.refuse (`inst takes a class name, not "{tostring (class)}"`)
    end

    return Base.make ("inst", { class = class })
end

return table.freeze (Datatypes)
